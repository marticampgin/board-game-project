extends RefCounted
const Rules = preload("res://scripts/domain/game_rules.gd")
const State = preload("res://scripts/domain/state/game_state.gd")
const Catalog = preload("res://scripts/domain/definitions/definition_catalog.gd")
const Hex = preload("res://scripts/domain/hex/hex.gd")
var errors: Array[String] = []

func run() -> Array[String]:
	errors.clear()
	_test_definitions_and_initial_state()
	_test_serialization_and_rejection()
	_test_guards_and_planning()
	_test_rounds_and_initiative()
	_test_movement_capture_income()
	_test_contested_capture()
	_test_replay_and_save_continuation()
	return errors

func _check(condition: bool, detail: String) -> void:
	if not condition:
		errors.append(detail)

func _accept(game: RefCounted, command: Dictionary) -> Dictionary:
	var result: Dictionary = game.execute(command)
	_check(result.is_valid, "Expected accepted command %s: %s" % [command, result])
	return result

func _reject_unchanged(game: RefCounted, command: Dictionary, code: String) -> void:
	var before: String = game.checksum()
	var rng_before: Dictionary = game.snapshot().rng
	var result: Dictionary = game.execute(command)
	_check(not result.is_valid and result.reason_code == code, "Expected %s for %s, got %s" % [code, command, result.reason_code])
	_check(game.checksum() == before, "Rejected command mutated authoritative state: " + str(command))
	_check(game.snapshot().rng == rng_before, "Rejected command consumed RNG")
	_check(result.events.is_empty(), "Rejected command emitted events")

func _start_actions(game: RefCounted) -> void:
	_accept(game, {"type": "advance"})
	for player_id: String in ["p1", "p2", "p3", "p4"]:
		_accept(game, {"type": "ready", "player_id": player_id})
	_accept(game, {"type": "advance"})

func _finish_round(game: RefCounted) -> void:
	var guard: int = 0
	while game.state.data.phase in ["cycle_1", "cycle_2"] and guard < 8:
		_accept(game, {"type": "pass", "player_id": game.current_actor()})
		guard += 1
	_accept(game, {"type": "advance"})
	_accept(game, {"type": "advance"})

func _test_definitions_and_initial_state() -> void:
	var catalog: RefCounted = Catalog.new()
	_check(catalog.errors.is_empty(), "Definitions load and validate")
	_check(catalog.classes.size() == 4 and catalog.tower_traits.size() == 2, "Four classes and two traits loaded")
	var game: RefCounted = Rules.new(17)
	_check(game.state.data.phase == "world" and game.state.data.round_number == 1, "Starts at round 1 World")
	_check(game.current_actor().is_empty(), "World has no active hero")
	_check(game.snapshot().map.hexes.size() == 61, "Logical board contains 61 hexes")
	var expected: Dictionary = {"p1": [8, 3, 2, 5], "p2": [12, 5, 4, 2], "p3": [9, 2, 3, 3], "p4": [9, 3, 2, 3]}
	for player_id: String in expected:
		var hero: Dictionary = game.state.data.heroes[player_id]
		_check([hero.hp, hero.attack, hero.defence, hero.speed] == expected[player_id], "Prototype stats for " + player_id)
		_check(hero.gold == 4 and hero.power == 2 and hero.fate == 1 and hero.relics.is_empty(), "Starting resources for " + player_id)
		_check(hero.hex == hero.sanctuary and hero.controlled_locations.is_empty(), "Starting sanctuary for " + player_id)
		for location: Dictionary in game.state.data.map.locations.values():
			if Hex.distance(hero.hex, location.hex) <= 2:
				_check(location.discovered_by.has(player_id), "Range-2 discovery at spawn")
	var snapshot: Dictionary = game.snapshot()
	snapshot.heroes.p1.hp = 1
	_check(game.state.data.heroes.p1.hp == 8, "Snapshots cannot mutate live state")

func _test_serialization_and_rejection() -> void:
	var game: RefCounted = Rules.new(9183)
	var snapshot: Dictionary = game.snapshot()
	_check(State.validation_errors(snapshot).is_empty(), "Generated state validates: " + str(State.validation_errors(snapshot)))
	var loaded: RefCounted = State.from_dict(JSON.parse_string(game.state.to_json()))
	_check(loaded != null and loaded.checksum() == game.checksum(), "JSON save round trip preserves checksum")
	_check(State.canonical_json({"b": 2, "a": 1}) == State.canonical_json({"a": 1.0, "b": 2.0}), "Canonical JSON ignores dictionary order and JSON integer conversion")
	for bad_field: String in ["schema", "content", "class", "trait", "rng", "phase", "hero", "object"]:
		var bad: Dictionary = snapshot.duplicate(true)
		match bad_field:
			"schema": bad.schema_version = 9000
			"content": bad.content_version = "missing"
			"class": bad.heroes.p1.class_id = "missing"
			"trait": bad.map.locations[bad.map.locations.keys()[0]].trait = "missing"
			"rng": bad.rng.streams.combat.state = 0
			"phase": bad.phase = "unknown"
			"hero": bad.heroes.p1.hex = "999,999"
			"object": bad.extra = RefCounted.new()
		_check(State.from_dict(bad) == null, "Reject corrupt snapshot: " + bad_field)
	_reject_unchanged(game, {}, "INVALID_COMMAND")
	_reject_unchanged(game, {"type": "cheat"}, "UNKNOWN_COMMAND")
	_reject_unchanged(game, {"type": "move", "player_id": "p1", "target": "0,0"}, "WRONG_PHASE")
	_reject_unchanged(game, {"type": "ready", "player_id": "p99"}, "UNKNOWN_PLAYER")
	_reject_unchanged(game, {"type": "advance", "node": RefCounted.new()}, "INVALID_COMMAND")

