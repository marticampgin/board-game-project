extends RefCounted
## Reusable complete-match harness. The 40-round limit reports stalls, never a fabricated winner.

const Rules = preload("res://scripts/domain/game_rules.gd")
const Bot = preload("res://scripts/domain/bots/simple_bot.gd")

static func run_match(seed_value: int, maximum_rounds: int = 40, preferences: Dictionary = {}, verify_replay: bool = true) -> Dictionary:
	var rules: RefCounted = Rules.new(seed_value)
	var events: Dictionary = {}
	var commands: Dictionary = {}
	var commands_per_round: Dictionary = {}
	var attempts: int = 0
	var failure: String = ""
	var started: int = Time.get_ticks_msec()
	var last_restored_round: int = 0
	while int(rules.state.data["round_number"]) <= maximum_rounds and rules.state.data.get("victory", {}).is_empty():
		var before_round: int = int(rules.state.data["round_number"])
		# Resume each new round from actual JSON, then replay from an untouched new
		# game. This catches dictionary-insertion ordering bugs hidden by same-process runs.
		if before_round != last_restored_round:
			var prior_hash: String = rules.checksum()
			var continued: RefCounted = Rules.from_snapshot(JSON.parse_string(JSON.stringify(rules.snapshot())))
			if continued == null or continued.checksum() != prior_hash:
				failure = "round_snapshot_roundtrip_failed"
				break
			rules = continued
			last_restored_round = before_round
		if int(commands_per_round.get(before_round, 0)) >= 120:
			failure = "command_limit_exceeded"
			break
		var command: Dictionary = Bot.choose(rules, preferences)
		if command.is_empty():
			failure = "no_legal_bot_command"
			break
		if attempts % 37 == 0:
			var before: String = rules.checksum()
			if command != Bot.choose(rules, preferences) or before != rules.checksum():
				failure = "nondeterministic_or_mutating_policy"
				break
		command["expected_version"] = rules.state.data["state_version"]
		var result: Dictionary = rules.execute(command)
		attempts += 1
		commands_per_round[before_round] = int(commands_per_round.get(before_round, 0)) + 1
		if not result.get("is_valid", false):
			failure = "rejected:%s:%s" % [JSON.stringify(command), result.get("reason_code", "")]
			break
		commands[command["type"]] = int(commands.get(command["type"], 0)) + 1
		for event: Dictionary in result.get("events", []):
			var event_type: String = str(event["type"])
			events[event_type] = int(events.get(event_type, 0)) + 1
			if event_type == "CombatCalculationUpdated" and not event["data"].get("is_valid", true):
				failure = "invalid_combat_calculation:" + JSON.stringify(event["data"])
		if not failure.is_empty(): break
	var victory: Dictionary = rules.state.data.get("victory", {}).duplicate(true)
	var checksum: String = rules.checksum()
	var replay_matches: bool = false
	if failure.is_empty() and verify_replay:
		var replay: RefCounted = Rules.new(seed_value)
		for command: Dictionary in rules.state.data["commands"]:
			var result: Dictionary = replay.execute(command)
			if not result.get("is_valid", false):
				failure = "replay_rejected:" + str(result.get("reason_code", ""))
				break
		replay_matches = replay.checksum() == checksum
		if failure.is_empty() and not replay_matches: failure = "replay_checksum_mismatch"
	var restored: RefCounted = Rules.from_snapshot(JSON.parse_string(JSON.stringify(rules.snapshot())))
	if restored == null or restored.checksum() != checksum:
		failure = "final_snapshot_roundtrip_failed"
	var resources: Dictionary = {}
	for hero: Dictionary in rules.state.data["heroes"].values():
		resources[hero["id"]] = {"class_id": hero["class_id"], "hp": hero["hp"], "gold": hero["gold"], "power": hero["power"], "fate": hero["fate"], "relics": hero["relics"].size()}
	return {
		"seed": seed_value, "content_version": rules.state.data.get("content_version", ""), "finished": not victory.is_empty() and failure.is_empty(),
		"victory": victory, "rounds": int(victory.get("round", mini(maximum_rounds, int(rules.state.data["round_number"])))) ,
		"commands": attempts, "command_counts": commands, "event_counts": events,
		"resources": resources, "checksum": checksum, "replay_matches": replay_matches,
		"stop_reason": failure if not failure.is_empty() else ("victory" if not victory.is_empty() else "stalled_round_limit"),
		"duration_ms": Time.get_ticks_msec() - started
	}

static func summarize(reports: Array[Dictionary]) -> Dictionary:
	var finished: int = 0
	var rounds: Array[int] = []
	var routes: Dictionary = {}
	var stalled: Array[int] = []
	for report: Dictionary in reports:
		if report.get("finished", false):
			finished += 1
			rounds.append(int(report["rounds"]))
			var route: String = str(report["victory"].get("route", "unknown"))
			routes[route] = int(routes.get(route, 0)) + 1
		else:
			stalled.append(int(report["seed"]))
	rounds.sort()
	var median: float = 0.0
	if not rounds.is_empty():
		median = float(rounds[rounds.size() / 2]) if rounds.size() % 2 == 1 else float(rounds[rounds.size() / 2 - 1] + rounds[rounds.size() / 2]) / 2.0
	return {"matches": reports.size(), "finished": finished, "stalled_seeds": stalled, "median_rounds": median, "route_distribution": routes}
