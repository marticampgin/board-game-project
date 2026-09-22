extends RefCounted
## One authoritative command path for UI, CLI, tests, replay, and bots.
## Validation is pure: no accepted command, event, state version, or RNG changes
## occur until every precondition has passed.
const State = preload("res://scripts/domain/state/game_state.gd")
const Catalog = preload("res://scripts/domain/definitions/definition_catalog.gd")
const Enums = preload("res://scripts/domain/game_enums.gd")
const Event = preload("res://scripts/domain/events/domain_event.gd")
const Result = preload("res://scripts/domain/commands/validation_result.gd")
const Hex = preload("res://scripts/domain/hex/hex.gd")
const Generator = preload("res://scripts/domain/generation/map_generator.gd")
const Movement = preload("res://scripts/domain/resolvers/movement.gd")
const Rng = preload("res://scripts/services/deterministic_rng.gd")

var state: State
var definitions: Catalog
var _rng: RefCounted
var _emitted: Array = []

func _init(seed: int = 20260922, initialize: bool = true) -> void:
	definitions = Catalog.new()
	assert(definitions.errors.is_empty(), "Definitions failed validation: " + str(definitions.errors))
	_rng = Rng.new(seed)
	if initialize:
		_start_game(seed)

static func from_snapshot(values: Dictionary) -> RefCounted:
	var restored: RefCounted = State.from_dict(values)
	if restored == null:
		return null
	var script: GDScript = load("res://scripts/domain/game_rules.gd")
	var rules: RefCounted = script.new(int(values.master_seed), false)
	rules.state = restored
	rules._rng.restore(restored.data.rng)
	return rules

func _start_game(seed: int) -> void:
	var map: Dictionary = Generator.generate(seed)
	var heroes: Dictionary = {}
	for seat: int in range(4):
		var player_id: String = Enums.PLAYER_IDS[seat]
		var class_id: String = definitions.rules.class_order[seat]
		var definition: Dictionary = definitions.classes[class_id]
		heroes[player_id] = {
			"id": player_id, "player_id": player_id, "class_id": class_id, "name": definition.name,
			"hp": int(definition.hp), "max_hp": int(definition.hp), "attack": int(definition.attack),
			"defence": int(definition.defence), "speed": int(definition.speed), "move": int(definition.move),
			"hex": map.sanctuaries[seat], "sanctuary": map.sanctuaries[seat],
			"gold": int(definitions.rules.starting_gold), "power": int(definitions.rules.starting_power),
			"fate": int(definitions.rules.starting_fate), "relics": [], "statuses": {}, "flags": {},
			"controlled_locations": [], "upgrades": []
		}
	state = State.new({
		"schema_version": 1, "content_version": definitions.rules.content_version,
		"master_seed": seed, "round_number": 1, "phase": "world", "action_cycle": 0,
		"current_actor_index": 0, "initiative_order": [], "initiative_scores": {},
		"heroes": heroes, "map": map, "plans": {}, "ready": [], "rng": _rng.snapshot(),
		"command_sequence": 0, "event_sequence": 0, "state_version": 0, "events": [], "commands": []
	})
	_emit("GameCreated", "", {"seed": seed, "content_version": definitions.rules.content_version, "map_report": map.report})
	_emit("RoundStarted", "", {"round": 1, "world_event": "none_first_round"})
	for player_id: String in Enums.PLAYER_IDS:
		_discover(player_id)
	_emitted.clear()

func snapshot() -> Dictionary:
	return state.to_dict()

func checksum() -> String:
	return state.checksum()

func current_actor() -> String:
	if state.data.phase not in ["cycle_1", "cycle_2"]:
		return ""
	return str(state.data.initiative_order[state.data.current_actor_index])

