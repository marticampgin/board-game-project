extends Control
## Native UI and development bridge. Commands always cross GameRules.execute.

const Rules = preload("res://scripts/domain/game_rules.gd")
const Board = preload("res://scripts/presentation/board_view.gd")
const ActionLog = preload("res://scripts/services/action_logger.gd")
const Hex = preload("res://scripts/domain/hex/hex.gd")
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
var actions: HBoxContainer
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

func _ready() -> void:
	logger = ActionLog.new("user://logs/actions.jsonl")
	_build_theme()
	_build_ui()
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
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(body)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 204
	body.add_child(left)
	left.add_child(_label("THE FOUR FACTIONS", 12, MUTED))
	cards = VBoxContainer.new()
	cards.add_theme_constant_override("separation", 6)
	left.add_child(cards)
	var local_note := _label("LOCAL · ALL FOUR SEATS\nSelect a card to inspect.", 11, MUTED)
	local_note.size_flags_vertical = Control.SIZE_EXPAND_FILL
	local_note.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	left.add_child(local_note)
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
	camera_controls.add_child(_button("zoom_out", "−", func() -> void: board.zoom_by(1); _publish_bridge()))
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
	actions = HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	footer_stack.add_child(actions)
	feedback = _label("Seeded rules · local four-seat play · no turn timers", 12, MUTED)
	footer_stack.add_child(feedback)
	_build_debug()
	_build_welcome()
	rules_dialog = AcceptDialog.new()
	rules_dialog.title = "The rules of the realm"
	rules_dialog.dialog_text = "Each round: World → Planning → Initiative → two Action Cycles → Bonus → Resolution.\n\nEvery hero acts once in each cycle. Initiative is Speed + d3.\nMove: 3 movement points; road-only paths allow 4. Forest costs 2 (Ranger: 1). Swamp ends movement. Occupied and impassable hexes block paths.\n\nCapture a neutral Minor Tower while standing on it. Capture uses its own action. Minor Towers produce 1 Power at Resolution. Fate increases by 1, capped at 5.\n\nMove and capture are authoritative commands. Green rings show legal targets; hover previews cost and path.\n\nCamera: WASD pan · Q/E or middle drag rotate · wheel zoom · F/Home focus.\n\nThis milestone proves the board and round rhythm. Victory routes and later content are tracked in the master specification."
	add_child(rules_dialog)
	pass_dialog = ConfirmationDialog.new()
	pass_dialog.title = "Pass this action>"
	pass_dialog.dialog_text = "This action will be lost. Your next action still follows initiative order."
	pass_dialog.confirmed.connect(func() -> void: _command({"type": "pass", "player_id": rules.current_actor()}))
	add_child(pass_dialog)

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
	options.add_child(_button("debug_close", "Close", _toggle_debug))

func _build_welcome() -> void:
	welcome = _panel(Color("192f37"), 30)
	welcome.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	welcome.offset_left = -265
	welcome.offset_right = 265
	welcome.offset_top = -140
	welcome.offset_bottom = 140
	add_child(welcome)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 14)
	welcome.add_child(stack)
	stack.add_child(_label("YOUR TABLE AWAITS", 12, GOLD))
	stack.add_child(_label("Four heroes. One shattered realm.", 23))
	stack.add_child(_label("Ranger · Warlord · Merchant · Cultist\n\nA seeded world of towers, roads and contested ground.\nControl all four seats in this development prototype.", 15, MUTED))
	stack.add_child(_button("start", "Enter the realm  →", func() -> void:
		started = true
		welcome.hide()
		_command({"type": "advance"})))

func _new_game(seed_value: int) -> void:
	rules = Rules.new(seed_value)
	viewer = "p1"
	selected_hex = ""
	move_mode = false
	seed_edit.text = str(seed_value)
	board.build(rules.state.data.map)
	_refresh()

func _regenerate() -> void:
	if not seed_edit.text.is_valid_int():
		feedback.text = "Enter an integer seed."
		return
	if int(seed_edit.text) < -2147483648 or int(seed_edit.text) > 2147483647:
		feedback.text = "Seed must be between -2147483648 and 2147483647."
		return
	_new_game(int(seed_edit.text))
	feedback.text = "World regenerated from seed %s. All seats reset." % seed_edit.text
	_publish_bridge()

