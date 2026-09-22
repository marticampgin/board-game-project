extends Control
## Native UI and development bridge. Commands always cross GameRules.execute.

const Rules = preload("res://scripts/domain/game_rules.gd")
const Board = preload("res://scripts/presentation/board_view.gd")
const ActionLog = preload("res://scripts/services/action_logger.gd")
const Hex = preload("res://scripts/domain/hex/hex.gd")
const Bot = preload("res://scripts/domain/bots/simple_bot.gd")
const Saves = preload("res://scripts/services/snapshot_store.gd")
const Preferences = preload("res://scripts/services/preferences.gd")
const Equipment = preload("res://scripts/domain/resolvers/equipment.gd")
const RemoteView = preload("res://scripts/presentation/remote_rules_view.gd")
const NetworkLobby = preload("res://scripts/presentation/network_lobby.gd")
const PHASES: Array[String] = ["world", "planning", "initiative", "cycle_1", "cycle_2", "bonus", "resolution"]
const INK := Color("eee8d8")
const MUTED := Color("91aaa9")
const GOLD := Color("dec18a")

var rules: RefCounted
var logger: RefCounted
var board: Node3D
var viewport: SubViewport
var viewport_container: SubViewportContainer
var seed_edit: LineEdit
var phase_title: Label
var instruction: Label
var phase_steps: HBoxContainer
var initiative: HBoxContainer
var cards: VBoxContainer
var actions: HFlowContainer
var selected_panel: RichTextLabel
var log_text: RichTextLabel
var debug_text: RichTextLabel
var feedback: Label
var hover_label: Label
var debug_panel: PanelContainer
var welcome: PanelContainer
var rules_dialog: AcceptDialog
var pass_dialog: ConfirmationDialog
var buttons: Dictionary = {}
var viewer: String = "p1"
var selected_hex: String = ""
var move_mode: bool = false
var started: bool = false
var last_result: Dictionary = {}
var bridge_callbacks: Array = []
var journal_filter: String = "all"
var reduced_motion: bool = false
var target_mode: String = ""
var decision_ack: String = ""
var handoff: Control
var handoff_label: Label
var planning_dialog: ConfirmationDialog
var planning_push: CheckBox
var planning_snare: OptionButton
var planning_hex: OptionButton
var planning_seat: String = ""
var planning_purchase: OptionButton
var planning_purchases: Array[OptionButton] = []
var mode_select: OptionButton
var seat_select: OptionButton
var local_mode: String = "sandbox"
var human_seat: String = "p1"
var bot_elapsed: float = 0.0
var session_label: Label
var saves := Saves.new()
var load_dialog: AcceptDialog
var threat_label: Label
var pending_handoff_key: String = ""
var victory_panel: PanelContainer
var victory_text: Label
var cinematic: PanelContainer
var cinematic_text: Label
var cinematic_seconds: float = 0.0
var preferences: Node
var settings_dialog: AcceptDialog
var network: Node
var network_lobby: AcceptDialog
var network_event_sequence: int = 0
var network_results: Array = []
const MANUAL_SAVE := "user://saves/manual.json"
const AUTO_SAVE := "user://saves/autosave.json"

func _ready() -> void:
	logger = ActionLog.new("user://logs/actions.jsonl")
	preferences = Preferences.new()
	add_child(preferences)
	_build_theme()
	_build_ui()
	_apply_preferences()
	_new_game(20260922)
	_setup_bridge()
	get_viewport().size_changed.connect(_publish_bridge)