func _test_guards_and_planning() -> void:
	var game: RefCounted = Rules.new(42)
	_reject_unchanged(game, {"type": "advance", "expected_version": 1}, "STALE_STATE")
	_reject_unchanged(game, {"type": "advance", "expected_phase": "planning"}, "PHASE_MISMATCH")
	_accept(game, {"type": "advance", "command_id": "first", "expected_version": 0.0, "expected_phase": "world"})
	_reject_unchanged(game, {"type": "advance", "command_id": "first"}, "DUPLICATE_COMMAND")
	_reject_unchanged(game, {"type": "advance"}, "WRONG_PHASE")
	_reject_unchanged(game, {"type": "submit_plan", "player_id": "p1", "plan": {"gold": 999}}, "INVALID_PLAN")
	for player_id: String in ["p4", "p2", "p1", "p3"]:
		_accept(game, {"type": "submit_plan", "player_id": player_id, "plan": {"no_change": true}})
	_check(game.state.data.phase == "planning" and game.state.data.initiative_order.is_empty(), "Submitted plans are stored without prematurely resolving")
	_accept(game, {"type": "ready", "player_id": "p1"})
	_reject_unchanged(game, {"type": "ready", "player_id": "p1"}, "ALREADY_READY")
	_reject_unchanged(game, {"type": "submit_plan", "player_id": "p1", "plan": {}}, "ALREADY_READY")
	for player_id: String in ["p2", "p3", "p4"]:
		_accept(game, {"type": "ready", "player_id": player_id})
	_check(game.state.data.phase == "initiative", "All four ready reveals Initiative phase")
	_check(game.state.data.plans.size() == 4, "All simultaneous plans retained until resolution")
	_check(game.current_actor().is_empty(), "Initiative is visible before cycle starts")

func _test_rounds_and_initiative() -> void:
	var game: RefCounted = Rules.new(21)
	var second: RefCounted = Rules.new(21)
	_start_actions(game)
	_start_actions(second)
	_check(game.checksum() == second.checksum(), "Same seed and fixture have identical complete state")
	var order: Array = game.state.data.initiative_order.duplicate()
	for player_id: String in order:
		var delta: int = int(game.state.data.initiative_scores[player_id]) - int(game.state.data.heroes[player_id].speed)
		_check(delta >= 1 and delta <= 3, "Initiative = Speed + d3")
	var acted: Dictionary = {"p1": 0, "p2": 0, "p3": 0, "p4": 0}
	for cycle: int in [1, 2]:
		_check(game.state.data.action_cycle == cycle, "Expected action cycle " + str(cycle))
		for player_id: String in order:
			_check(game.current_actor() == player_id, "Stable interleaved initiative order")
			var other: String = "p2" if player_id == "p1" else "p1"
			_reject_unchanged(game, {"type": "pass", "player_id": other}, "NOT_CURRENT_ACTOR")
			_accept(game, {"type": "pass", "player_id": player_id})
			acted[player_id] += 1
	_check(game.state.data.phase == "bonus" and game.current_actor().is_empty(), "Bonus visible after all eight actions")
	for count: int in acted.values():
		_check(count == 2, "Exactly two actions per hero")
	_reject_unchanged(game, {"type": "pass", "player_id": "p1"}, "WRONG_PHASE")
	_accept(game, {"type": "advance"})
	_check(game.state.data.phase == "resolution", "Resolution is independently visible")
	_accept(game, {"type": "advance"})
	_check(game.state.data.phase == "world" and game.state.data.round_number == 2, "Round increments once")
	_check(game.state.data.ready.is_empty() and game.state.data.plans.is_empty(), "Planning reset for new round")
	for round_index: int in range(5):
		_start_actions(game)
		_finish_round(game)
	for hero: Dictionary in game.state.data.heroes.values():
		_check(hero.fate == 5, "Resolution Fate capped at five")
	var phases: Dictionary = {}
	for event: Dictionary in game.state.data.events:
		if event.type == "PhaseChanged": phases[event.data.to] = true
	_check(phases.size() == 7, "All seven phases emit visible transitions")