func execute(command: Dictionary) -> Dictionary:
	var validation: Dictionary = _validate(command)
	if not validation.is_valid:
		return validation
	_emitted = []
	var kind: String = command.type
	var player_id: String = command.get("player_id", "")
	match kind:
		"advance":
			_advance()
		"submit_plan":
			state.data.plans[player_id] = command.plan.duplicate(true)
			_emit("PlanSubmitted", player_id, {"submitted": true})
		"ready":
			if not state.data.plans.has(player_id):
				state.data.plans[player_id] = {}
			state.data.ready.append(player_id)
			_emit("PlayerReady", player_id, {"ready_count": state.data.ready.size()})
			if state.data.ready.size() == 4:
				_emit("PlanningCompleted", "", {"players": Enums.PLAYER_IDS.duplicate()})
				_set_phase("initiative")
				_roll_initiative()
		"move":
			_start_action(player_id, kind)
			_move(player_id, command.target)
			_finish_action(player_id, kind)
		"capture":
			_start_action(player_id, kind)
			_capture(player_id)
			_finish_action(player_id, kind)
		"pass":
			_start_action(player_id, kind)
			_emit("ActionPassed", player_id, {})
			_finish_action(player_id, kind)
	state.data.command_sequence += 1
	state.data.state_version += 1
	state.data.commands.append(command.duplicate(true))
	state.data.rng = _rng.snapshot()
	return Result.new(true, "OK", "Command accepted", int(state.data.state_version), _emitted).to_dict()

func _reject(code: String, message: String) -> Dictionary:
	return Result.new(false, code, message, int(state.data.state_version)).to_dict()

func _validate(command: Dictionary) -> Dictionary:
	if not State.is_serializable(command) or not command.get("type") is String:
		return _reject("INVALID_COMMAND", "A command requires a string type and serializable payload.")
	if not Enums.COMMAND_IDS.has(command.type):
		return _reject("UNKNOWN_COMMAND", "Unknown command: " + command.type)
	if command.has("expected_version"):
		if not (command.expected_version is int or command.expected_version is float) or command.expected_version != state.data.state_version:
			return _reject("STALE_STATE", "Expected state version does not match authoritative state.")
	if command.has("expected_phase") and command.expected_phase != state.data.phase:
		return _reject("PHASE_MISMATCH", "Expected phase does not match authoritative phase.")
	if command.has("command_id"):
		if not command.command_id is String or command.command_id.is_empty():
			return _reject("INVALID_COMMAND", "Command ID must be a nonempty string.")
		for previous: Dictionary in state.data.commands:
			if previous.get("command_id", "") == command.command_id:
				return _reject("DUPLICATE_COMMAND", "This command ID has already been accepted.")
	if command.type == "advance":
		if state.data.phase not in ["world", "initiative", "bonus", "resolution"]:
			return _reject("WRONG_PHASE", "This phase advances through player commands.")
		return {"is_valid": true}
	if not command.get("player_id") is String or not state.data.heroes.has(command.player_id):
		return _reject("UNKNOWN_PLAYER", "Player ID must identify one of the four seats.")
	var player_id: String = command.player_id
	if command.type in ["submit_plan", "ready"]:
		if state.data.phase != "planning":
			return _reject("WRONG_PHASE", "Plans and Ready are only legal during Planning.")
		if state.data.ready.has(player_id):
			return _reject("ALREADY_READY", "The submitted plan is locked after Ready.")
		if command.type == "submit_plan":
			if not command.get("plan") is Dictionary:
				return _reject("INVALID_PLAN", "The plan must be a dictionary.")
			if not command.plan.is_empty() and command.plan != {"no_change": true}:
				return _reject("INVALID_PLAN", "Milestone 1 supports an empty no-change plan.")
		return {"is_valid": true}
	if state.data.phase not in ["cycle_1", "cycle_2"]:
		return _reject("WRONG_PHASE", "Normal actions require an Action Cycle.")
	if current_actor() != player_id:
		return _reject("NOT_CURRENT_ACTOR", "Wait for this hero's scheduled action.")
	if command.type == "move":
		if not command.get("target") is String:
			return _reject("INVALID_TARGET", "Move requires a hex key target.")
		var reachable: Dictionary = Movement.reachable(state.data.map, state.data.heroes, player_id)
		if not reachable.has(command.target):
			return _reject("TARGET_OUT_OF_RANGE", "Destination is blocked, occupied, or outside movement range.")
	if command.type == "capture":
		return _capture_validation(player_id)
	return {"is_valid": true}

