extends SceneTree
## Thin process adapter. Commands, bots, and replay all execute the same domain rules.

const Rules = preload("res://scripts/domain/game_rules.gd")
const MapGenerator = preload("res://scripts/domain/generation/map_generator.gd")
const SimpleBot = preload("res://scripts/domain/bots/simple_bot.gd")
const ActionLog = preload("res://scripts/services/action_logger.gd")

var logger: RefCounted

func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 2:
		printerr("Usage: --script res://tools/game_cli.gd -- request.json response.json")
		quit(1)
		return
	var request_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not request_value is Dictionary:
		_write_response(args[1], {"ok": false, "error": "Request must be a JSON object."})
		return
	var response: Dictionary = _handle(request_value)
	_write_response(args[1], response)

func _write_response(output: String, response: Dictionary) -> void:
	var file: FileAccess = FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		printerr("Cannot write CLI response: ", error_string(FileAccess.get_open_error()))
		quit(1)
		return
	file.store_string(JSON.stringify(response))
	file.close()
	quit(0)

func _handle(request: Dictionary) -> Dictionary:
	var operation: String = str(request.get("operation", "state"))
	var seed_value: int = int(request.get("seed", 20260922))
	logger = ActionLog.new(str(request.get("log_path", "")))
	if operation == "validate-map":
		var reports: Array[Dictionary] = []
		var valid: bool = true
		for offset: int in range(int(request.get("count", 1))):
			var generated: Dictionary = MapGenerator.new().generate(seed_value + offset)
			var report: Dictionary = MapGenerator.new().validate(generated)
			report["seed"] = seed_value + offset
			reports.append(report)
			valid = valid and bool(report.get("valid", false))
		return {"ok": valid, "reports": reports, "count": reports.size()}
	var rules: RefCounted
	if operation == "new":
		rules = Rules.new(seed_value)
	else:
		var snapshot_value: Variant = request.get("snapshot", null)
		if not snapshot_value is Dictionary:
			return {"ok": false, "error": "No saved game. Run new --seed NUMBER first."}
		rules = Rules.from_snapshot(snapshot_value)
		if rules == null:
			return {"ok": false, "error": "Saved game failed schema, definition, or state validation."}
	var response: Dictionary = {"ok": true}
	match operation:
		"new", "state":
			pass
		"legal":
			var player_id: String = str(request.get("player_id", ""))
			if player_id.is_empty():
				player_id = rules.current_actor()
			response["player_id"] = player_id
			response["legal"] = rules.legal_actions(player_id)
		"command":
			var result: Dictionary = logger.execute(rules, request.get("command", {}), "cli")
			response["result"] = result
			response["ok"] = result.get("is_valid", false)
			response["mutated"] = result.get("is_valid", false)
		"simulate":
			response.merge(_simulate(rules, int(request.get("rounds", 3))), true)
			response["mutated"] = true
		"bot-step":
			var command: Dictionary = SimpleBot.choose(rules)
			var result: Dictionary = logger.execute(rules, command, "bot")
			response["command"] = command
			response["result"] = result
			response["ok"] = result.get("is_valid", false)
			response["mutated"] = result.get("is_valid", false)
		"replay":
			response.merge(_replay(rules), true)
		_:
			return {"ok": false, "error": "Unknown operation: " + operation}
	response["snapshot"] = rules.snapshot()
	response["checksum"] = rules.checksum()
	response["current_actor"] = rules.current_actor()
	response["log_entries"] = logger.entries.size()
	if not logger.last_error.is_empty():
		response["logging_error"] = logger.last_error
	return response

func _simulate(rules: RefCounted, rounds: int) -> Dictionary:
	var end_round: int = int(rules.snapshot()["round_number"]) + rounds
	var attempts: int = 0
	var maximum: int = rounds * 120 + 120
	var action_counts: Dictionary = {}
	var event_counts: Dictionary = {}
	while int(rules.snapshot()["round_number"]) < end_round and attempts < maximum:
		var state: Dictionary = rules.snapshot()
		var command: Dictionary = SimpleBot.choose(rules)
		if command.is_empty():
			return {"ok": false, "error": "Simulation found no command.", "attempts": attempts}
		command["expected_version"] = state["state_version"]
		var result: Dictionary = logger.execute(rules, command, "bot")
		attempts += 1
		if not result.get("is_valid", false):
			return {"ok": false, "error": "Bot command rejected.", "command": command, "result": result, "attempts": attempts}
		var action: String = str(command["type"])
		action_counts[action] = int(action_counts.get(action, 0)) + 1
		for event: Dictionary in result.get("events", []):
			var kind: String = str(event["type"])
			event_counts[kind] = int(event_counts.get(kind, 0)) + 1
	var completed: bool = int(rules.snapshot()["round_number"]) == end_round
	return {"ok": completed, "completed_rounds": rounds if completed else int(rules.snapshot()["round_number"]) - end_round + rounds, "attempts": attempts, "action_counts": action_counts, "event_counts": event_counts, "stop_reason": "configured_round_limit" if completed else "command_limit_exceeded"}

func _replay(rules: RefCounted) -> Dictionary:
	var original: Dictionary = rules.snapshot()
	var replay: RefCounted = Rules.new(int(original["master_seed"]))
	var count: int = 0
	for command: Dictionary in original["commands"]:
		var result: Dictionary = replay.execute(command)
		if not result.get("is_valid", false):
			return {"ok": false, "error": "Replay command rejected.", "index": count, "command": command, "result": result}
		count += 1
	var matches: bool = replay.checksum() == rules.checksum()
	return {"ok": matches, "replayed_commands": count, "replay_checksum": replay.checksum(), "matches": matches}