func _build_theme() -> void:
	var result := Theme.new()
	result.default_font_size = 15
	result.set_color("font_color", "Label", INK)
	result.set_color("default_color", "RichTextLabel", INK)
	for state_name in ["normal", "hover", "pressed", "focus", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color("253d44") if state_name == "normal" else Color("37524f")
		if state_name == "disabled": style.bg_color = Color("1c2c32")
		style.border_color = Color("52726f") if state_name == "focus" else Color("3b5558")
		style.set_border_width_all(1)
		style.set_corner_radius_all(5)
		style.content_margin_left = 13
		style.content_margin_right = 13
		style.content_margin_top = 9
		style.content_margin_bottom = 9
		result.set_stylebox(state_name, "Button", style)
	result.set_color("font_color", "Button", INK)
	result.set_color("font_disabled_color", "Button", Color("65807e"))
	var input_style := StyleBoxFlat.new()
	input_style.bg_color = Color("101f28")
	input_style.set_corner_radius_all(4)
	input_style.content_margin_left = 9
	input_style.content_margin_right = 9
	result.set_stylebox("normal", "LineEdit", input_style)
	result.set_color("font_color", "LineEdit", INK)
	theme = result

func _panel(color: Color = Color("192d35"), padding: int = 14) -> PanelContainer:
	var result := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = Color("304951")
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	result.add_theme_stylebox_override("panel", style)
	return result

func _label(value: String, font_size: int = 15, color: Color = INK) -> Label:
	var result := Label.new()
	result.text = value
	result.add_theme_font_size_override("font_size", font_size)
	result.add_theme_color_override("font_color", color)
	return result

func _button(id: String, text_value: String, callable: Callable) -> Button:
	var result := Button.new()
	result.text = text_value
	result.pressed.connect(callable)
	result.pressed.connect(func() -> void: preferences.click())
	result.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	buttons[id] = result
	return result

func _rich(min_height: float = 0) -> RichTextLabel:
	var result := RichTextLabel.new()
	result.bbcode_enabled = true
	result.custom_minimum_size.y = min_height
	result.selection_enabled = true
	result.add_theme_font_size_override("normal_font_size", 14)
	result.add_theme_color_override("default_color", INK)
	return result

func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("101f28")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	add_child(margin)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 10)
	margin.add_child(layout)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	layout.add_child(header)
	var brand := VBoxContainer.new()
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(brand)
	brand.add_child(_label("SHATTERED REALM", 26, GOLD))
	brand.add_child(_label("A realm divided. Four paths to power.", 13, MUTED))
	var seed_box := VBoxContainer.new()
	header.add_child(seed_box)
	seed_box.add_child(_label("WORLD SEED", 11, MUTED))
	seed_edit = LineEdit.new()
	seed_edit.text = "20260922"
	seed_edit.custom_minimum_size = Vector2(150, 32)
	seed_edit.tooltip_text = "Identical seeds reproduce terrain, locations and roads."
	seed_box.add_child(seed_edit)
	header.add_child(_button("regenerate", "Regenerate", _regenerate))
	header.add_child(_button("copy_seed", "Copy seed", func() -> void: DisplayServer.clipboard_set(seed_edit.text)))
	header.add_child(_button("rules", "Rules", func() -> void: rules_dialog.popup_centered(Vector2i(650, 470))))
	header.add_child(_button("settings", "Settings", func() -> void: settings_dialog.popup_centered()))
	header.add_child(_button("online", "Online", func() -> void: network_lobby.popup_centered()))
	header.add_child(_button("debug", "Debug  F3", _toggle_debug))
	var phase_panel := _panel(Color("1d333a"), 10)
	layout.add_child(phase_panel)
	var phase_stack := VBoxContainer.new()
	phase_panel.add_child(phase_stack)
	var phase_row := HBoxContainer.new()
	phase_stack.add_child(phase_row)
	phase_title = _label("ROUND 01", 18, GOLD)
	phase_title.custom_minimum_size.x = 240
	phase_row.add_child(phase_title)
	phase_steps = HBoxContainer.new()
	phase_steps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	phase_row.add_child(phase_steps)
	initiative = HBoxContainer.new()
	phase_stack.add_child(initiative)
	threat_label = _label("", 12, GOLD)
	threat_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	phase_stack.add_child(threat_label)
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(body)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 204
	body.add_child(left)
	left.add_child(_label("THE FOUR FACTIONS", 12, MUTED))
	cards = VBoxContainer.new()
	cards.add_theme_constant_override("separation", 4)
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var card_scroll := ScrollContainer.new()
	card_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(card_scroll)
	card_scroll.add_child(cards)
	session_label = _label("LOCAL · ALL FOUR SEATS", 11, MUTED)
	session_label.size_flags_vertical = Control.SIZE_SHRINK_END
	session_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	left.add_child(session_label)
	var save_row := HBoxContainer.new()
	left.add_child(save_row)
	save_row.add_child(_button("save_game", "Save", func() -> void: _save_game(MANUAL_SAVE)))
	save_row.add_child(_button("load_game", "Load", _open_load))
	save_row.add_child(_button("menu", "Menu", func() -> void: welcome.show(); _publish_bridge()))
	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(center)
	var map_title := HBoxContainer.new()
	center.add_child(map_title)
	var board_title := _label("THE FRACTURED MARCHES", 12, MUTED)
	board_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_title.add_child(board_title)
	map_title.add_child(_label("61 HEXES  /  16 LOCATIONS", 11, MUTED))
	viewport_container = SubViewportContainer.new()
	viewport_container.stretch = true
	viewport_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewport_container.custom_minimum_size = Vector2(380, 270)
	center.add_child(viewport_container)
	viewport = SubViewport.new()
	viewport.size = Vector2i(650, 450)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = true
	viewport_container.add_child(viewport)
	board = Board.new()
	viewport.add_child(board)
	viewport_container.gui_input.connect(board.input_event)
	board.hex_selected.connect(_select_hex)
	board.hex_hovered.connect(_hover_hex)
	hover_label = _label("Select a hex to inspect terrain and locations.", 12, MUTED)
	hover_label.custom_minimum_size.y = 20
	center.add_child(hover_label)
	var camera_controls := HBoxContainer.new()
	center.add_child(camera_controls)
	camera_controls.add_child(_button("rotate_left", "Q  Rotate", func() -> void: board.rotate_board(-0.3); _publish_bridge()))
	camera_controls.add_child(_button("focus", "F  Focus", _focus_actor))
	camera_controls.add_child(_button("zoom_out", "-", func() -> void: board.zoom_by(1); _publish_bridge()))
	camera_controls.add_child(_button("zoom_in", "+", func() -> void: board.zoom_by(-1); _publish_bridge()))
	camera_controls.add_child(_button("rotate_right", "Rotate  E", func() -> void: board.rotate_board(0.3); _publish_bridge()))
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 258
	body.add_child(right)
	right.add_child(_label("FIELD NOTES", 12, MUTED))
	var selection := _panel()
	right.add_child(selection)
	selected_panel = _rich(123)
	selection.add_child(selected_panel)
	var journal_row := HBoxContainer.new()
	right.add_child(journal_row)
	var journal_title := _label("CHRONICLE", 12, MUTED)
	journal_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	journal_row.add_child(journal_title)
	var filters := OptionButton.new()
	filters.add_item("All events")
	filters.add_item("Actions")
	filters.add_item("Economy")
	filters.item_selected.connect(func(index: int) -> void:
		journal_filter = ["all", "actions", "economy"][index]
		_refresh_journal())
	journal_row.add_child(filters)
	var journal := _panel(Color("142831"), 10)
	journal.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(journal)
	log_text = _rich()
	log_text.scroll_following = true
	journal.add_child(log_text)
	right.add_child(_button("export_log", "Export action log", _export_log))
	var footer := _panel(Color("20373c"), 12)
	layout.add_child(footer)
	var footer_stack := VBoxContainer.new()
	footer.add_child(footer_stack)
	instruction = _label("", 16, GOLD)
	footer_stack.add_child(instruction)
	actions = HFlowContainer.new()
	actions.add_theme_constant_override("separation", 8)
	footer_stack.add_child(actions)
	feedback = _label("Seeded rules · local four-seat play · no turn timers", 12, MUTED)
	footer_stack.add_child(feedback)
	_build_debug()
	_build_welcome()
	_build_decision_ui()
	_build_victory_ui()
	_build_settings()
	_build_network_lobby()
	rules_dialog = AcceptDialog.new()
	rules_dialog.title = "The rules of the realm"
	rules_dialog.dialog_text = "Each round: World > Planning > Initiative > two Action Cycles > Bonus > Resolution. Every hero acts once in each cycle. Initiative is Speed + d3.\n\nMove: 3 MP; road-only paths allow 4. Forest costs 2 (Ranger: 1). Swamp ends movement. Occupied and impassable hexes block paths.\n\nMinor Towers capture in one action; Ancient Towers need Begin then Complete on your next action. Towers pay Power at Resolution. Upgrades cost 3/5 Gold.\n\nCombat: select an adjacent target, choose sealed stances, then reveal. Assault +2; Guard +1 and reduces damage; Counter +3 against Assault, otherwise -1; Trick costs 1 Fate and gains +2 against Guard/Counter. Ties defend. Attacker rerolls first, then defender. Each reroll costs 1 Fate.\n\nFate caps at 5 and grows by 1 each Resolution. Planning offers Initiative Push, Ranger Snare and Cultist Prepared Hex. Downed heroes recover at Sanctuary and retain scheduled actions.\n\nGreen rings: Move. Red rings: Attack. Camera: WASD pan, Q/E rotate, wheel zoom, F/Home focus. Victory routes and exploration arrive in Milestone 3."
	add_child(rules_dialog)
	buttons.rules_close = rules_dialog.get_ok_button()
	rules_dialog.dialog_text = "ROUND: World event > private Planning > Initiative > Cycle 1 > Cycle 2 > Bonus > Resolution. Every hero has one action per cycle. Speed + d3 sets initiative.\n\nMOVE: 3 MP, or 4 on roads only. Forest costs 2 (Ranger: 1). Swamp ends movement. Occupied, mountain and water hexes block travel. Green rings show legal destinations.\n\nCAPTURE: Minor Towers and Settlements take one action. Ancient Towers require Begin then Complete on your next action; disruption cancels the commitment. Owned sites pay income at Resolution.\n\nCOMBAT: Adjacent target > sealed stances > simultaneous reveal > attacker Fate > defender Fate > damage/displacement. Assault +2, Guard +1 and damage protection, Counter +3 versus Assault / -1 otherwise, Trick costs 1 Fate and counters Guard/Counter. Ties defend.\n\nECONOMY: Trade at friendly/neutral Settlements or the Wandering Market. Control a Settlement to buy up to three equipment items in Planning. Explore Ruins for Relics and rewards; 2 Fate reveals two bonuses to choose from.\n\nCONQUEST: Hold all four Ancient Towers including Worldspire through the next Resolution. DOMINION: Hold both Settlements, an unblocked road network and 15 Gold through the next Resolution. ASCENSION: Bring 3 Relics to Worldspire, Begin Ritual, then Complete on your next action. Losing requirements cancels claims immediately.\n\nFATE: Capped at 5, +1 each Resolution, plus class and setback triggers once per round. RECOVERING: A downed hero returns to their Sanctuary, is temporarily untargetable and retains scheduled actions.\n\nCAMERA: WASD pan, Q/E rotate, wheel zoom, F/Home focus. Hover actions and faction cards for detail. Save manually or continue the most recent round autosave."
	pass_dialog = ConfirmationDialog.new()
	pass_dialog.title = "Pass this action?"
	pass_dialog.dialog_text = "This action will be lost. Your next action still follows initiative order."
	pass_dialog.confirmed.connect(func() -> void: _command({"type": "pass", "player_id": rules.current_actor()}))
	add_child(pass_dialog)
	load_dialog = AcceptDialog.new()
	load_dialog.title = "Continue a saved realm"
	var load_choices := VBoxContainer.new()
	load_choices.add_child(_label("Loading replaces the current table. Save first to retain it.", 14, MUTED))
	load_choices.add_child(_button("load_manual", "Load manual save", func() -> void: _load_game(MANUAL_SAVE)))
	load_choices.add_child(_button("load_auto", "Load round autosave", func() -> void: _load_game(AUTO_SAVE)))
	load_dialog.add_child(load_choices)
	add_child(load_dialog)

func _build_debug() -> void:
	debug_panel = _panel(Color("102128"), 16)
	debug_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	debug_panel.offset_left = -332
	debug_panel.offset_right = 333
	debug_panel.offset_top = -205
	debug_panel.offset_bottom = 205
	debug_panel.visible = false
	add_child(debug_panel)
	var stack := VBoxContainer.new()
	debug_panel.add_child(stack)
	stack.add_child(_label("DEVELOPER INSPECTOR", 19, GOLD))
	debug_text = _rich(250)
	stack.add_child(debug_text)
	var row := HBoxContainer.new()
	stack.add_child(row)
	row.add_child(_button("debug_advance", "Advance safe phase", func() -> void: _command({"type": "advance"})))
	row.add_child(_button("same_seed", "Replay same seed", _regenerate))
	row.add_child(_button("snapshot", "Save snapshot", _save_snapshot))
	var options := HBoxContainer.new()
	stack.add_child(options)
	var motion := CheckButton.new()
	motion.text = "Reduced motion"
	motion.toggled.connect(func(value: bool) -> void: reduced_motion = value; board.motion = not value)
	options.add_child(motion)
	options.add_child(_button("bot_step", "Bot step", func() -> void:
		var command: Dictionary = Bot.choose(rules)
		if not command.is_empty(): _command(command)))
	options.add_child(_button("debug_close", "Close", _toggle_debug))

func _build_welcome() -> void:
	welcome = _panel(Color("192f37"), 30)
	welcome.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	welcome.offset_left = -265
	welcome.offset_right = 265
	welcome.offset_top = -225
	welcome.offset_bottom = 225
	add_child(welcome)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 14)
	welcome.add_child(stack)
	stack.add_child(_label("YOUR TABLE AWAITS", 12, GOLD))
	stack.add_child(_label("Four heroes. One shattered realm.", 23))
	stack.add_child(_label("Ranger · Warlord · Merchant · Cultist\n\nClaim Ancient Towers, build a trading dominion,\nor bring three Relics to the Worldspire.", 15, MUTED))
	mode_select = OptionButton.new()
	mode_select.add_item("Local sandbox · control all four heroes")
	mode_select.add_item("Solo · one human and three bots")
	mode_select.add_item("Hotseat · four humans with private handoffs")
	buttons.mode_select = mode_select
	stack.add_child(mode_select)
	seat_select = OptionButton.new()
	for value: String in ["P1 · Ranger", "P2 · Warlord", "P3 · Merchant", "P4 · Cultist"]: seat_select.add_item(value)
	buttons.seat_select = seat_select
	seat_select.tooltip_text = "Your hero in Solo mode. All heroes remain inspectable."
	stack.add_child(seat_select)
	stack.add_child(_button("start", "Enter the realm  >", func() -> void:
		if local_mode == "network": _leave_network()
		local_mode = ["sandbox", "solo", "hotseat"][mode_select.selected]
		human_seat = "p%d" % (seat_select.selected + 1)
		viewer = human_seat if local_mode == "solo" else "p1"
		started = true
		welcome.hide()
		if rules.state.data.phase == "world": _command({"type": "advance"})
		else: _refresh()))
	stack.add_child(_button("welcome_load", "Continue a saved game", _open_load))