func _capture_validation(player_id: String) -> Dictionary:
	var location: Dictionary = _hero_location(player_id)
	if location.is_empty() or location.kind != "minor_tower":
		return _reject("NOT_CAPTURABLE", "Stand on a Minor Tower to Capture in this milestone.")
	if location.owner_id == player_id:
		return _reject("ALREADY_CONTROLLED", "This hero already controls the tower.")
	if not location.discovered_by.has(player_id):
		return _reject("TARGET_NOT_DISCOVERED", "The location has not been discovered.")
	for other_id: String in state.data.heroes:
		if other_id != player_id and state.data.heroes[other_id].hex == location.hex:
			return _reject("LOCATION_OCCUPIED", "An enemy hero must be displaced before Capture.")
	return {"is_valid": true}

func legal_actions(player_id: String) -> Dictionary:
	if not state.data.heroes.has(player_id):
		return {}
	if state.data.phase in ["world", "initiative", "bonus", "resolution"]:
		return {"advance": {"phase": state.data.phase}}
	if state.data.phase == "planning":
		if state.data.ready.has(player_id):
			return {}
		return {"submit_plan": {"choices": ["no_change"]}, "ready": {}}
	if current_actor() != player_id:
		return {}
	var actions: Dictionary = {"pass": {}, "move": {"targets": Movement.reachable(state.data.map, state.data.heroes, player_id)}}
	if _capture_validation(player_id).is_valid:
		var location: Dictionary = _hero_location(player_id)
		actions.capture = {"location_id": location.id, "automatic": str(location.owner_id).is_empty(), "defence": _tower_defence(location)}
	return actions

func _advance() -> void:
	match str(state.data.phase):
		"world":
			_set_phase("planning")
		"initiative":
			state.data.current_actor_index = 0
			_set_phase("cycle_1")
		"bonus":
			_emit("BonusCycleCompleted", "", {"actions_granted": 0})
			_set_phase("resolution")
		"resolution":
			_resolve_round()

func _set_phase(next_phase: String) -> void:
	var previous: String = state.data.phase
	state.data.phase = next_phase
	state.data.action_cycle = 1 if next_phase == "cycle_1" else (2 if next_phase == "cycle_2" else (3 if next_phase == "bonus" else 0))
	_emit("PhaseChanged", "", {"from": previous, "to": next_phase, "current_actor": current_actor()})

func _roll_initiative() -> void:
	var scores: Dictionary = {}
	var ordered: Array[String] = Enums.PLAYER_IDS.duplicate()
	for player_id: String in ordered:
		var roll: Dictionary = _draw("initiative", 1, 3, player_id, "initiative")
		var speed: int = state.data.heroes[player_id].speed
		scores[player_id] = speed + int(roll.result)
		_emit("InitiativeRolled", player_id, {"speed": speed, "die": roll.result, "modifier": 0, "score": scores[player_id]})
	ordered.sort_custom(func(a: String, b: String) -> bool: return scores[a] > scores[b] if scores[a] != scores[b] else a < b)
	var group_start: int = 0
	while group_start < ordered.size():
		var group_end: int = group_start + 1
		while group_end < ordered.size() and scores[ordered[group_start]] == scores[ordered[group_end]]:
			group_end += 1
		for index: int in range(group_end - 1, group_start, -1):
			var tie: Dictionary = _draw("tie_breaks", group_start, index, "", "initiative_tie")
			var swap: int = tie.result
			var temporary: String = ordered[index]
			ordered[index] = ordered[swap]
			ordered[swap] = temporary
		if group_end - group_start > 1:
			_emit("InitiativeTieResolved", "", {"score": scores[ordered[group_start]], "order": ordered.slice(group_start, group_end)})
		group_start = group_end
	state.data.initiative_scores = scores
	state.data.initiative_order = ordered
	state.data.current_actor_index = 0
	_emit("InitiativeOrderChanged", "", {"order": ordered.duplicate(), "scores": scores.duplicate()})

