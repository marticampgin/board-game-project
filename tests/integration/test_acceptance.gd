extends RefCounted

const Rules = preload("res://scripts/domain/game_rules.gd")
const Movement = preload("res://scripts/domain/resolvers/movement.gd")
const ActionLog = preload("res://scripts/services/action_logger.gd")

var errors: Array[String] = []
var logger: RefCounted

func run() -> Array[String]:
	errors.clear()
	logger = ActionLog.new()
	_test_fixture()
	_test_three_rounds()
	_test_rejection_purity()
	return errors

func _check(condition: bool, message: String) -> void:
	if not condition:
		errors.append(message)

func _test_fixture() -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/planning_commands.json"))
	var first: RefCounted = Rules.new(int(fixture["seed"]))
	var second: RefCounted = Rules.new(int(fixture["seed"]))
	for command: Dictionary in fixture["commands"]:
		var left: Dictionary = first.execute(command)
		var right: Dictionary = second.execute(command)
		_check(left.get("is_valid", false) and right.get("is_valid", false), "Fixture rejected: " + JSON.stringify(command))
		_check(first.checksum() == second.checksum(), "Fixture replay diverged at " + str(command["type"]))
	_check(JSON.stringify(first.snapshot()["events"]) == JSON.stringify(second.snapshot()["events"]), "Identical fixture must produce identical events including RNG results")

func _send(rules: RefCounted, command: Dictionary) -> bool:
	# Every phase/action is saved through JSON, restored, and continued in parallel.
	var restored: RefCounted = Rules.from_snapshot(JSON.parse_string(JSON.stringify(rules.snapshot())))
	_check(restored != null, "Valid snapshot could not restore before " + JSON.stringify(command))
	if restored == null:
		return false
	_check(restored.checksum() == rules.checksum(), "JSON save/load changed checksum")
	var result: Dictionary = logger.execute(rules, command, "acceptance")
	var continued: Dictionary = restored.execute(command)
	_check(result.get("is_valid", false), "Acceptance command rejected: %s %s" % [JSON.stringify(command), JSON.stringify(result)])
	_check(continued.get("is_valid", false), "Restored game rejected legal continuation")
	_check(rules.checksum() == restored.checksum(), "Save/load continuation diverged in state or RNG")
	return bool(result.get("is_valid", false))