func _test_movement_capture_income() -> void:
	var game: RefCounted = Rules.new(123)
	_start_actions(game)
	var player_id: String = game.current_actor()
	var hero: Dictionary = game.state.data.heroes[player_id]
	var targets: Dictionary = game.legal_actions(player_id).move.targets
	_check(not targets.is_empty(), "Initial hero has reachable movement")
	_reject_unchanged(game, {"type": "move", "player_id": player_id, "target": "999,999"}, "TARGET_OUT_OF_RANGE")
	_reject_unchanged(game, {"type": "capture", "player_id": player_id}, "NOT_CAPTURABLE")
	var target: String = targets.keys()[0]
	var before_hex: String = hero.hex
	var result: Dictionary = _accept(game, {"type": "move", "player_id": player_id, "target": target})
	_check(hero.hex == target and hero.hex != before_hex, "Move immediately updates authoritative coordinate")
	var logged: bool = false
	for event: Dictionary in result.events:
		if event.type == "HeroMoved":
			logged = event.data.path[0] == before_hex and event.data.path.back() == target and event.data.cost > 0
	_check(logged, "Move event reports full route and weighted cost")
	# Explicit fixture places current actor on a real tower to isolate ownership/economy.
	player_id = game.current_actor()
	hero = game.state.data.heroes[player_id]
	var tower: Dictionary = {}
	for location: Dictionary in game.state.data.map.locations.values():
		if location.kind == "minor_tower" and location.hex != target:
			tower = location
			break
	hero.hex = tower.hex
	if not tower.discovered_by.has(player_id): tower.discovered_by.append(player_id)
	var rng_before: Dictionary = game.snapshot().rng
	_accept(game, {"type": "capture", "player_id": player_id})
	_check(tower.owner_id == player_id and hero.controlled_locations.has(tower.id), "Minor Tower capture transfers ownership in one action")
	_check(game.snapshot().rng == rng_before, "Neutral capture consumes no RNG")
	hero.power = 12
	hero.hp = int(hero.max_hp) - 2
	hero.flags.test_flag = true
	_finish_round(game)
	_check(hero.power == 12, "Tower income respects Power cap")
	_check(hero.hp == int(hero.max_hp) - 1, "Resolution heals one Health")
	_check(hero.flags.is_empty(), "Resolution resets once-per-round flags even without statuses")
	var income_sequence: int = 0
	var heal_sequence: int = 0
	var fate_sequence: int = 0
	for event: Dictionary in game.state.data.events:
		if event.actor_id == player_id:
			if event.type == "IncomeGranted": income_sequence = event.sequence
			if event.type == "HeroHealed": heal_sequence = event.sequence
			if event.type == "FateGained": fate_sequence = event.sequence
	_check(income_sequence > 0 and income_sequence < heal_sequence and heal_sequence < fate_sequence, "Resolution order: income, healing, Fate")
	hero.power = 2
	_start_actions(game)
	_finish_round(game)
	_check(hero.power == 3, "Minor Tower pays one Power each Resolution")

func _test_contested_capture() -> void:
	var game: RefCounted = Rules.new(551)
	_start_actions(game)
	var player_id: String = game.current_actor()
	var owner: String = "p2" if player_id != "p2" else "p3"
	var tower: Dictionary = {}
	for location: Dictionary in game.state.data.map.locations.values():
		if location.kind == "minor_tower":
			tower = location
			break
	tower.owner_id = owner
	game.state.data.heroes[owner].controlled_locations.append(tower.id)
	game.state.data.heroes[player_id].hex = tower.hex
	game.state.data.heroes[player_id].attack = 10
	if not tower.discovered_by.has(player_id): tower.discovered_by.append(player_id)
	var result: Dictionary = _accept(game, {"type": "capture", "player_id": player_id})
	_check(tower.owner_id == player_id, "Successful contested capture transfers tower")
	_check(not game.state.data.heroes[owner].controlled_locations.has(tower.id), "Previous owner loses controlled location")
	var calculation: bool = false
	for event: Dictionary in result.events:
		if event.type == "TowerCaptureResolved":
			calculation = event.data.success and event.data.total == event.data.attack + event.data.martial_presence + event.data.die
	_check(calculation, "Contested capture emits reproducible complete calculation")

func _test_replay_and_save_continuation() -> void:
	var first: RefCounted = Rules.new(444)
	for round_index: int in range(3):
		_start_actions(first)
		_finish_round(first)
	var replay: RefCounted = Rules.new(444)
	for command: Dictionary in first.state.data.commands:
		_accept(replay, command)
	_check(first.checksum() == replay.checksum(), "Accepted-command replay reproduces three-round checksum")
	var restored: RefCounted = Rules.from_snapshot(JSON.parse_string(first.state.to_json()))
	_check(restored != null, "Restore full rules engine from JSON")
	if restored == null:
		return
	_check(restored.checksum() == first.checksum(), "Restored state checksum matches")
	_start_actions(first)
	_start_actions(restored)
	_check(first.checksum() == restored.checksum(), "RNG continuation survives save/load")
	for index: int in range(8):
		var checkpoint: RefCounted = Rules.from_snapshot(first.snapshot())
		_check(checkpoint != null, "Save/load is valid during every action")
		_accept(first, {"type": "pass", "player_id": first.current_actor()})