func _draw(stream: String, minimum: int, maximum: int, actor: String, cause: String) -> Dictionary:
	var roll: Dictionary = _rng.draw(stream, minimum, maximum)
	var details: Dictionary = roll.duplicate(true)
	details.cause = cause
	_emit("DieRolled", actor, details)
	return roll

func _start_action(player_id: String, kind: String) -> void:
	_emit("ActionStarted", player_id, {"action": kind, "cycle": state.data.action_cycle, "actor_index": state.data.current_actor_index})

func _finish_action(player_id: String, kind: String) -> void:
	_emit("ActionCompleted", player_id, {"action": kind, "cycle": state.data.action_cycle})
	state.data.current_actor_index += 1
	if state.data.current_actor_index >= state.data.initiative_order.size():
		state.data.current_actor_index = 0
		_set_phase("cycle_2" if state.data.phase == "cycle_1" else "bonus")
	else:
		_emit("ActorChanged", "", {"current_actor": current_actor(), "actor_index": state.data.current_actor_index})

func _move(player_id: String, target: String) -> void:
	var hero: Dictionary = state.data.heroes[player_id]
	var route: Dictionary = Movement.reachable(state.data.map, state.data.heroes, player_id)[target]
	var origin: String = hero.hex
	hero.hex = target
	_emit("HeroMoved", player_id, {"from": origin, "to": target, "path": route.path, "cost": route.cost, "road_only": route.road_only})
	_discover(player_id)

func _hero_location(player_id: String) -> Dictionary:
	var hex_id: String = state.data.heroes[player_id].hex
	var location_id: String = state.data.map.hexes[hex_id].get("location_id", "")
	return state.data.map.locations.get(location_id, {})

func _tower_defence(location: Dictionary) -> int:
	var tower_trait: Dictionary = definitions.tower_traits.get(location.trait, {})
	return int(definitions.rules.tower_defence) + int(location.level) - 1 + int(tower_trait.get("tower_defence", 0))

func _capture(player_id: String) -> void:
	var location: Dictionary = _hero_location(player_id)
	var previous_owner: String = location.owner_id
	if not previous_owner.is_empty():
		var hero: Dictionary = state.data.heroes[player_id]
		var attack_bonus: int = 1 if hero.class_id == "warlord" else 0
		var roll: Dictionary = _draw("combat", 1, 6, player_id, "tower_capture")
		var total: int = int(hero.attack) + attack_bonus + int(roll.result)
		var defence: int = _tower_defence(location)
		_emit("TowerCaptureResolved", player_id, {"location_id": location.id, "attack": hero.attack, "martial_presence": attack_bonus, "die": roll.result, "total": total, "defence": defence, "success": total > defence})
		if total <= defence:
			return
	if not previous_owner.is_empty():
		state.data.heroes[previous_owner].controlled_locations.erase(location.id)
	location.owner_id = player_id
	state.data.heroes[player_id].controlled_locations.append(location.id)
	_emit("LocationCaptured", player_id, {"location_id": location.id, "kind": location.kind, "previous_owner": previous_owner, "owner_id": player_id})
	_discover(player_id)

