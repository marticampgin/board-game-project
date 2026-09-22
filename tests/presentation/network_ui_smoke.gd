extends SceneTree
## Drives the actual Main scene in each native ENet process, including the
## observation facade, lobby callbacks and per-seat action UI.
var app: Control
var mode: String
var port: int
var elapsed: float = 0.0
var action_elapsed: float = 0.0
var busy: bool = false
var done: bool = false
var accepted: int = 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	mode = args[0]
	port = int(args[1])
	call_deferred("_boot")

func _boot() -> void:
	app = load("res://scenes/app/main.tscn").instantiate()
	root.add_child(app)
	if mode == "host": app._host_network(port)
	else: app._join_network("127.0.0.1", port, "")
	app.network.command_result.connect(_result)
	app.network.connection_failed.connect(func(message: String) -> void:
		if not done: _fail(message))
	print("@ui-boot " + mode)

func _result(result: Dictionary) -> void:
	busy = false
	if result.get("is_valid", false): accepted += 1
	elif result.get("reason_code", "") != "STALE_STATE": _fail("Command rejected: " + str(result))

func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > 30 and not done: _fail("Timed out awaiting synchronized graphical game")
	if app == null or app.network == null or done: return false
	if mode == "host" and not app.network.started:
		var connected: int = 0
		for seat: Dictionary in app.network.lobby_snapshot().get("seats", []):
			if seat.connected: connected += 1
		if connected >= 3: app.network.start_match()
	if not app.network.started or app.network.local_player_id.is_empty(): return false
	if app.rules.state.data.state_version >= 55:
		var player: String = app.network.local_player_id
		if app.viewer != player or app.local_mode != "network": _fail("UI lost its authorized viewer"); return false
		if app.rules.snapshot().has("rng") or app.rules.snapshot().has("commands") or app.rules.snapshot().has("master_seed"): _fail("Presentation received authority-only fields"); return false
		if app.board.heroes.size() != 4: _fail("Expected four rendered heroes"); return false
		if accepted < 3: _fail("Expected at least three accepted commands from this UI"); return false
		done = true
		print("@ui-done " + JSON.stringify({"player": player, "version": app.rules.state.data.state_version, "accepted": accepted, "phase_title": app.phase_title.text, "instruction": app.instruction.text}))
		return false
	if busy: return false
	action_elapsed += delta
	if action_elapsed < 0.08: return false
	action_elapsed = 0
	var command: Dictionary = _choose()
	if not command.is_empty():
		busy = true
		app._command(command)
	return false

func _choose() -> Dictionary:
	var player: String = app.network.local_player_id
	var legal: Dictionary = app.rules.legal_actions(player)
	var command: Dictionary = {"player_id": player}
	for kind: String in ["choose_stance", "resolve_reaction", "decline_fate", "displace", "choose_reward"]:
		if not legal.has(kind): continue
		command.type = kind
		match kind:
			"choose_stance": command.stance = "guard"
			"resolve_reaction": command.choice = "decline"
			"displace": command.target = legal.displace.targets.keys()[0]
			"choose_reward": command.choice = legal.choose_reward.choices.keys()[0]
		return command
	if legal.has("ready"):
		if not app.rules.state.data.plans.has(player): command.merge({"type": "submit_plan", "plan": {}})
		else: command.type = "ready"
		return command
	if legal.has("capture"): command.type = "capture"
	elif legal.has("explore"): command.type = "explore"
	elif legal.has("move"):
		command.type = "move"
		command.target = legal.move.targets.keys()[0]
	elif legal.has("pass"): command.type = "pass"
	else: return {}
	return command

func _fail(message: String) -> void:
	printerr("UI SMOKE FAILED: " + message)
	quit(1)
