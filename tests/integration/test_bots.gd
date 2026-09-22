extends RefCounted

const Rules = preload("res://scripts/domain/game_rules.gd")
const SimpleBot = preload("res://scripts/domain/bots/simple_bot.gd")

var errors: Array[String] = []

func run() -> Array[String]:
	errors.clear()
	_test_twenty_rounds(20260922)
	return errors

func _check(condition: bool, message: String) -> void:
	if not condition:
		errors.append(message)

func _test_twenty_rounds(seed_value: int) -> void:
	var rules: RefCounted = Rules.new(seed_value)
	var attempts: int = 0
	var actions: Dictionary = {}
	var event_counts: Dictionary = {}
	var pending_stages_saved: Dictionary = {}
	var guards: int = 0
	var commands_per_round: Dictionary = {}
	while int(rules.state.data["round_number"]) <= 20 and attempts < 2400 and rules.state.data.get("victory", {}).is_empty():
		var version: int = int(rules.state.data["state_version"])
		var command: Dictionary = SimpleBot.choose(rules)
		if command.is_empty():
			errors.append("Bot deadlocked: seed %s, round %s, phase %s, pending %s/%s" % [seed_value, rules.state.data["round_number"], rules.state.data["phase"], rules.state.data.get("pending_combat", {}), rules.state.data.get("pending_reaction", {})])
			return
		# Repeated observation cannot consume RNG; it must produce the same intention.
		if attempts % 19 == 0:
			var before: String = rules.checksum()
			_check(command == SimpleBot.choose(rules), "Bot choice changes without an authoritative state change")
			_check(rules.checksum() == before, "Bot choice mutated authoritative state or RNG")
			guards += 1
		var pending: Dictionary = rules.state.data.get("pending_combat", {})
		var reaction: Dictionary = rules.state.data.get("pending_reaction", {})
		var stage: String = str(pending.get("stage", reaction.get("kind", "")))
		var restored: RefCounted = null
		if not stage.is_empty() and not pending_stages_saved.has(stage):
			pending_stages_saved[stage] = true
			restored = Rules.from_snapshot(JSON.parse_string(JSON.stringify(rules.snapshot())))
			_check(restored != null, "Cannot restore a pending bot decision: " + stage)
			if restored != null:
				_check(restored.checksum() == rules.checksum(), "Pending save checksum differs: " + stage)
				_check(SimpleBot.choose(restored) == command, "Save/load changes bot decision: " + stage)
		command["expected_version"] = version
		var result: Dictionary = rules.execute(command)
		attempts += 1
		var round_number: int = int(rules.state.data["round_number"])
		commands_per_round[round_number] = int(commands_per_round.get(round_number, 0)) + 1
		if int(commands_per_round[round_number]) > 120:
			errors.append("Bot exceeded 120 commands in round %s; last command %s" % [round_number, JSON.stringify(command)])
			return
		if not result.get("is_valid", false):
			errors.append("Bot command rejected at seed %s attempt %s: %s => %s" % [seed_value, attempts, JSON.stringify(command), JSON.stringify(result)])
			return
		_check(int(rules.state.data["state_version"]) == version + 1, "Bot command did not increment exactly one state version")
		if restored != null:
			var continuation: Dictionary = restored.execute(command)
			_check(continuation.get("is_valid", false), "Restored pending decision was rejected")
			_check(restored.checksum() == rules.checksum(), "Pending decision RNG continuation diverged: " + stage)
		for event: Dictionary in result.get("events", []):
			var kind: String = str(event["type"])
			if kind == "CombatCalculationUpdated" and not event["data"].get("is_valid", true):
				errors.append("Combat calculation failed during bot run: " + JSON.stringify(event["data"]))
				return
			event_counts[kind] = int(event_counts.get(kind, 0)) + 1
			if kind == "ActionCompleted":
				var key: String = "%s:%s:%s" % [event["round"], event["data"].get("cycle", -1), event["actor_id"]]
				actions[key] = int(actions.get(key, 0)) + 1
	var won: bool = not rules.state.data.get("victory", {}).is_empty()
	_check(int(rules.state.data["round_number"]) == 21 or won, "Four bots did not finish 20 rounds or reach a legitimate victory")
	_check(rules.state.data["phase"] in ["world", "victory"], "Bot stop point is not World or Victory")
	_check(rules.state.data.get("pending_combat", {}).is_empty(), "Bot stop point has an unresolved combat")
	_check(rules.state.data.get("pending_reaction", {}).is_empty(), "Bot stop point has an unresolved reaction")
	var completed_rounds: int = mini(20, int(rules.state.data["round_number"]) - 1)
	for round_number: int in range(1, completed_rounds + 1):
		for cycle: int in [1, 2]:
			for player: String in ["p1", "p2", "p3", "p4"]:
				var key: String = "%s:%s:%s" % [round_number, cycle, player]
				_check(int(actions.get(key, 0)) == 1, "Bot lost or duplicated scheduled action: " + key)
	_check(int(event_counts.get("CombatResolved", 0)) > 0, "Bot fixture did not exercise combat")
	_check(int(event_counts.get("LocationCaptured", 0)) > 0, "Bot fixture did not capture any location")
	_check(int(event_counts.get("HeroMoved", 0)) > 0, "Bot fixture did not exercise movement")
	_check(guards > 0, "Bot purity guards did not run")
	var replay: RefCounted = Rules.new(seed_value)
	for command: Dictionary in rules.state.data["commands"]:
		var replay_result: Dictionary = replay.execute(command)
		if not replay_result.get("is_valid", false):
			errors.append("20-round replay rejected " + JSON.stringify(command))
			return
	_check(replay.checksum() == rules.checksum(), "20-round replay diverged in state, events, or RNG")
	print("Bot simulation: seed %s, %s complete rounds%s, %s commands, %s combats, %s captures, %s saved decision stages; checksum %s" % [seed_value, completed_rounds, " and victory" if won else "", attempts, event_counts.get("CombatResolved", 0), event_counts.get("LocationCaptured", 0), pending_stages_saved.size(), rules.checksum()])