func _build_decision_ui() -> void:
	handoff = Control.new()
	handoff.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	handoff.visible = false
	add_child(handoff)
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.07, 0.09, 0.97)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	handoff.add_child(dim)
	var panel := _panel(Color("20373c"), 28)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -275
	panel.offset_right = 275
	panel.offset_top = -120
	panel.offset_bottom = 120
	handoff.add_child(panel)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 18)
	panel.add_child(stack)
	stack.add_child(_label("PRIVATE DECISION", 12, GOLD))
	handoff_label = _label("", 21)
	stack.add_child(handoff_label)
	stack.add_child(_label("Pass control to this player.\nStances stay sealed until both players have chosen.", 15, MUTED))
	stack.add_child(_button("handoff", "I am ready to choose", func() -> void:
		decision_ack = pending_handoff_key
		var decision_owner: String = _decision_player()
		if not decision_owner.is_empty(): viewer = decision_owner
		handoff.hide()
		_refresh()))
	planning_dialog = ConfirmationDialog.new()
	planning_dialog.title = "Private Planning"
	add_child(planning_dialog)
	var plan_stack := VBoxContainer.new()
	plan_stack.custom_minimum_size = Vector2(420, 245)
	planning_dialog.add_child(plan_stack)
	plan_stack.add_child(_label("Preparations resolve together after all seats are Ready.", 13, MUTED))
	planning_push = CheckBox.new()
	planning_push.text = "Initiative Push: 2 Fate for +2 initiative"
	plan_stack.add_child(planning_push)
	plan_stack.add_child(_label("Ranger Snare · 1 Power · stops an entering enemy", 13))
	planning_snare = OptionButton.new()
	plan_stack.add_child(planning_snare)
	plan_stack.add_child(_label("Cultist Prepared Hex · 1 Power · target's next combat die -1", 13))
	planning_hex = OptionButton.new()
	plan_stack.add_child(planning_hex)
	plan_stack.add_child(_label("Equipment · control a Settlement · up to 3 items", 13))
	for slot: int in 3:
		var purchase_choice := OptionButton.new()
		plan_stack.add_child(purchase_choice)
		planning_purchases.append(purchase_choice)
		buttons["purchase_%d" % slot] = purchase_choice
	planning_purchase = planning_purchases[0]
	planning_dialog.confirmed.connect(_submit_plan)
	buttons.plan_confirm = planning_dialog.get_ok_button()

func _build_victory_ui() -> void:
	victory_panel = _panel(Color("1c343d"), 30)
	victory_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	victory_panel.offset_left = -300
	victory_panel.offset_right = 300
	victory_panel.offset_top = -180
	victory_panel.offset_bottom = 180
	victory_panel.hide()
	add_child(victory_panel)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 20)
	victory_panel.add_child(stack)
	stack.add_child(_label("THE REALM HAS CHOSEN", 13, GOLD))
	victory_text = _label("", 21)
	victory_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(victory_text)
	stack.add_child(_button("victory_continue", "Review the final board", func() -> void: victory_panel.hide(); _publish_bridge()))
	stack.add_child(_button("victory_export", "Export the full action log", _export_log))
	cinematic = _panel(Color("28423e"), 16)
	cinematic.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	cinematic.offset_left = -320
	cinematic.offset_right = 320
	cinematic.offset_top = 160
	cinematic.offset_bottom = 240
	cinematic.hide()
	add_child(cinematic)
	var row := HBoxContainer.new()
	cinematic.add_child(row)
	cinematic_text = _label("", 16, GOLD)
	cinematic_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cinematic_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(cinematic_text)
	row.add_child(_button("skip_effect", "Dismiss", func() -> void: cinematic.hide()))

func _build_settings() -> void:
	settings_dialog = AcceptDialog.new()
	settings_dialog.title = "Settings · saved on this device"
	buttons.settings_close = settings_dialog.get_ok_button()
	add_child(settings_dialog)
	var stack := VBoxContainer.new()
	stack.custom_minimum_size.x = 420
	stack.add_theme_constant_override("separation", 12)
	settings_dialog.add_child(stack)
	for channel: String in ["master", "music", "sfx", "ui"]:
		var row := HBoxContainer.new()
		stack.add_child(row)
		var label := _label(channel.to_upper(), 14, MUTED)
		label.custom_minimum_size.x = 100
		row.add_child(label)
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.05
		slider.value = preferences.values[channel]
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value_changed.connect(func(value: float) -> void: preferences.set_value(channel, value))
		row.add_child(slider)
	var motion := CheckButton.new()
	motion.text = "Reduced motion"
	buttons.reduced_motion = motion
	motion.button_pressed = preferences.values.reduced_motion
	motion.toggled.connect(func(value: bool) -> void: preferences.set_value("reduced_motion", value); _apply_preferences())
	stack.add_child(motion)
	var hints := CheckButton.new()
	hints.text = "Show first-time action hints"
	hints.button_pressed = preferences.values.hints
	hints.toggled.connect(func(value: bool) -> void: preferences.set_value("hints", value))
	stack.add_child(hints)
	stack.add_child(_label("Animation speed", 14, MUTED))
	var speed := OptionButton.new()
	buttons.settings_speed = speed
	for title_value: String in ["Relaxed · 0.5×", "Normal · 1×", "Fast · 2×"]: speed.add_item(title_value)
	speed.selected = [0.5, 1.0, 2.0].find(preferences.values.animation_speed)
	speed.item_selected.connect(func(index: int) -> void: preferences.set_value("animation_speed", [0.5, 1.0, 2.0][index]); _apply_preferences())
	stack.add_child(speed)
	stack.add_child(_label("Interface scale", 14, MUTED))
	var scale_choice := OptionButton.new()
	buttons.settings_scale = scale_choice
	for title_value: String in ["Compact · 85%", "Standard · 100%", "Large · 115% (1600×900 recommended)"]: scale_choice.add_item(title_value)
	scale_choice.selected = [0.85, 1.0, 1.15].find(preferences.values.ui_scale)
	scale_choice.item_selected.connect(func(index: int) -> void: preferences.set_value("ui_scale", [0.85, 1.0, 1.15][index]); _apply_preferences())
	stack.add_child(scale_choice)
	stack.add_child(_label("Music bus is ready for a future soundtrack.\nAll important cues also appear as text in the Chronicle.", 12, MUTED))

func _build_network_lobby() -> void:
	network_lobby = NetworkLobby.new()
	add_child(network_lobby)
	network_lobby.host_requested.connect(_host_network)
	network_lobby.join_requested.connect(_join_network)
	network_lobby.start_requested.connect(func() -> void:
		if network != null:
			var result: Dictionary = network.start_match()
			if not result.get("is_valid", result.get("ok", false)): network_lobby.show_error(result.get("message", str(result))))
	network_lobby.leave_requested.connect(_leave_network)

func _ensure_network() -> bool:
	if OS.has_feature("web"): return false
	if network != null: return true
	var service: GDScript = load("res://scripts/network/network_session.gd")
	if service == null: return false
	network = service.new()
	network.name = "NetworkSession"
	add_child(network)
	network.observation_updated.connect(_network_observation)
	network.lobby_updated.connect(_network_lobby_updated)
	network.command_result.connect(_network_result)
	network.connection_failed.connect(func(message: String) -> void: network_lobby.show_error(message); feedback.text = message)
	return true

func _host_network(port: int) -> void:
	if not _ensure_network(): return
	local_mode = "network"
	network_event_sequence = 0
	network_results.clear()
	var seed_value: int = int(seed_edit.text) if seed_edit.text.is_valid_int() else 20260922
	var error: Error = network.host_game(port, seed_value)
	if error != OK:
		_leave_network()
		network_lobby.show_error("Cannot host: " + error_string(error))

func _join_network(address: String, port: int, token: String) -> void:
	if not _ensure_network(): return
	local_mode = "network"
	network_event_sequence = 0
	network_results.clear()
	var error: Error = network.join_game(address, port, token)
	if error != OK:
		_leave_network()
		network_lobby.show_error("Cannot connect: " + error_string(error))
	else: network_lobby.status.text = "Connecting to %s:%d…" % [address, port]

func _network_lobby_updated(lobby: Dictionary) -> void:
	if network == null: return
	network_lobby.update_lobby(lobby, network.is_host, network.local_player_id, network.reconnect_token)

func _network_observation(view: Dictionary) -> void:
	if view.get("state", {}).is_empty(): return
	var first: bool = not rules is RemoteView
	var was_started: bool = started
	if first:
		rules = RemoteView.new(view)
		board.build(rules.state.data.map)
	else: rules.update(view)
	viewer = str(view.player_id)
	human_seat = viewer
	local_mode = "network"
	started = bool(view.get("started", false))
	selected_hex = "" if first else selected_hex
	move_mode = false
	target_mode = ""
	seed_edit.text = "Host realm"
	var events: Array = []
	for event: Dictionary in rules.state.data.get("events", []):
		if int(event.sequence) > network_event_sequence: events.append(event)
		network_event_sequence = maxi(network_event_sequence, int(event.sequence))
	_refresh(events)
	if started:
		welcome.hide()
		if first or not was_started: network_lobby.hide()
		if rules.state.data.phase == "victory": _show_victory()
	_network_lobby_updated(view.get("lobby", {}))