func _discover(player_id: String) -> void:
	var hero: Dictionary = state.data.heroes[player_id]
	var origins: Array = [{"hex": hero.hex, "radius": int(definitions.rules.discovery_radius)}]
	for location_id: String in hero.controlled_locations:
		var controlled: Dictionary = state.data.map.locations[location_id]
		var tower_trait: Dictionary = definitions.tower_traits.get(controlled.trait, {})
		if int(tower_trait.get("vision_radius", 0)) > 0:
			origins.append({"hex": controlled.hex, "radius": int(tower_trait.vision_radius)})
	var location_ids: Array = state.data.map.locations.keys()
	location_ids.sort()
	for location_id: String in location_ids:
		var location: Dictionary = state.data.map.locations[location_id]
		if location.discovered_by.has(player_id):
			continue
		for origin: Dictionary in origins:
			if Hex.distance(origin.hex, location.hex) <= int(origin.radius):
				location.discovered_by.append(player_id)
				_emit("LocationDiscovered", player_id, {"location_id": location_id, "hex": location.hex, "kind": location.kind, "trait": location.trait})
				break

func _resolve_round() -> void:
	_emit("ResolutionStarted", "", {"order": ["claims", "income", "new_claims", "recovery", "statuses", "flags", "fate", "snapshot"]})
	var location_ids: Array = state.data.map.locations.keys()
	location_ids.sort()
	for location_id: String in location_ids:
		var location: Dictionary = state.data.map.locations[location_id]
		var owner_id: String = location.owner_id
		if owner_id.is_empty():
			continue
		var hero: Dictionary = state.data.heroes[owner_id]
		var resource: String = "power"
		var amount: int = 0
		match str(location.kind):
			"minor_tower": amount = int(definitions.rules.minor_tower_income)
			"ancient_tower", "worldspire": amount = int(definitions.rules.ancient_tower_income)
			"settlement":
				resource = "gold"
				amount = int(definitions.rules.settlement_income)
		var before: int = hero[resource]
		hero[resource] = mini(before + amount, int(definitions.rules.power_cap)) if resource == "power" else before + amount
		_emit("IncomeGranted", owner_id, {"location_id": location_id, "resource": resource, "amount": int(hero[resource]) - before, "base_amount": amount, "before": before, "after": hero[resource], "capped": int(hero[resource]) < before + amount})
	for player_id: String in Enums.PLAYER_IDS:
		var hero: Dictionary = state.data.heroes[player_id]
		if not hero.flags.get("downed_this_round", false):
			var before: int = hero.hp
			hero.hp = mini(int(hero.max_hp), before + int(definitions.rules.round_healing))
			_emit("HeroHealed", player_id, {"cause": "resolution", "amount": int(hero.hp) - before, "before": before, "after": hero.hp})
	for player_id: String in Enums.PLAYER_IDS:
		var hero: Dictionary = state.data.heroes[player_id]
		var status_ids: Array = hero.statuses.keys()
		status_ids.sort()
		for status_id: String in status_ids:
			if hero.statuses[status_id] is Dictionary and hero.statuses[status_id].has("remaining_rounds"):
				hero.statuses[status_id].remaining_rounds -= 1
				if hero.statuses[status_id].remaining_rounds <= 0:
					hero.statuses.erase(status_id)
					_emit("StatusExpired", player_id, {"status_id": status_id})
		hero.flags.clear()
	for player_id: String in Enums.PLAYER_IDS:
		var hero: Dictionary = state.data.heroes[player_id]
		var before: int = hero.fate
		hero.fate = mini(int(definitions.rules.fate_cap), before + int(definitions.rules.round_fate))
		_emit("FateGained", player_id, {"cause": "resolution", "amount": int(hero.fate) - before, "before": before, "after": hero.fate})
	_emit("ResolutionCompleted", "", {"round": state.data.round_number})
	state.data.plans = {}
	state.data.ready = []
	state.data.round_number += 1
	state.data.current_actor_index = 0
	_set_phase("world")
	_emit("RoundStarted", "", {"round": state.data.round_number, "world_event": "deferred_milestone_3"})

func _emit(event_type: String, actor_id: String, details: Dictionary) -> void:
	state.data.event_sequence += 1
	var event: Dictionary = Event.new(int(state.data.event_sequence), event_type, int(state.data.round_number), state.data.phase, actor_id, details).to_dict()
	state.data.events.append(event)
	_emitted.append(event)
