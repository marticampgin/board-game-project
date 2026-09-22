extends SceneTree
## Native development adapter. NetworkSession alone owns RPC and authority.
## The inbox/journal are local process controls, never part of the network protocol.
const Session = preload("res://scripts/network/network_session.gd")
const Bot = preload("res://scripts/domain/bots/simple_bot.gd")
var session: Node
var directory: String = ""
var elapsed: float = 0.0
var event_index: int = 0
var reported_token: String = ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("network_peer requires one JSON configuration path")
		quit(1)
		return
	var config: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not config is Dictionary:
		push_error("Invalid network peer configuration")
		quit(1)
		return
	call_deferred("_boot", config)

func _boot(config: Dictionary) -> void:
	directory = str(config.directory)
	DirAccess.make_dir_recursive_absolute(directory.path_join("inbox"))
	session = Session.new()
	session.name = "NetworkSession"
	session.log_path = directory.path_join("actions.jsonl")
	session.auto_drive = bool(config.get("auto_drive", true))
	session.reaction_timeout_seconds = float(config.get("reaction_timeout_seconds", 20.0))
	session.planning_timeout_seconds = float(config.get("planning_timeout_seconds", 60.0))
	session.bot_interval_seconds = float(config.get("bot_interval_seconds", 0.25))
	session.observation_updated.connect(_observation)
	session.lobby_updated.connect(func(lobby: Dictionary) -> void: _emit("lobby", lobby))
	session.command_result.connect(func(result: Dictionary) -> void: _emit("result", result))
	session.connection_failed.connect(func(message: String) -> void: _emit("connection_failed", {"message": message}))
	root.add_child(session)
	var error: int
	if config.get("mode", "host") == "host":
		error = session.host_game(int(config.get("port", 24567)), int(config.get("seed", 20260922)))
	else:
		error = session.join_game(str(config.get("address", "127.0.0.1")), int(config.get("port", 24567)), str(config.get("token", "")))
	_emit("boot", {"mode": config.get("mode", "host"), "error": error})
	if error != OK: quit(1)

func _process(delta: float) -> bool:
	if session == null: return false
	if session.reconnect_token != reported_token and not str(session.reconnect_token).is_empty():
		reported_token = session.reconnect_token
		var credentials := {"player_id": session.local_player_id, "token": reported_token}
		_write_json("credentials.json", credentials)
		_emit("identity", credentials)
	elapsed += delta
	if elapsed < 0.025: return false
	elapsed = 0.0
	var files := DirAccess.get_files_at(directory.path_join("inbox"))
	files.sort()
	for filename: String in files:
		if not filename.ends_with(".json"): continue
		var filename_path := directory.path_join("inbox").path_join(filename)
		var request: Variant = JSON.parse_string(FileAccess.get_file_as_string(filename_path))
		DirAccess.remove_absolute(filename_path)
		if request is Dictionary: _request(request)
		else: _emit("control_error", {"message": "Invalid JSON control file", "file": filename})
	return false

func _request(request: Dictionary) -> void:
	var id: String = str(request.get("id", ""))
	var op: String = str(request.get("op", "submit"))
	var response: Dictionary = {"id": id, "op": op}
	match op:
		"start": response["result"] = session.start_match()
		"submit": session.submit(request.get("command", {}))
		"host_submit":
			if session.is_host:
				response["result"] = session.submit_as_host(request.get("command", {}), "network:cli")
		"raw_rpc":
			# Only the development harness calls this; it exercises server authentication.
			session.rpc_id(1, "_request_command", int(request.get("sequence", 1)), request.get("command", {}))
		"inspect":
			response["observation"] = session.latest_observation
			response["player_id"] = session.local_player_id
			response["started"] = session.started
			if session.is_host and session.rules != null:
				# Read-only, host-local diagnostics. This is not sent to remote peers.
				response["snapshot"] = session.rules.snapshot()
				response["checksum"] = session.rules.checksum()
				response["actor"] = session.rules.current_actor()
				var legal: Dictionary = {}
				for player: String in ["p1", "p2", "p3", "p4"]: legal[player] = session.rules.legal_actions(player)
				response["legal"] = legal
		"propose":
			if session.is_host and session.rules != null:
				response["command"] = Bot.choose(session.rules, request.get("preferences", {}))
		"configure":
			for key: String in ["auto_drive", "reaction_timeout_seconds", "planning_timeout_seconds", "bot_interval_seconds"]:
				if request.has(key): session.set(key, request[key])
		"tick":
			if session.is_host: session.tick(float(request.get("seconds", 0.0)))
		"disconnect": session.disconnect_session()
		"quit":
			session.disconnect_session()
			quit(0)
		_: response["error"] = "Unknown control operation: " + op
	_emit("control", response)

func _observation(view: Dictionary) -> void:
	_write_json("observation.json", view)
	_emit("observation", view)

func _write_json(filename: String, value: Dictionary) -> void:
	var temporary := directory.path_join(filename + ".tmp")
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return
	file.store_string(JSON.stringify(value))
	file.close()
	DirAccess.rename_absolute(temporary, directory.path_join(filename))

func _emit(kind: String, data: Dictionary) -> void:
	event_index += 1
	var record := {"index": event_index, "kind": kind, "time_ms": Time.get_ticks_msec(), "data": data}
	var encoded := JSON.stringify(record)
	var filename := directory.path_join("network.jsonl")
	var journal := FileAccess.open(filename, FileAccess.READ_WRITE if FileAccess.file_exists(filename) else FileAccess.WRITE)
	if journal != null:
		journal.seek_end()
		journal.store_line(encoded)
		journal.close()
	print("@realm-net " + encoded)