func _test_three_rounds() -> void:
	var rules: RefCounted = Rules.new(20260922)
	var original_map: String = JSON.stringify(rules.snapshot()["map"])
	var moved: Dictionary = {"p1": false, "p2": false, "p3": false, "p4": false}
	var capture_count: int = 0
	var received_income: bool = false
	var phases: Dictionary = {}
	for round_index: int in range(1, 4):
		_check(int(rules.snapshot()["round_number"]) == round_index, "Round counter differs from expected round")
		phases["world"] = true
		if not _send(rules, {"type": "advance"}): return
		phases["planning"] = true
		for player: String in ["p1", "p2", "p3", "p4"]:
			if not _send(rules, {"type": "submit_plan", "player_id": player, "plan": {}}): return
			if not _send(rules, {"type": "ready", "player_id": player}): return
		_check(rules.snapshot()["phase"] == "initiative", "Ready all must enter initiative")
		phases["initiative"] = true
		var order: Array = rules.snapshot()["initiative_order"]
		_check(order.size() == 4, "Initiative must contain all four heroes")
		if not _send(rules, {"type": "advance"}): return
		for cycle: int in range(1, 3):
			var seen: Dictionary = {}
			for index: int in range(4):
				var phase: String = "cycle_%s" % cycle
				phases[phase] = true
				_check(rules.snapshot()["phase"] == phase, "Action cycle transitioned too early or too late")
				var actor: String = rules.current_actor()
				_check(actor == str(order[index]), "Actor differs from initiative order")
				_check(not seen.has(actor), "Duplicate action for %s in %s" % [actor, phase])
				seen[actor] = true
				var legal: Dictionary = rules.legal_actions(actor)
				var command: Dictionary = {"type": "pass", "player_id": actor}
				if legal.has("capture"):
					command["type"] = "capture"
				elif legal.has("move"):
					var target: String = _tower_destination(rules.snapshot(), legal["move"].get("targets", {}))
					if not target.is_empty():
						command["type"] = "move"
						command["target"] = target
						moved[actor] = true
				if not _send(rules, command): return
				for event: Dictionary in logger.entries.back()["events"]:
					if event["type"] == "LocationCaptured":
						capture_count += 1
			_check(seen.size() == 4, "A hero lost its scheduled action")
		_check(rules.snapshot()["phase"] == "bonus", "Two ordinary cycles must precede bonus")
		phases["bonus"] = true
		if not _send(rules, {"type": "advance"}): return
		_check(rules.snapshot()["phase"] == "resolution", "Bonus must enter resolution")
		phases["resolution"] = true
		var before_income: Dictionary = rules.snapshot()
		if not _send(rules, {"type": "advance"}): return
		var after_income: Dictionary = rules.snapshot()
		for player: String in ["p1", "p2", "p3", "p4"]:
			var tower_income: int = 0
			for location: Dictionary in before_income["map"]["locations"].values():
				if location.get("owner_id", "") == player and location["kind"] == "minor_tower":
					tower_income += 1
			var expected: int = mini(12, int(before_income["heroes"][player]["power"]) + tower_income)
			_check(int(after_income["heroes"][player]["power"]) == expected, "Minor Tower income was not paid to " + player)
			received_income = received_income or expected > int(before_income["heroes"][player]["power"])
	_check(int(rules.snapshot()["round_number"]) == 4 and rules.snapshot()["phase"] == "world", "Three complete rounds did not reach round 4 World")
	_check(phases.size() == 7, "Acceptance did not visit all seven phase types")
	for player: String in moved:
		_check(bool(moved[player]), "Hero never moved: " + player)
	_check(capture_count > 0, "Three-round fixture did not capture a tower")
	_check(received_income, "Three-round fixture did not receive tower income")
	var fresh: RefCounted = Rules.new(20260922)
	_check(original_map == JSON.stringify(fresh.snapshot()["map"]), "Regenerated map differs for same seed")
	for command: Dictionary in rules.snapshot()["commands"]:
		var result: Dictionary = fresh.execute(command)
		_check(result.get("is_valid", false), "Full replay rejected recorded command")
	_check(fresh.checksum() == rules.checksum(), "Three-round accepted-command replay diverged")
	_check(JSON.stringify(fresh.snapshot()["events"]) == JSON.stringify(rules.snapshot()["events"]), "Three-round event log differs on replay")
	_check(logger.entries.size() > 0 and logger.to_text().contains("ACCEPT"), "Readable action log is empty")

func _tower_destination(state: Dictionary, targets: Dictionary) -> String:
	var candidates: Array = targets.keys()
	candidates.sort()
	if candidates.is_empty(): return ""
	var chosen: String = str(candidates[0])
	var best: int = 1000000
	for target: String in candidates:
		var costs: Dictionary = Movement.travel_costs(state["map"], target)
		for location: Dictionary in state["map"]["locations"].values():
			if location["kind"] != "minor_tower" or not str(location.get("owner_id", "")).is_empty(): continue
			var cost: int = int(costs.get(location["hex"], 1000000))
			if cost < best:
				best = cost
				chosen = target
	return chosen

func _test_rejection_purity() -> void:
	var rules: RefCounted = Rules.new(17)
	for command: Dictionary in [
		{"type": "move", "player_id": "p1", "target": "0,0"},
		{"type": "advance", "expected_version": 999999},
		{"type": "advance", "expected_phase": "planning"},
		{"type": "unknown"},
		{}
	]:
		var checksum: String = rules.checksum()
		var result: Dictionary = logger.execute(rules, command, "rejection-test")
		_check(not result.get("is_valid", true), "Invalid command accepted: " + JSON.stringify(command))
		_check(rules.checksum() == checksum, "Rejected command mutated state, event history, or RNG")
		var entry: Dictionary = logger.entries.back()
		_check(entry["checksum_before"] == entry["checksum_after"], "Rejection audit hashes differ")
		_check(not str(entry["reason_code"]).is_empty(), "Rejection has no reason code")
	var checksum: String = rules.checksum()
	for player: String in ["p1", "p2", "p3", "p4"]:
		rules.legal_actions(player)
	_check(checksum == rules.checksum(), "Legal-action queries consumed gameplay RNG or mutated state")