func _command(command: Dictionary) -> Dictionary:
	command["expected_version"] = rules.state.data.state_version if not command.has("expected_version") else command.expected_version
	last_result = logger.execute(rules, command, "presentation")
	if last_result.is_valid:
		move_mode = false
		var actor: String = rules.current_actor()
		if not actor.is_empty(): viewer = actor
		feedback.text = "Accepted · %s · state %s" % [command.type, rules.state.data.state_version]
		_refresh(last_result.get("events", []))
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
		var prefix: String = "▶ " if rules.current_actor() == id else ""
		initiative.add_child(_label("%s%s %s  [%s]     " % [prefix, id.to_upper(), state.heroes[id].name, state.initiative_scores.get(id, "–")], 13, color))
	_refresh_cards()
	_refresh_actions()
	_refresh_selection()
	_refresh_journal()
	board.sync(state, viewer, events)
	var targets: Dictionary = {}
	if move_mode and not rules.current_actor().is_empty():
		targets = rules.legal_actions(rules.current_actor()).get("move", {}).get("targets", {})
	board.set_targets(targets)
	_refresh_debug()
	_publish_bridge.call_deferred()

func _refresh_cards() -> void:
	_clear(cards)
	var state: Dictionary = rules.state.data
	for id: String in state.heroes:
		var hero: Dictionary = state.heroes[id]
		var color: Color = Board.TEAM[int(id.substr(1)) - 1]
		var panel := _panel(Color("263d42") if viewer == id else Color("1a2f37"), 7)
		cards.add_child(panel)
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 2)
		panel.add_child(stack)
		var select := _button("seat_" + id, "%s   %s%s" % [id.to_upper(), hero.name, "  •" if rules.current_actor() == id else ""], func() -> void:
			viewer = id
			selected_hex = rules.state.data.heroes[id].hex
			board.selected = selected_hex
			board.focus_hex(selected_hex)
			_refresh())
		select.add_theme_color_override("font_color", color)
		select.add_theme_font_size_override("font_size", 14)
		for style_name in ["normal", "hover", "pressed", "focus"]:
			var style: StyleBoxFlat = theme.get_stylebox(style_name, "Button").duplicate()
			style.content_margin_top = 3
			style.content_margin_bottom = 3
			select.add_theme_stylebox_override(style_name, style)
		select.alignment = HORIZONTAL_ALIGNMENT_LEFT
		stack.add_child(select)
		stack.add_child(_label("HP %d/%d   ATK %d   DEF %d   SPD %d" % [hero.hp, hero.max_hp, hero.attack, hero.defence, hero.speed], 10, MUTED))
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

func _refresh_actions() -> void:
	_clear(actions)
	var state: Dictionary = rules.state.data
	match state.phase:
		"world":
			instruction.text = "A new round begins. Survey the realm, then prepare your plans."
			actions.add_child(_button("advance", "Begin Planning  →", func() -> void: _command({"type": "advance"})))
		"planning":
			instruction.text = "Planning · submit all four seats to reveal initiative together."
			for id: String in state.heroes:
				var ready: bool = id in state.ready
				var button := _button("ready_" + id, "%s %s" % [id.to_upper(), "Ready ✓" if ready else "Ready"], func() -> void: _command({"type": "ready", "player_id": id}))
				button.disabled = ready
				actions.add_child(button)
			actions.add_child(_label("No preparations required in this slice.", 12, MUTED))
		"initiative":
			instruction.text = "Initiative revealed · Speed + d3. Each hero acts once per cycle."
			actions.add_child(_button("advance", "Begin Action Cycle 1  →", func() -> void: _command({"type": "advance"})))
		"cycle_1", "cycle_2":
			var actor: String = rules.current_actor()
			var legal: Dictionary = rules.legal_actions(actor)
			instruction.text = "%s · %s's action · select Move, then a highlighted hex." % [actor.to_upper(), state.heroes[actor].name]
			var move_button := _button("move", "Move" + ("  ✓" if move_mode else ""), func() -> void: move_mode = not move_mode; _refresh())
			move_button.disabled = not legal.has("move")
			actions.add_child(move_button)
			var capture := _button("capture", "Capture tower", func() -> void: _command({"type": "capture", "player_id": actor}))
			capture.disabled = not legal.has("capture")
			capture.tooltip_text = "Stand on an unowned Minor Tower to capture. Move and Capture each use one action."
			actions.add_child(capture)
			actions.add_child(_button("pass", "Pass…", func() -> void: pass_dialog.popup_centered()))
			actions.add_child(_button("cancel", "Cancel selection", func() -> void: move_mode = false; _refresh()))
		"bonus":
			instruction.text = "Both ordinary cycles are complete. No bonus actions are granted."
			actions.add_child(_button("advance", "Continue to Resolution  →", func() -> void: _command({"type": "advance"})))
		"resolution":
			instruction.text = "Resolution · pay location income, recover Health, gain capped Fate."
			actions.add_child(_button("advance", "Resolve round  →", func() -> void: _command({"type": "advance"})))