func _network_result(result: Dictionary) -> void:
	last_result = result.duplicate(true)
	network_results.append({"source": "network", "result": result.duplicate(true), "received_at": Time.get_datetime_string_from_system(true)})
	feedback.text = "%s · %s" % [result.get("reason_code", "Network"), result.get("message", "Host response received")]
	_publish_bridge()

func _leave_network() -> void:
	if network != null: network.disconnect_session()
	local_mode = "sandbox"
	started = false
	network_event_sequence = 0
	_new_game(20260922)
	welcome.show()
	network_lobby.hide()

func _apply_preferences() -> void:
	reduced_motion = preferences.values.reduced_motion
	board.motion = not reduced_motion
	board.set_meta("animation_speed", float(preferences.values.animation_speed))
	var scale_value: float = float(preferences.values.ui_scale)
	var actual: Vector2i = DisplayServer.window_get_size()
	if scale_value > 1.0 and (actual.x < 1472 or actual.y < 828): scale_value = 1.0
	get_tree().root.content_scale_size = Vector2i(roundi(1280.0 / scale_value), roundi(720.0 / scale_value))

func _refresh_victory(events: Array) -> void:
	var state: Dictionary = rules.state.data
	var threats: PackedStringArray = []
	for claim: Dictionary in state.get("victory_claims", {}).values():
		threats.append("%s claims %s — interrupt before R%d Resolution" % [String(claim.player_id).to_upper(), String(claim.route).capitalize(), int(claim.created_round) + 1])
	for id: String in state.get("commitments", {}):
		if state.commitments[id].kind == "ritual": threats.append("%s is performing the Ascension Ritual — interrupt before their next action" % id.to_upper())
	threat_label.text = "  |  ".join(threats)
	threat_label.visible = not threats.is_empty() and state.phase != "victory"
	if state.phase != "victory": victory_panel.hide()
	for event: Dictionary in events:
		if event.type in ["VictoryClaimCreated", "VictoryClaimCanceled", "RitualBegun", "RitualCanceled"]:
			preferences.cue()
			cinematic_text.text = "%s · %s" % [String(event.actor_id).to_upper(), String(event.type).capitalize()]
			cinematic_seconds = 1.2 if reduced_motion else 2.4
			cinematic.show()
		if event.type == "VictoryAchieved":
			preferences.cue()
			_show_victory()

func _show_victory() -> void:
	var victory: Dictionary = rules.state.data.get("victory", {})
	if victory.is_empty(): return
	cinematic.hide()
	var names: PackedStringArray = []
	for id: String in victory.winners: names.append("%s · %s" % [id.to_upper(), rules.state.data.heroes[id].name])
	victory_text.text = "%s\n\n%s victory · Round %d\n\n%d commands tell the story of this realm." % [" & ".join(names), String(victory.route).capitalize(), victory.round, rules.state.data.command_sequence]
	victory_panel.show()

func _open_plan() -> void:
	planning_seat = viewer
	var options: Dictionary = rules.legal_actions(viewer).get("submit_plan", {})
	planning_dialog.title = "%s %s — private plan" % [viewer.to_upper(), rules.state.data.heroes[viewer].name]
	planning_push.disabled = not options.get("initiative_push", false)
	planning_push.button_pressed = false
	planning_snare.clear()
	planning_snare.add_item("No Snare")
	for hex: String in options.get("snare_targets", {}):
		planning_snare.add_item(hex)
		planning_snare.set_item_metadata(planning_snare.item_count - 1, hex)
	planning_snare.disabled = planning_snare.item_count == 1
	planning_hex.clear()
	planning_hex.add_item("No Prepared Hex")
	for id: String in options.get("prepared_hex_targets", {}):
		planning_hex.add_item("%s %s" % [id.to_upper(), options.prepared_hex_targets[id].name])
		planning_hex.set_item_metadata(planning_hex.item_count - 1, id)
	planning_hex.disabled = planning_hex.item_count == 1
	for slot: int in planning_purchases.size():
		var choice: OptionButton = planning_purchases[slot]
		choice.clear()
		choice.add_item("Slot %d · no purchase" % (slot + 1))
		for id: String in options.get("purchases", {}):
			var item: Dictionary = options.purchases[id]
			choice.add_item("%s · %s Gold" % [item.get("name", id), item.get("cost", 4)])
			choice.set_item_metadata(choice.item_count - 1, id)
			choice.get_popup().set_item_tooltip(choice.item_count - 1, item.get("description", ""))
		choice.disabled = choice.item_count == 1 or slot >= int(options.get("slots", 0))
	planning_dialog.popup_centered()

func _submit_plan() -> void:
	var plan: Dictionary = {}
	if planning_push.button_pressed: plan.initiative_push = true
	if planning_snare.selected > 0: plan.snare = planning_snare.get_item_metadata(planning_snare.selected)
	if planning_hex.selected > 0: plan.prepared_hex = planning_hex.get_item_metadata(planning_hex.selected)
	var purchases: Array[String] = []
	for choice: OptionButton in planning_purchases:
		if not choice.disabled and choice.selected > 0: purchases.append(choice.get_item_metadata(choice.selected))
	if not purchases.is_empty(): plan.purchases = purchases
	_command({"type": "submit_plan", "player_id": planning_seat, "plan": plan})

func _decision_player() -> String:
	var state: Dictionary = rules.state.data
	var ids: Array = ["p1", "p2", "p3", "p4"]
	var combat: Dictionary = state.get("pending_combat", {})
	if not combat.is_empty() and combat.get("attacker_id", "") in ids:
		ids.erase(combat.attacker_id)
		ids.push_front(combat.attacker_id)
	for id: String in ids:
		var legal: Dictionary = rules.legal_actions(id)
		for kind: String in ["choose_stance", "resolve_reaction", "spend_fate", "decline_fate", "displace", "choose_reward"]:
			if legal.has(kind): return id
	return ""

func _decision_key() -> String:
	return "%s:%s" % [rules.state.data.state_version, _decision_player()]

func _handoff_for(actor: String, key: String) -> void:
	if decision_ack == key: return
	pending_handoff_key = key
	handoff_label.text = "Hand control to %s · %s" % [actor.to_upper(), rules.state.data.heroes[actor].name]
	handoff.show()

func _refresh_decision_actions(actor: String) -> void:
	var legal: Dictionary = rules.legal_actions(actor)
	var combat: Dictionary = rules.state.data.get("pending_combat", {})
	instruction.text = "%s · %s's decision" % [actor.to_upper(), rules.state.data.heroes[actor].name]
	if legal.has("choose_stance"):
		instruction.text += " · choose a secret stance"
		var descriptions: Dictionary = {"assault": "+2 total; losing adds 1 damage", "guard": "+1 total; losing damage reduced by 1", "counter": "+3 against Assault, otherwise -1", "trick": "1 Fate; +2 against Guard/Counter"}
		for stance: String in legal.choose_stance.choices:
			var button := _button("stance_" + stance, stance.capitalize(), func() -> void: _command({"type": "choose_stance", "player_id": actor, "stance": stance}))
			button.tooltip_text = descriptions.get(stance, "")
			actions.add_child(button)
		if decision_ack != _decision_key() and local_mode not in ["solo", "network"]:
			_handoff_for(actor, _decision_key())
	elif legal.has("resolve_reaction"):
		var reaction: Dictionary = rules.state.data.get("pending_reaction", {})
		instruction.text += " · " + String(reaction.get("kind", "reaction")).replace("_", " ").capitalize()
		for choice: String in legal.resolve_reaction.choices:
			actions.add_child(_button("reaction_" + choice, choice.capitalize(), func() -> void: _command({"type": "resolve_reaction", "player_id": actor, "choice": choice})))
	elif legal.has("decline_fate"):
		instruction.text += " · reroll your own die for 1 Fate, or keep the roll"
		var reroll := _button("reroll", "Reroll · 1 Fate", func() -> void: _command({"type": "spend_fate", "player_id": actor}))
		reroll.disabled = not legal.has("spend_fate")
		actions.add_child(reroll)
		actions.add_child(_button("decline_fate", "Keep this roll", func() -> void: _command({"type": "decline_fate", "player_id": actor})))
	elif legal.has("displace"):
		instruction.text += " · choose your displacement hex"
		for hex: String in legal.displace.targets:
			actions.add_child(_button("displace_" + hex, hex, func() -> void: _command({"type": "displace", "player_id": actor, "target": hex})))
	elif legal.has("choose_reward"):
		instruction.text += " · Fate reveals two rewards; choose one"
		for choice in legal.choose_reward.choices:
			var choice_id: String = str(choice)
			var reward: Dictionary = legal.choose_reward.choices[choice_id]
			actions.add_child(_button("reward_" + choice_id, reward.get("label", choice_id.replace("_", " ").capitalize()), func() -> void: _command({"type": "choose_reward", "player_id": actor, "choice": choice_id})))
	if combat.get("stage", "") != "stances" and not combat.is_empty():
		selected_panel.custom_minimum_size.y = 210
		var stances: Dictionary = combat.get("stances", {})
		selected_panel.text = "[color=#dec18a][b]Combat revealed[/b][/color]\n%s: %s / %s: %s\n%s" % [String(combat.attacker_id).to_upper(), stances.get(combat.attacker_id, ""), String(combat.defender_id).to_upper(), stances.get(combat.defender_id, ""), _combat_summary(combat.get("calculation", {}))]