func _select_hex(hex: String) -> void:
	selected_hex = hex
	if move_mode:
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
	if board.reachable.has(hex):
		var route: Dictionary = board.reachable[hex]
		info += "  |  %d MP  ·  %s" % [route.cost, " → ".join(route.path)]
		if route.road_only: info += "  [road]"
	hover_label.text = info
	_refresh_debug()

func _refresh_selection() -> void:
	var state: Dictionary = rules.state.data
	if selected_hex.is_empty():
		selected_panel.text = "[color=#dec18a][b]Explore the board[/b][/color]\n\nSelect a hex or faction card.\nGreen rings: legal movement\nGold border: selected hex\nP1–P4 banners: ownership"
		return
	var tile: Dictionary = state.map.hexes[selected_hex]
	var value: String = "[color=#dec18a][b]%s[/b][/color]  %s\n%s\n" % [String(tile.terrain).capitalize(), selected_hex, tile.region]
	var location_id: String = tile.get("location_id", "")
	if not location_id.is_empty():
		var location: Dictionary = state.map.locations[location_id]
		var visible: bool = location.kind in ["worldspire", "ancient_tower"] or viewer in location.get("discovered_by", [])
		if visible:
			value += "\n[b]%s[/b]\n%s · Level %d\nOwner: %s" % [location.name, String(location.kind).replace("_", " ").capitalize(), location.level, location.owner_id if not String(location.owner_id).is_empty() else "Neutral"]
			if rules.definitions.tower_traits.has(location.get("trait", "")):
				var trait: Dictionary = rules.definitions.tower_traits[location.trait]
				value += "\n[color=#dec18a]%s[/color]: %s" % [trait.name, trait.description]
		else: value += "\nUndiscovered location\nApproach within 2 hexes."
	else:
		value += "\n%s" % {"plains": "Open ground · 1 movement point", "forest": "Forest · 2 MP (Ranger: 1)\nDefender gains +1 Defence", "swamp": "Swamp · ends movement", "water": "Water · impassable", "mountain": "Mountain · impassable"}.get(tile.terrain, "")
	selected_panel.text = value

func _refresh_journal() -> void:
	var lines: PackedStringArray = []
	var events: Array = rules.state.data.events
	for index in range(maxi(0, events.size() - 90), events.size()):
		var event: Dictionary = events[index]
		if event.get("visibility", "public") != "public": continue
		if journal_filter == "actions" and event.type not in ["ActionStarted", "HeroMoved", "LocationCaptured", "ActionPassed"]: continue
		if journal_filter == "economy" and event.type not in ["IncomeGranted", "FateGained", "LocationCaptured"]: continue
		var description: String = _event_description(event)
		lines.append("[color=#7e9a9a]#%03d · R%d[/color]  %s\n%s" % [event.sequence, event.round, event.actor_id.to_upper(), description])
	log_text.text = "\n\n".join(lines)

func _event_description(event: Dictionary) -> String:
	var data: Dictionary = event.data
	match event.type:
		"HeroMoved": return "Moved %s → %s" % [data.get("from", ""), data.get("to", data.get("target", ""))]
		"PhaseChanged": return "[color=#dec18a]%s[/color]" % String(data.get("phase", data.get("to", "Phase advanced"))).replace("_", " ").capitalize()
		"IncomeGranted": return "[color=#a3ceb2]Income[/color]  " + JSON.stringify(data)
		"LocationCaptured": return "[color=#dec18a]Location captured[/color]  " + String(data.get("location_id", ""))
		"InitiativeRolled": return "Initiative  " + JSON.stringify(data)
		_: return String(event.type).capitalize() + ("  " + JSON.stringify(data) if not data.is_empty() else "")

func _refresh_debug() -> void:
	if not debug_panel.visible: return
	var state: Dictionary = rules.state.data
	debug_text.text = "[b]Seed[/b] %s    [b]FPS[/b] %d    [b]Version[/b] %s\n[b]Round / Phase / Cycle[/b] %s / %s / %s\n[b]Actor[/b] %s  [b]Selection[/b] %s\n[b]Checksum[/b]\n%s\n[b]RNG[/b] %s\n[b]Generation[/b] %s\n[b]Path[/b] %s\n[b]Log[/b] %s" % [state.master_seed, Engine.get_frames_per_second(), state.state_version, state.round_number, state.phase, state.action_cycle, rules.current_actor(), selected_hex, rules.checksum(), JSON.stringify(state.rng), JSON.stringify(state.map.report), hover_label.text, "user://logs/actions.jsonl"]

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

func _export_log() -> void:
	var text_value: String = logger.to_jsonl()
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(text_value.to_utf8_buffer(), "shattered-realm-actions.jsonl", "application/x-ndjson")
	else:
		var file := FileAccess.open("user://action-export.jsonl", FileAccess.WRITE)
		if file: file.store_string(text_value)
	feedback.text = "Action log exported: commands, results, events, RNG and before/after checksums."

func _process(delta: float) -> void:
	if not started: return
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
			debug_panel.hide()
			_refresh()
	_publish_bridge()

func _setup_bridge() -> void:
	if not OS.has_feature("web") or not OS.is_debug_build(): return
	JavaScriptBridge.eval("window.realm = {state: null, ui: null, lastResult: null};", true)
	var window := JavaScriptBridge.get_interface("window")
	var command_callback := JavaScriptBridge.create_callback(_bridge_command)
	var reset_callback := JavaScriptBridge.create_callback(_bridge_reset)
	var inspect_callback := JavaScriptBridge.create_callback(_bridge_inspect)
	bridge_callbacks = [command_callback, reset_callback, inspect_callback]
	window.realmCommand = command_callback
	window.realmReset = reset_callback
	window.realmInspect = inspect_callback
	JavaScriptBridge.eval("window.realm.command = c => { window.realmCommand(JSON.stringify(c)); return window.realm.lastResult; }; window.realm.reset = s => window.realmReset(s); window.realm.inspect = () => window.realmInspect();", true)
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

func _publish_bridge() -> void:
	if not OS.has_feature("web") or not OS.is_debug_build() or rules == null: return
	var controls: Dictionary = {}
	for id: String in buttons:
		var button: Variant = buttons[id]
		if not is_instance_valid(button) or not button.is_inside_tree() or not button.is_visible_in_tree(): continue
		var rect: Rect2 = button.get_global_rect()
		controls[id] = {"x": rect.position.x, "y": rect.position.y, "width": rect.size.x, "height": rect.size.y, "disabled": button.disabled, "text": button.text}
	var view_rect: Rect2 = viewport_container.get_global_rect()
	var ui: Dictionary = {"controls": controls, "phase_title": phase_title.text, "instruction": instruction.text, "feedback": feedback.text, "selected": selected_hex, "move_mode": move_mode, "debug_visible": debug_panel.visible, "journal": log_text.get_parsed_text(), "viewport": {"x": view_rect.position.x, "y": view_rect.position.y, "width": view_rect.size.x, "height": view_rect.size.y}, "size": {"width": size.x, "height": size.y}, "hexes": board.projected_hexes(), "camera": {"yaw": board.yaw, "zoom": board.zoom, "x": board.focus_point.x, "z": board.focus_point.z}}
	var actor: String = rules.current_actor()
	JavaScriptBridge.eval("if(window.realm){window.realm.state = %s; window.realm.ui = %s; window.realm.lastResult = %s; window.realm.legal = %s;}" % [JSON.stringify(rules.snapshot()), JSON.stringify(ui), JSON.stringify(last_result), JSON.stringify(rules.legal_actions(actor) if not actor.is_empty() else {})], true)