func _combat_summary(calculation: Dictionary) -> String:
	if calculation.is_empty(): return "Waiting for the final rolls."
	return "ATK %s + stance %s + modifiers %s + die %s = %s\nDEF %s + stance %s + modifiers %s + die %s = %s\nMargin %s · Damage %s / %s\n%s" % [calculation.get("attacker_stat", "?"), calculation.get("attacker_stance_modifier", 0), calculation.get("attacker_modifier", 0), calculation.get("attacker_die", "?"), calculation.get("attacker_total", "?"), calculation.get("defender_stat", "?"), calculation.get("defender_stance_modifier", 0), calculation.get("defender_modifier", 0), calculation.get("defender_die", "?"), calculation.get("defender_total", "?"), calculation.get("margin", "?"), calculation.get("attacker_damage", 0), calculation.get("defender_damage", 0), String(calculation.get("outcome_band", "")).replace("_", " ")]

func _new_game(seed_value: int) -> void:
	rules = Rules.new(seed_value)
	viewer = human_seat if local_mode == "solo" else "p1"
	selected_hex = ""
	move_mode = false
	target_mode = ""
	seed_edit.text = str(seed_value)
	board.build(rules.state.data.map)
	_refresh()

func _regenerate() -> void:
	if local_mode == "network":
		feedback.text = "Leave the online session before generating a local game."
		return
	if not seed_edit.text.is_valid_int():
		feedback.text = "Enter an integer seed."
		return
	if int(seed_edit.text) < -2147483648 or int(seed_edit.text) > 2147483647:
		feedback.text = "Seed must be between -2147483648 and 2147483647."
		return
	_new_game(int(seed_edit.text))
	feedback.text = "World regenerated from seed %s. All seats reset." % seed_edit.text
	_publish_bridge()

func _command(command: Dictionary, source: String = "presentation") -> Dictionary:
	command["expected_version"] = rules.state.data.state_version if not command.has("expected_version") else command.expected_version
	if local_mode == "network":
		network.submit(command)
		return last_result
	last_result = logger.execute(rules, command, source)
	if last_result.is_valid:
		move_mode = false
		target_mode = ""
		var actor: String = rules.current_actor()
		if local_mode == "solo": viewer = human_seat
		elif not actor.is_empty(): viewer = actor
		feedback.text = "Accepted · %s · state %s" % [command.type, rules.state.data.state_version]
		_refresh(last_result.get("events", []))
		for event: Dictionary in last_result.get("events", []):
			if event.type in ["ResolutionCompleted", "RoundStarted", "VictoryAchieved"]:
				_save_game(AUTO_SAVE, true)
				break
	else:
		feedback.text = "%s · %s" % [last_result.reason_code, last_result.get("message", "Command rejected")]
		_publish_bridge()
	return last_result

func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()

func _refresh(events: Array = []) -> void:
	var state: Dictionary = rules.state.data
	if local_mode == "hotseat" and state.phase == "planning":
		for id: String in state.heroes:
			if id not in state.ready:
				viewer = id
				break
	session_label.text = "ONLINE · %s" % viewer.to_upper() if local_mode == "network" else ("SOLO · %s + 3 BOTS" % human_seat.to_upper() if local_mode == "solo" else ("HOTSEAT · FOUR HUMANS" if local_mode == "hotseat" else "LOCAL · ALL FOUR SEATS"))
	for id: String in ["save_game", "load_game", "regenerate", "copy_seed", "snapshot", "bot_step", "debug_advance", "same_seed"]:
		buttons[id].disabled = local_mode == "network"
	phase_title.text = "ROUND %02d  /  %s" % [state.round_number, String(state.phase).replace("_", " ").to_upper()]
	_clear(phase_steps)
	for phase: String in PHASES:
		var step := _label(phase.replace("_", " ").capitalize(), 12, GOLD if state.phase == phase else MUTED)
		step.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		phase_steps.add_child(step)
	_clear(initiative)
	initiative.add_child(_label("INITIATIVE  ", 11, MUTED))
	if state.initiative_order.is_empty():
		initiative.add_child(_label("Revealed after all four plans are ready", 12, MUTED))
	for id: String in state.initiative_order:
		var color: Color = Board.TEAM[int(id.substr(1)) - 1]
		var prefix: String = "> " if rules.current_actor() == id else ""
		var score: int = int(state.initiative_scores.get(id, 0))
		if state.phase == "cycle_2": score += int(state.get("cycle_2_modifiers", {}).get(id, 0))
		var entry: String = "%s%s %s  [%s]     " % [prefix, id.to_upper(), state.heroes[id].name, score]
		if state.phase == "cycle_1" and not state.get("cycle_2_modifiers", {}).is_empty():
			entry += "\nNext: #%d  [%d]" % [state.next_cycle_order.find(id) + 1, score + int(state.cycle_2_modifiers.get(id, 0))]
		initiative.add_child(_label(entry, 13, color))
	_refresh_cards()
	_refresh_selection()
	_refresh_actions()
	_refresh_journal()
	_refresh_victory(events)
	board.sync(state, viewer, events)
	var targets: Dictionary = {}
	if move_mode and not rules.current_actor().is_empty():
		targets = rules.legal_actions(rules.current_actor()).get("move", {}).get("targets", {})
	elif target_mode == "attack":
		for option: Dictionary in rules.legal_actions(rules.current_actor()).get("attack", {}).get("targets", {}).values():
			targets[option.hex] = {"cost": 0, "path": [], "road_only": false}
	elif target_mode == "forced_march":
		targets = rules.legal_actions(rules.current_actor()).get("special", {}).get("choices", {}).get("forced_march", {}).get("targets", {})
	board.set_targets(targets, Color("e78d7d") if target_mode == "attack" else Color("82bf8d"))
	_refresh_debug()
	_publish_bridge.call_deferred()

func _refresh_cards() -> void:
	_clear(cards)
	var state: Dictionary = rules.state.data
	for id: String in state.heroes:
		var hero: Dictionary = state.heroes[id]
		var color: Color = Board.TEAM[int(id.substr(1)) - 1]
		var panel := _panel(Color("263d42") if viewer == id else Color("1a2f37"), 4)
		cards.add_child(panel)
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 0)
		panel.add_child(stack)
		var select := _button("seat_" + id, "%s   %s%s" % [id.to_upper(), hero.name, "  *" if rules.current_actor() == id else ""], func() -> void:
			if local_mode not in ["solo", "network"]: viewer = id
			selected_hex = rules.state.data.heroes[id].hex
			board.selected = selected_hex
			board.focus_hex(selected_hex)
			_refresh())
		select.add_theme_color_override("font_color", color)
		select.add_theme_font_size_override("font_size", 14)
		for style_name in ["normal", "hover", "pressed", "focus"]:
			var style: StyleBoxFlat = theme.get_stylebox(style_name, "Button").duplicate()
			style.content_margin_top = 2
			style.content_margin_bottom = 2
			select.add_theme_stylebox_override(style_name, style)
		select.alignment = HORIZONTAL_ALIGNMENT_LEFT
		stack.add_child(select)
		var recovering: bool = hero.statuses.has("recovering") or hero.statuses.has("Recovering")
		stack.add_child(_label("HP %d/%d   ATK %d   DEF %d   SPD %d" % [hero.hp, hero.max_hp, hero.attack + Equipment.passive_bonus(hero, "attack") - int(recovering), hero.defence + Equipment.passive_bonus(hero, "defence") - int(recovering), hero.speed], 10, MUTED))
		if recovering: select.tooltip_text = "Recovering: untargetable until next World phase; -1 Attack and Defence. Scheduled actions are retained."
		stack.add_child(_label("Gold %d    Power %d    Relics %d" % [hero.gold, hero.power, hero.relics.size()], 11))
		var fate_row := HBoxContainer.new()
		stack.add_child(fate_row)
		fate_row.add_child(_label("Fate %d/5 " % hero.fate, 11, color))
		for index in 5:
			var pip := ColorRect.new()
			pip.custom_minimum_size = Vector2(9, 7)
			pip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			pip.color = color if index < hero.fate else Color("3d5156")
			fate_row.add_child(pip)
		var progress: Dictionary = rules.victory_progress(id)
		if viewer == id: stack.add_child(_label("Ancients %d/4 · Markets %d/2 · Relics %d/3" % [progress.conquest.controlled, progress.dominion.settlements, progress.ascension.relics], 10, color))
		select.tooltip_text += "\nConquest: hold 4 Ancient Towers including Worldspire through the next Resolution.\nDominion: 2 Settlements, an unblocked road network and 15 Gold through next Resolution.\nAscension: 3 Relics, Begin and Complete Ritual at Worldspire."
		if not hero.upgrades.is_empty(): select.tooltip_text += "\nEquipment: " + ", ".join(hero.upgrades)

func _refresh_actions() -> void:
	_clear(actions)
	handoff.hide()
	var state: Dictionary = rules.state.data
	var decision: String = _decision_player()
	if not decision.is_empty():
		if local_mode == "solo" and decision != human_seat:
			instruction.text = "%s · %s is deciding…" % [decision.to_upper(), state.heroes[decision].name]
			return
		_refresh_decision_actions(decision)
		return
	if local_mode == "network":
		if not network.started:
			instruction.text = "Online lobby · the host will start the match."
			return
		if not state.get("pending_combat", {}).is_empty() or not state.get("pending_reaction", {}).is_empty() or not state.get("pending_exploration", {}).is_empty():
			instruction.text = "Waiting for another player's decision."
			return
		if state.phase in ["world", "initiative", "bonus", "resolution"]:
			instruction.text = "The host is resolving %s…" % state.phase
			return
	match state.phase:
		"world":
			instruction.text = "A new round begins. Survey the realm, then prepare your plans."
			actions.add_child(_button("advance", "Begin Planning  >", func() -> void: _command({"type": "advance"})))
		"planning":
			instruction.text = "Planning · prepare equipment and abilities, then Ready to reveal initiative together."
			for id: String in state.heroes:
				var ready: bool = id in state.ready
				var button := _button("ready_" + id, "%s %s" % [id.to_upper(), "Ready OK" if ready else "Ready"], func() -> void: _command({"type": "ready", "player_id": id}))
				button.disabled = ready or (local_mode == "solo" and id != human_seat) or (local_mode in ["hotseat", "network"] and id != viewer)
				actions.add_child(button)
			var plan_button := _button("plan", "Plan for %s" % viewer.to_upper(), _open_plan)
			plan_button.disabled = viewer in state.ready
			actions.add_child(plan_button)
			if local_mode == "hotseat": _handoff_for(viewer, "plan:%s:%s" % [state.round_number, viewer])
		"initiative":
			instruction.text = "Initiative revealed · Speed + d3. Each hero acts once per cycle."
			actions.add_child(_button("advance", "Begin Action Cycle 1  >", func() -> void: _command({"type": "advance"})))
		"cycle_1", "cycle_2":
			var actor: String = rules.current_actor()
			if (local_mode == "solo" and actor != human_seat) or (local_mode == "network" and actor != viewer):
				instruction.text = "%s · %s is taking their action…" % [actor.to_upper(), state.heroes[actor].name]
				return
			var legal: Dictionary = rules.legal_actions(actor)
			instruction.text = "%s · %s's action · select Move, then a highlighted hex." % [actor.to_upper(), state.heroes[actor].name]
			var move_button := _button("move", "Move" + (" *" if move_mode else ""), func() -> void: target_mode = ""; move_mode = not move_mode; _refresh())
			move_button.tooltip_text = "Spend your action traveling. Green rings show reachable hexes; hover for path and movement cost."
			move_button.disabled = not legal.has("move")
			actions.add_child(move_button)
			var attack := _button("attack", "Attack", func() -> void: move_mode = false; target_mode = "attack"; _refresh())
			attack.disabled = not legal.has("attack")
			attack.tooltip_text = "Attack an adjacent hero or monster. Both participants choose a sealed stance before dice and Fate windows."
			actions.add_child(attack)
			var capture_label: String = "Complete capture" if legal.get("capture", {}).get("completing", false) else ("Begin capture" if legal.get("capture", {}).get("commitment", false) else "Capture")
			var capture := _button("capture", capture_label, func() -> void: _command({"type": "capture", "player_id": actor}))
			capture.disabled = not legal.has("capture")
			capture.tooltip_text = "Minor Towers capture in one action. Ancient Towers require Begin, then Complete on your next scheduled action."
			actions.add_child(capture)
			var upgrade := _button("upgrade", "Upgrade", func() -> void: _command({"type": "upgrade", "player_id": actor}))
			upgrade.disabled = not legal.has("upgrade")
			upgrade.tooltip_text = "Upgrade the owned location you occupy: Level 2 costs 3 Gold (+1 Defence); Level 3 costs 5 Gold (+1 income)."
			actions.add_child(upgrade)
			if legal.has("explore"):
				var explore := _button("explore", "Explore", func() -> void: _command({"type": "explore", "player_id": actor}))
				explore.tooltip_text = legal.explore.get("description", "Collect unclaimed rewards here.")
				actions.add_child(explore)
				if legal.explore.get("alternatives_available", false):
					actions.add_child(_button("explore_fate", "Explore · 2 Fate", func() -> void: _command({"type": "explore", "player_id": actor, "use_fate": true})))
			for direction: String in legal.get("trade", {}).get("choices", {}):
				var terms: Dictionary = legal.trade.choices[direction]
				var label: String = "%s %s → %s %s" % [terms.cost, terms.cost_resource.capitalize(), terms.gain, terms.gain_resource.capitalize()]
				actions.add_child(_button("trade_" + direction, label, func() -> void: _command({"type": "trade", "player_id": actor, "direction": direction})))
			for ritual: String in ["begin_ritual", "complete_ritual"]:
				if legal.has(ritual): actions.add_child(_button(ritual, ritual.replace("_", " ").capitalize(), func() -> void: _command({"type": ritual, "player_id": actor})))
			for special: String in legal.get("special", {}).get("choices", {}):
				var button := _button("special_" + special, special.replace("_", " ").capitalize(), func() -> void:
					if special == "forced_march":
						move_mode = false
						target_mode = "forced_march"
						_refresh()
					else: _command({"type": "special", "player_id": actor, "special_id": special}))
				actions.add_child(button)
			actions.add_child(_button("pass", "Pass...", func() -> void: pass_dialog.popup_centered()))
			actions.add_child(_button("cancel", "Cancel", func() -> void: move_mode = false; target_mode = ""; _refresh()))
			if target_mode == "attack": instruction.text = "%s · select an adjacent highlighted hero or monster to attack." % actor.to_upper()
			if target_mode == "forced_march": instruction.text = "%s · Forced March: select a destination · 1 Power, +2 next-cycle initiative." % actor.to_upper()
			if preferences.values.hints and state.round_number == 1 and target_mode.is_empty() and not move_mode:
				feedback.text = "First move: select Move, then a green hex. Inspect nearby towers; Capture becomes available when you arrive."
		"bonus":
			instruction.text = "Both ordinary cycles are complete. No bonus actions are granted."
			actions.add_child(_button("advance", "Continue to Resolution  >", func() -> void: _command({"type": "advance"})))
		"resolution":
			instruction.text = "Resolution · pay location income, recover Health, gain capped Fate."
			actions.add_child(_button("advance", "Resolve round  >", func() -> void: _command({"type": "advance"})))
		"victory":
			var victory: Dictionary = state.get("victory", {})
			instruction.text = "%s wins · %s · Round %s" % [", ".join(victory.get("winners", [])), String(victory.get("route", "victory")).capitalize(), victory.get("round", state.round_number)]
			if local_mode == "network": actions.add_child(_button("leave_match", "Leave online match", _leave_network))
			else: actions.add_child(_button("new_match", "Play another realm", func() -> void: _new_game(int(seed_edit.text) + 1); welcome.show()))
			actions.add_child(_button("victory_log", "Export match log", _export_log))

func _select_hex(hex: String) -> void:
	selected_hex = hex
	if target_mode == "attack":
		var actor: String = rules.current_actor()
		var targets: Dictionary = rules.legal_actions(actor).get("attack", {}).get("targets", {})
		for id: String in targets:
			if targets[id].hex == hex:
				_command({"type": "attack", "player_id": actor, "target_id": id})
				return
		feedback.text = "Select a highlighted adjacent attack target."
	elif target_mode == "forced_march":
		_command({"type": "special", "special_id": "forced_march", "player_id": rules.current_actor(), "target": hex})
	elif move_mode:
		var actor: String = rules.current_actor()
		if not actor.is_empty():
			_command({"type": "move", "player_id": actor, "target": hex})
	else:
		_refresh_selection()
		_publish_bridge()

func _hover_hex(hex: String) -> void:
	if hex.is_empty():
		hover_label.text = "WASD pan · Q/E rotate · wheel zoom · F focus"
		return
	var tile: Dictionary = rules.state.data.map.hexes[hex]
	var info: String = "%s · %s · %s" % [hex, String(tile.terrain).capitalize(), tile.region]
	if target_mode == "attack":
		for target: Dictionary in rules.legal_actions(rules.current_actor()).get("attack", {}).get("targets", {}).values():
			if target.hex == hex: info += "  |  Attack %s · HP %d · base Defence %d" % [target.name, target.hp, target.defence]
	elif board.reachable.has(hex):
		var route: Dictionary = board.reachable[hex]
		info += "  |  %d MP  ·  %s" % [route.cost, " > ".join(route.path)]
		if route.road_only: info += "  [road]"
	hover_label.text = info
	_refresh_debug()

func _refresh_selection() -> void:
	selected_panel.custom_minimum_size.y = 123
	var state: Dictionary = rules.state.data
	if selected_hex.is_empty():
		selected_panel.text = "[color=#dec18a][b]Explore the board[/b][/color]\n\nSelect a hex or faction card.\nGreen rings: legal movement\nGold border: selected hex\nP1–P4 banners: ownership"
		return
	var tile: Dictionary = state.map.hexes[selected_hex]
	var value: String = "[color=#dec18a][b]%s[/b][/color]  %s\n%s\n" % [String(tile.terrain).capitalize(), selected_hex, tile.region]
	var location_id: String = tile.get("location_id", "")
	if not location_id.is_empty():
		var location: Dictionary = state.map.locations[location_id]
		var discovered: bool = viewer in location.get("discovered_by", [])
		var visible: bool = location.kind in ["worldspire", "ancient_tower"] or not String(location.owner_id).is_empty() or discovered
		if visible:
			value += "\n[b]%s[/b]\n%s · Level %d\nOwner: %s" % [location.name, String(location.kind).replace("_", " ").capitalize(), location.level, location.owner_id if not String(location.owner_id).is_empty() else "Neutral"]
			if discovered and rules.definitions.tower_traits.has(location.get("trait", "")):
				var trait_definition: Dictionary = rules.definitions.tower_traits[location.trait]
				value += "\n[color=#dec18a]%s[/color]: %s" % [trait_definition.name, trait_definition.description]
			if location.get("exhausted", false): value += "\nExplored · no rewards remain."
			if location.get("cleared", false): value += "\nCamp cleared."
			for monster: Dictionary in state.get("monsters", {}).values():
				if monster.hex == selected_hex:
					value += "\n%s · HP %s/%s · DEF %s" % [monster.name, monster.hp, monster.max_hp, monster.defence]
		else: value += "\nUndiscovered location\nApproach within 2 hexes."
	else:
		value += "\n%s" % {"plains": "Open ground · 1 movement point", "forest": "Forest · 2 MP (Ranger: 1)\nDefender gains +1 Defence", "swamp": "Swamp · ends movement", "water": "Water · impassable", "mountain": "Mountain · impassable"}.get(tile.terrain, "")
	for warning: Dictionary in state.get("traps", {}).values():
		if warning.hex == selected_hex: value += "\n[color=#dec18a]Warning: a prepared trap is present.[/color]"
	for id: String in state.get("commitments", {}):
		if state.commitments[id].hex == selected_hex: value += "\n[color=#dec18a]%s is %s. Complete on their next action.[/color]" % [id.to_upper(), "performing a Ritual" if state.commitments[id].kind == "ritual" else "capturing"]
	if state.get("market_hex", "") == selected_hex: value += "\nWandering Market · Trade until Resolution."
	if tile.has("movement_terrain"): value += "\nCursed Ground · movement uses Forest costs."
	if state.get("ground_loot", {}).has(selected_hex): value += "\nUnclaimed loot · Explore to collect."
	for hero: Dictionary in state.heroes.values():
		if hero.hex != selected_hex: continue
		value += "\n\n[b]%s[/b] · Relics %d/3" % [hero.name, hero.relics.size()]
		if not hero.upgrades.is_empty(): value += "\nEquipment: " + ", ".join(hero.upgrades).replace("_", " ")
		var tracks: Dictionary = rules.victory_progress(hero.id)
		value += "\nAncients %d/4 · Settlements %d/2\nRoad network: %s · Gold %d/15" % [tracks.conquest.controlled, tracks.dominion.settlements, "connected" if tracks.dominion.connected else "incomplete", hero.gold]
		if hero.id == viewer and hero.class_id == "cultist": value += "\nOccult hints: " + ", ".join(hero.get("occult_hint", {}).get("regions", []))
	selected_panel.text = value

func _refresh_journal() -> void:
	var lines: PackedStringArray = []
	var events: Array = rules.state.data.events
	for index in range(maxi(0, events.size() - 90), events.size()):
		var event: Dictionary = events[index]
		if event.get("visibility", "public") != "public": continue
		if event.type in ["WorldEventSelected", "WorldEventResolved"]: continue
		if journal_filter == "actions" and event.type not in ["ActionStarted", "HeroMoved", "LocationCaptured", "ActionPassed"]: continue
		if journal_filter == "economy" and event.type not in ["IncomeGranted", "FateGained", "LocationCaptured", "TradeCompleted", "EquipmentPurchased", "RuinExplored", "RelicCollected"]: continue
		var description: String = _event_description(event)
		lines.append("[color=#7e9a9a]#%03d · R%d[/color]  %s\n%s" % [event.sequence, event.round, event.actor_id.to_upper(), description])
	log_text.text = "\n\n".join(lines)

func _event_description(event: Dictionary) -> String:
	var data: Dictionary = event.data
	match event.type:
		"HeroMoved": return "Moved %s > %s" % [data.get("from", ""), data.get("to", data.get("target", ""))]
		"PhaseChanged": return "[color=#dec18a]%s[/color]" % String(data.get("phase", data.get("to", "Phase advanced"))).replace("_", " ").capitalize()
		"IncomeGranted": return "[color=#a3ceb2]Income[/color] · +%s %s from %s%s" % [data.get("amount", 0), String(data.get("resource", "")).capitalize(), String(data.get("location_id", "location")).replace("_", " "), " (cap reached)" if data.get("capped", false) else ""]
		"TradeCompleted":
			var offer: Dictionary = data.get("offer", {})
			return "Trade · %s %s → %s %s" % [offer.get("cost", 0), offer.get("cost_resource", ""), offer.get("gain", 0), offer.get("gain_resource", "")]
		"EquipmentPurchased", "EquipmentFound":
			var item: Dictionary = Equipment.definitions().get(data.get("upgrade_id", ""), {})
			return "%s · %s\n%s" % ["Purchased" if event.type == "EquipmentPurchased" else "Found", item.get("name", data.get("upgrade_id", "equipment")), item.get("description", "")]
		"WorldEventApplied": return "[color=#dec18a]%s[/color] · %s" % [data.get("name", "World event"), String(data.get("hex", data.get("region", data.get("location_id", "The realm changes"))))]
		"WorldEventSkipped": return "The first round begins without a world event." if data.get("reason", "") == "first_round" else "No world effect can be applied this round."
		"WorldEffectExpired": return "%s has ended." % String(data.get("event_id", "World effect")).replace("_", " ").capitalize()
		"RuinExplored": return "Ruin explored · %s\n%s" % [data.get("reward", {}).get("name", "Reward gained"), data.get("reward", {}).get("description", "")]
		"RelicCollected": return "[color=#dec18a]Relic collected[/color] · " + String(data.get("hex", ""))
		"GroundLootCollected": return "Recovered %s Gold and %d Relic(s)." % [data.get("gold", 0), data.get("relics", []).size()]
		"VictoryClaimCreated": return "[color=#dec18a]%s claim declared[/color]\nInterrupt before round %s Resolution." % [String(data.get("route", "")).capitalize(), data.get("required_round", "next")]
		"VictoryClaimCanceled": return "%s claim canceled · requirements lost." % String(data.get("route", "")).capitalize()
		"RitualBegun": return "[color=#dec18a]Ascension Ritual begun[/color]\nInterrupt before this hero's next action."
		"RitualCompleted": return "Ascension Ritual completed."
		"VictoryAchieved": return "[color=#dec18a]%s wins by %s[/color] in round %s." % [", ".join(data.get("winners", [])).to_upper(), String(data.get("route", "victory")).capitalize(), data.get("round", "")]
		"LocationCaptured": return "[color=#dec18a]Location captured[/color]  " + String(data.get("location_id", ""))
		"InitiativeRolled": return "Initiative  " + JSON.stringify(data)
		"StancesRevealed": return "[color=#dec18a]Stances revealed[/color]\n" + JSON.stringify(data)
		"CombatResolved": return "[color=#dec18a]Combat resolved[/color]\n" + _combat_summary(data.get("calculation", data))
		"CombatCalculationUpdated": return "Combat calculation\n" + _combat_summary(data)
		"FateWindowOpened": return "Fate window · %s may reroll for 1 Fate" % event.actor_id.to_upper()
		"LocationCaptureBegun": return "Ancient capture begun. Hold until the next action."
		"CommitmentCanceled": return "Capture commitment canceled: " + String(data.get("reason", "requirements lost"))
		"LocationCaptureCanceled": return "Capture canceled · " + String(data.get("cause", "requirements lost")).replace("_", " ")
		"LocationDiscovered": return "Discovered " + String(data.get("kind", "location")).replace("_", " ") + " at " + String(data.get("hex", ""))
		"PlayerReady": return "Ready for initiative"
		"FateGained": return "Fate gained · " + String(data.get("cause", "round recovery"))
		"ActionStarted": return "Action · " + String(data.get("action", data.get("type", ""))).capitalize()
		"RoundStarted": return "A new round begins."
		_: return String(event.type).capitalize() + ("  " + JSON.stringify(data) if not data.is_empty() else "")

func _refresh_debug() -> void:
	if not debug_panel.visible: return
	var state: Dictionary = rules.state.data
	debug_text.text = "[b]Seed[/b] %s    [b]FPS[/b] %d    [b]Version[/b] %s\n[b]Round / Phase / Cycle[/b] %s / %s / %s\n[b]Actor[/b] %s  [b]Selection[/b] %s\n[b]Checksum[/b]\n%s\n[b]RNG[/b] %s\n[b]Generation[/b] %s\n[b]Path[/b] %s\n[b]Log[/b] %s" % [state.get("master_seed", "Host only"), Engine.get_frames_per_second(), state.state_version, state.round_number, state.phase, state.action_cycle, rules.current_actor(), selected_hex, rules.checksum(), JSON.stringify(state.get("rng", {})), JSON.stringify(state.map.get("report", {})), hover_label.text, "user://logs/actions.jsonl"]

func _toggle_debug() -> void:
	debug_panel.visible = not debug_panel.visible
	_refresh_debug()
	_publish_bridge()

func _focus_actor() -> void:
	var actor: String = rules.current_actor()
	board.focus_hex(rules.state.data.heroes[viewer if actor.is_empty() else actor].hex)
	_publish_bridge()

func _save_snapshot() -> void:
	var text_value: String = JSON.stringify(rules.snapshot(), "  ")
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(text_value.to_utf8_buffer(), "shattered-realm-snapshot.json", "application/json")
	else:
		var file := FileAccess.open("user://snapshot.json", FileAccess.WRITE)
		if file: file.store_string(text_value)
	feedback.text = "Snapshot exported. CLI can inspect and continue the same rules state."

func _save_game(path: String, automatic: bool = false) -> void:
	var result: Dictionary = saves.write(path, rules.snapshot(), {"mode": local_mode, "human_seat": human_seat})
	if not automatic:
		feedback.text = "Saved · %s" % path if result.ok else "Save failed · %s" % result.get("message", result.get("error", "unknown"))
	_publish_bridge()

func _open_load() -> void:
	buttons.load_manual.disabled = not saves.exists(MANUAL_SAVE)
	buttons.load_auto.disabled = not saves.exists(AUTO_SAVE)
	load_dialog.popup_centered()
	_publish_bridge.call_deferred()

func _load_game(path: String) -> void:
	var result: Dictionary = saves.read(path)
	if not result.ok:
		feedback.text = "Load failed · %s" % result.get("message", result.get("error", "unknown"))
		return
	var restored: RefCounted = Rules.from_snapshot(result.snapshot)
	if restored == null:
		feedback.text = "Load failed · snapshot validation failed."
		return
	rules = restored
	local_mode = result.metadata.get("mode", "sandbox")
	if local_mode not in ["sandbox", "solo", "hotseat"]: local_mode = "sandbox"
	human_seat = result.metadata.get("human_seat", "p1")
	if not rules.state.data.heroes.has(human_seat): human_seat = "p1"
	viewer = human_seat if local_mode == "solo" else "p1"
	seed_edit.text = str(rules.state.data.master_seed)
	selected_hex = ""
	move_mode = false
	target_mode = ""
	decision_ack = ""
	board.build(rules.state.data.map)
	started = true
	welcome.hide()
	load_dialog.hide()
	_refresh()
	if rules.state.data.phase == "victory": _show_victory()
	feedback.text = "Loaded round %d · %s" % [rules.state.data.round_number, rules.state.data.phase]
	_publish_bridge()

func _export_log() -> void:
	var text_value: String = logger.to_jsonl()
	if local_mode == "network":
		var lines: PackedStringArray = []
		for result: Dictionary in network_results: lines.append(JSON.stringify(result))
		lines.append(JSON.stringify({"source": "authorized_view", "snapshot": rules.snapshot(), "checksum": rules.checksum()}))
		text_value = "\n".join(lines) + "\n"
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(text_value.to_utf8_buffer(), "shattered-realm-actions.jsonl", "application/x-ndjson")
	else:
		var file := FileAccess.open("user://action-export.jsonl", FileAccess.WRITE)
		if file: file.store_string(text_value)
	feedback.text = "Action log exported: commands, results, events, RNG and before/after checksums."

func _process(delta: float) -> void:
	if cinematic.visible:
		cinematic_seconds -= delta
		if cinematic_seconds <= 0: cinematic.hide()
	if not started: return
	if local_mode == "solo" and not welcome.visible and not planning_dialog.visible and not load_dialog.visible:
		bot_elapsed += delta
		if bot_elapsed >= 0.45:
			bot_elapsed = 0.0
			var command: Dictionary = Bot.choose(rules)
			if not command.is_empty() and command.get("player_id", "") != human_seat:
				_command(command, "solo_bot")
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit: return
	var direction := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W): direction.y -= 1
	if Input.is_physical_key_pressed(KEY_S): direction.y += 1
	if Input.is_physical_key_pressed(KEY_A): direction.x -= 1
	if Input.is_physical_key_pressed(KEY_D): direction.x += 1
	if direction != Vector2.ZERO: board.pan(direction * delta * 5)

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	match event.keycode:
		KEY_Q: board.rotate_board(-0.2)
		KEY_E: board.rotate_board(0.2)
		KEY_F, KEY_HOME: _focus_actor()
		KEY_F3: _toggle_debug()
		KEY_ESCAPE:
			move_mode = false
			if debug_panel.visible: debug_panel.hide()
			elif cinematic.visible: cinematic.hide()
			elif settings_dialog.visible: settings_dialog.hide()
			else: settings_dialog.popup_centered()
			_refresh()
	_publish_bridge()

func _setup_bridge() -> void:
	if not OS.has_feature("web") or not OS.is_debug_build(): return
	JavaScriptBridge.eval("window.realm = {state: null, ui: null, lastResult: null};", true)
	var window := JavaScriptBridge.get_interface("window")
	var command_callback := JavaScriptBridge.create_callback(_bridge_command)
	var reset_callback := JavaScriptBridge.create_callback(_bridge_reset)
	var inspect_callback := JavaScriptBridge.create_callback(_bridge_inspect)
	var propose_callback := JavaScriptBridge.create_callback(_bridge_propose)
	bridge_callbacks = [command_callback, reset_callback, inspect_callback, propose_callback]
	window.realmCommand = command_callback
	window.realmReset = reset_callback
	window.realmInspect = inspect_callback
	window.realmPropose = propose_callback
	JavaScriptBridge.eval("window.realm.command = c => { window.realmCommand(JSON.stringify(c)); return window.realm.lastResult; }; window.realm.reset = s => window.realmReset(s); window.realm.inspect = () => window.realmInspect(); window.realm.propose = p => { window.realmPropose(JSON.stringify(p || {})); return window.realm.botCommand; };", true)
	_publish_bridge()

func _bridge_command(args: Array) -> void:
	var value: Variant = JSON.parse_string(str(args[0]))
	if value is Dictionary: _command(value)
	_publish_bridge()

func _bridge_reset(args: Array) -> void:
	if args.is_empty() or int(args[0]) < -2147483648 or int(args[0]) > 2147483647: return
	_new_game(int(args[0]))
	started = true
	welcome.hide()
	_publish_bridge()

func _bridge_inspect(_args: Array) -> void:
	_publish_bridge()

func _bridge_propose(args: Array) -> void:
	var preferences_value: Variant = JSON.parse_string(str(args[0])) if not args.is_empty() else {}
	if not preferences_value is Dictionary: return
	JavaScriptBridge.eval("window.realm.botCommand = %s;" % JSON.stringify(Bot.choose(rules, preferences_value)), true)

func _publish_bridge() -> void:
	if not OS.has_feature("web") or not OS.is_debug_build() or rules == null: return
	var controls: Dictionary = {}
	for id: String in buttons:
		var button: Variant = buttons[id]
		if not is_instance_valid(button) or not button.is_inside_tree() or not button.is_visible_in_tree(): continue
		var rect: Rect2 = button.get_global_rect()
		if button.get_window() != get_tree().root:
			rect.position += Vector2(button.get_window().position)
		controls[id] = {"x": rect.position.x, "y": rect.position.y, "width": rect.size.x, "height": rect.size.y, "disabled": button.disabled, "text": button.text}
	var view_rect: Rect2 = viewport_container.get_global_rect()
	var ui: Dictionary = {"controls": controls, "phase_title": phase_title.text, "instruction": instruction.text, "feedback": feedback.text, "selected": selected_hex, "move_mode": move_mode, "debug_visible": debug_panel.visible, "journal": log_text.get_parsed_text(), "viewport": {"x": view_rect.position.x, "y": view_rect.position.y, "width": view_rect.size.x, "height": view_rect.size.y}, "size": {"width": size.x, "height": size.y}, "hexes": board.projected_hexes(), "camera": {"yaw": board.yaw, "zoom": board.zoom, "x": board.focus_point.x, "z": board.focus_point.z}}
	var actor: String = rules.current_actor()
	ui["decision_player"] = _decision_player()
	ui["mode"] = local_mode
	ui["human_seat"] = human_seat
	ui["viewer"] = viewer
	ui["threats"] = threat_label.text
	ui["victory_visible"] = victory_panel.visible
	ui["victory_text"] = victory_text.text
	ui["settings"] = preferences.values
	ui["performance"] = {"fps": Engine.get_frames_per_second(), "nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT), "draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)}
	ui["performance"]["board"] = board.debug_metrics()
	ui["handoff_visible"] = handoff.visible
	ui["handoff_text"] = handoff_label.text
	ui["planning_visible"] = planning_dialog.visible
	JavaScriptBridge.eval("if(window.realm){window.realm.state = %s; window.realm.ui = %s; window.realm.lastResult = %s; window.realm.legal = %s;}" % [JSON.stringify(rules.snapshot()), JSON.stringify(ui), JSON.stringify(last_result), JSON.stringify(rules.legal_actions(actor) if not actor.is_empty() else {})], true)
