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
const Battle = preload("res://scripts/domain/resolvers/battle_flow.gd")
const Classes = preload("res://scripts/domain/resolvers/class_flow.gd")

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
	# Generation owns an isolated instance, then hands its stream state into the
	# match so diagnostics and saved RNG continuation include every map draw.
	_rng.restore(map.report.rng)
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
			"controlled_locations": [], "upgrades": [], "prepared_hex": {}
		}
	state = State.new({
		"schema_version": 1, "content_version": definitions.rules.content_version,
		"master_seed": seed, "round_number": 1, "phase": "world", "action_cycle": 0,
		"current_actor_index": 0, "initiative_order": [], "initiative_scores": {},
		"heroes": heroes, "map": map, "plans": {}, "ready": [], "rng": _rng.snapshot(),
		"command_sequence": 0, "event_sequence": 0, "state_version": 0, "events": [], "commands": [],
		"monsters": {}, "pending_combat": {}, "pending_reaction": {}, "pending_move": {},
		"traps": {}, "commitments": {}, "ground_loot": {}, "cycle_2_modifiers": {}, "next_cycle_order": []
	})
	for index: int in range(4):
		var monster_id: String = "monster_%d" % (index + 1)
		var profile_id: String = ["wolf_pack", "stone_guardian", "relic_wraith", "wolf_pack"][index]
		var profile: Dictionary = definitions.monsters[profile_id]
		var camp_id: String = "camp_%d" % (index + 1)
		state.data.monsters[monster_id] = {"id": monster_id, "definition_id": profile_id, "name": profile.name, "camp_id": camp_id, "hex": map.locations[camp_id].hex, "hp": int(profile.hp), "max_hp": int(profile.hp), "attack": int(profile.attack), "defence": int(profile.defence)}
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
			_emit("PlanSubmitted", player_id, {"submitted": true}, "owner_only")
		"ready":
			if not state.data.plans.has(player_id):
				state.data.plans[player_id] = {}
			state.data.ready.append(player_id)
			_emit("PlayerReady", player_id, {"ready_count": state.data.ready.size()})
			if state.data.ready.size() == 4:
				Classes.apply_plans(self)
				_emit("PlanningCompleted", "", {"players": Enums.PLAYER_IDS.duplicate()})
				_set_phase("initiative")
				_roll_initiative()
		"move":
			_start_action(player_id, kind)
			Classes.begin_move(self, player_id, command.target, false)
		"capture":
			_start_action(player_id, kind)
			_capture(player_id)
			_finish_action(player_id, kind)
		"pass":
			_start_action(player_id, kind)
			_emit("ActionPassed", player_id, {})
			_finish_action(player_id, kind)
		"attack":
			_start_action(player_id, kind)
			Battle.declare(self, player_id, command.target_id)
		"choose_stance": Battle.choose_stance(self, player_id, command.stance)
		"spend_fate": Battle.fate_decision(self, player_id, true)
		"decline_fate": Battle.fate_decision(self, player_id, false)
		"displace": Battle.displace(self, player_id, command.target)
		"resolve_reaction":
			if state.data.pending_reaction.kind == "challenge": Classes.challenge_decision(self, command.choice)
			else: Battle.reaction(self, command.choice)
		"special":
			_start_action(player_id, kind)
			if command.special_id == "forced_march": Classes.begin_move(self, player_id, command.target, true)
			else:
				var hero: Dictionary = state.data.heroes[player_id]
				var before: int = hero.hp
				hero.hp = mini(int(hero.max_hp), before + 3)
				_emit("HeroHealed", player_id, {"cause": "rest", "amount": int(hero.hp) - before, "before": before, "after": hero.hp})
				_finish_action(player_id, kind)
		"upgrade":
			_start_action(player_id, kind)
			_upgrade(player_id)
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
	if not state.data.pending_reaction.is_empty() or not state.data.pending_combat.is_empty():
		if not command.get("player_id") is String or not state.data.heroes.has(command.player_id):
			return _reject("UNKNOWN_PLAYER", "A pending decision requires its participant's player ID.")
		if not state.data.pending_reaction.is_empty():
			var reaction: Dictionary = state.data.pending_reaction
			if command.type != "resolve_reaction" or command.player_id != reaction.actor_id:
				return _reject("REACTION_REQUIRED", "The eligible reaction owner must accept or decline.")
			if not reaction.choices.has(command.get("choice", "")):
				return _reject("INVALID_REACTION_CHOICE", "Choose accept or decline.")
			return {"is_valid": true}
		return Battle.validate_window(self, command)
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
			return Classes.validate_plan(self, player_id, command.plan)
		return {"is_valid": true}
	if state.data.phase not in ["cycle_1", "cycle_2"]:
		return _reject("WRONG_PHASE", "Normal actions require an Action Cycle.")
	if current_actor() != player_id:
		return _reject("NOT_CURRENT_ACTOR", "Wait for this hero's scheduled action.")
	if command.type == "move":
		if not command.get("target") is String:
			return _reject("INVALID_TARGET", "Move requires a hex key target.")
		var reachable: Dictionary = _movement_targets(player_id)
		if not reachable.has(command.target):
			return _reject("TARGET_OUT_OF_RANGE", "Destination is blocked, occupied, or outside movement range.")
	if command.type == "capture":
		return _capture_validation(player_id)
	if command.type == "attack" and not Battle.targets(self, player_id).has(command.get("target_id", "")):
		return _reject("TARGET_OUT_OF_RANGE", "Attack requires an adjacent target that is not Recovering.")
	if command.type == "upgrade": return _upgrade_validation(player_id)
	if command.type == "special":
		var choices: Dictionary = _special_choices(player_id)
		if not choices.has(command.get("special_id", "")):
			return _reject("SPECIAL_NOT_AVAILABLE", "This class, location, or resource state does not permit the Special.")
		if command.special_id == "forced_march" and not choices.forced_march.targets.has(command.get("target", "")):
			return _reject("TARGET_OUT_OF_RANGE", "Choose a legal Forced March destination.")
	if command.type in ["choose_stance", "spend_fate", "decline_fate", "displace", "resolve_reaction"]:
		return _reject("NO_PENDING_WINDOW", "This decision requires an open combat or reaction window.")
	return {"is_valid": true}

func _capture_validation(player_id: String) -> Dictionary:
	var location: Dictionary = _hero_location(player_id)
	if location.is_empty() or location.kind not in ["minor_tower", "ancient_tower", "worldspire"]:
		return _reject("NOT_CAPTURABLE", "Stand on a Tower to Capture.")
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
	if not state.data.pending_reaction.is_empty():
		if state.data.pending_reaction.actor_id == player_id:
			return {"resolve_reaction": {"choices": state.data.pending_reaction.choices.duplicate(), "kind": state.data.pending_reaction.kind}}
		return {}
	if not state.data.pending_combat.is_empty(): return Battle.legal_window(self, player_id)
	if state.data.phase in ["world", "initiative", "bonus", "resolution"]:
		return {"advance": {"phase": state.data.phase}}
	if state.data.phase == "planning":
		if state.data.ready.has(player_id):
			return {}
		return {"submit_plan": Classes.planning_options(self, player_id), "ready": {}}
	if current_actor() != player_id:
		return {}
	var actions: Dictionary = {"pass": {}, "move": {"targets": _movement_targets(player_id)}}
	if _capture_validation(player_id).is_valid:
		var location: Dictionary = _hero_location(player_id)
		actions.capture = {"location_id": location.id, "automatic": str(location.owner_id).is_empty(), "defence": _tower_defence(location), "commitment": location.kind != "minor_tower", "completing": state.data.commitments.has(player_id)}
	var attack_targets: Dictionary = Battle.targets(self, player_id)
	if not attack_targets.is_empty(): actions.attack = {"targets": attack_targets}
	var specials: Dictionary = _special_choices(player_id)
	if not specials.is_empty(): actions.special = {"choices": specials}
	if _upgrade_validation(player_id).is_valid:
		var location: Dictionary = _hero_location(player_id)
		actions.upgrade = {"location_id": location.id, "cost": 3 if int(location.level) == 1 else 5, "next_level": int(location.level) + 1}
	return actions

func _advance() -> void:
	match str(state.data.phase):
		"world":
			for hero: Dictionary in state.data.heroes.values():
				if not hero.prepared_hex.is_empty() and int(hero.prepared_hex.expires_planning_round) <= int(state.data.round_number): hero.prepared_hex = {}
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
		var hero: Dictionary = state.data.heroes[player_id]
		var modifier: int = int(hero.flags.get("initiative_push", 0)) + int(hero.statuses.get("next_round_initiative", {}).get("amount", 0))
		hero.statuses.erase("next_round_initiative")
		scores[player_id] = speed + int(roll.result) + modifier
		_emit("InitiativeRolled", player_id, {"speed": speed, "die": roll.result, "modifier": modifier, "score": scores[player_id]})
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
	state.data.next_cycle_order = ordered.duplicate()
	state.data.cycle_2_modifiers = {}
	state.data.current_actor_index = 0
	_emit("InitiativeOrderChanged", "", {"order": ordered.duplicate(), "scores": scores.duplicate()})

func _draw(stream: String, minimum: int, maximum: int, actor: String, cause: String) -> Dictionary:
	var roll: Dictionary = _rng.draw(stream, minimum, maximum)
	var details: Dictionary = roll.duplicate(true)
	details.cause = cause
	_emit("DieRolled", actor, details)
	return roll

func _start_action(player_id: String, kind: String) -> void:
	if kind != "capture": _cancel_commitment(player_id, "different_action")
	_emit("ActionStarted", player_id, {"action": kind, "cycle": state.data.action_cycle, "actor_index": state.data.current_actor_index})

func _finish_action(player_id: String, kind: String) -> void:
	_emit("ActionCompleted", player_id, {"action": kind, "cycle": state.data.action_cycle})
	state.data.current_actor_index += 1
	if state.data.current_actor_index >= state.data.initiative_order.size():
		state.data.current_actor_index = 0
		if state.data.phase == "cycle_1":
			state.data.initiative_order = state.data.next_cycle_order.duplicate()
			_emit("InitiativeOrderChanged", "", {"order": state.data.initiative_order.duplicate(), "modifiers": state.data.cycle_2_modifiers.duplicate(), "cycle": 2})
		_set_phase("cycle_2" if state.data.phase == "cycle_1" else "bonus")
	else:
		_emit("ActorChanged", "", {"current_actor": current_actor(), "actor_index": state.data.current_actor_index})

func _move(player_id: String, target: String) -> void:
	var hero: Dictionary = state.data.heroes[player_id]
	var route: Dictionary = Movement.reachable(state.data.map, state.data.heroes, player_id)[target]
	var origin: String = hero.hex
	hero.hex = target
	_emit("HeroMoved", player_id, {"from": origin, "to": target, "path": route.path, "cost": route.cost, "road_only": route.road_only})
	for traversed: String in route.path:
		_discover(player_id, traversed)

func _hero_location(player_id: String) -> Dictionary:
	var hex_id: String = state.data.heroes[player_id].hex
	var location_id: String = state.data.map.hexes[hex_id].get("location_id", "")
	return state.data.map.locations.get(location_id, {})

func _is_occupied(hex_id: String) -> bool:
	for hero: Dictionary in state.data.heroes.values():
		if hero.hex == hex_id: return true
	for monster: Dictionary in state.data.monsters.values():
		if int(monster.hp) > 0 and monster.hex == hex_id: return true
	return false

func _sanctuary_allowed(player_id: String, hex_id: String) -> bool:
	return not state.data.map.sanctuaries.has(hex_id) or state.data.heroes[player_id].sanctuary == hex_id

func _movement_targets(player_id: String, forced: bool = false) -> Dictionary:
	var blockers: Dictionary = state.data.heroes.duplicate()
	for monster_id: String in state.data.monsters:
		if int(state.data.monsters[monster_id].hp) > 0: blockers[monster_id] = {"hex": state.data.monsters[monster_id].hex}
	for other_id: String in state.data.heroes:
		if other_id != player_id: blockers["sanctuary_" + other_id] = {"hex": state.data.heroes[other_id].sanctuary}
	return Movement.reachable(state.data.map, blockers, player_id, {"forced_march": forced})

func _special_choices(player_id: String) -> Dictionary:
	var choices: Dictionary = {}
	var hero: Dictionary = state.data.heroes[player_id]
	var location: Dictionary = _hero_location(player_id)
	if hero.hex == hero.sanctuary or (not location.is_empty() and location.kind == "settlement" and location.owner_id == player_id):
		choices.rest = {"healing": 3}
	if hero.class_id == "warlord" and int(hero.power) >= 1:
		choices.forced_march = {"power_cost": 1, "initiative_modifier": 2, "targets": _movement_targets(player_id, true)}
	return choices

func _upgrade_validation(player_id: String) -> Dictionary:
	var location: Dictionary = _hero_location(player_id)
	if location.is_empty() or location.kind not in ["minor_tower", "ancient_tower", "worldspire"] or location.owner_id != player_id:
		return _reject("UPGRADE_NOT_AVAILABLE", "Stand on your controlled Tower to Upgrade.")
	if int(location.level) >= 3: return _reject("MAX_LEVEL", "Tower level is capped at three.")
	var cost: int = 3 if int(location.level) == 1 else 5
	if int(state.data.heroes[player_id].gold) < cost:
		return _reject("INSUFFICIENT_GOLD", "Upgrade costs %d Gold." % cost)
	return {"is_valid": true}

func _upgrade(player_id: String) -> void:
	var location: Dictionary = _hero_location(player_id)
	var cost: int = 3 if int(location.level) == 1 else 5
	state.data.heroes[player_id].gold -= cost
	location.level += 1
	_emit("LocationUpgraded", player_id, {"location_id": location.id, "level": location.level, "gold_cost": cost, "benefit": "+1 Defence" if int(location.level) == 2 else "+1 income"})

func _cancel_commitment(player_id: String, cause: String) -> void:
	if not state.data.commitments.has(player_id): return
	var commitment: Dictionary = state.data.commitments[player_id]
	state.data.commitments.erase(player_id)
	_emit("LocationCaptureCanceled", player_id, {"location_id": commitment.location_id, "cause": cause})

func _modify_next_cycle(player_id: String, amount: int, cause: String) -> void:
	if state.data.phase == "cycle_1":
		state.data.cycle_2_modifiers[player_id] = int(state.data.cycle_2_modifiers.get(player_id, 0)) + amount
		var ordered: Array = state.data.initiative_order.duplicate()
		# Preserve the already randomized order for exact adjusted-score ties.
		ordered.sort_custom(func(a: String, b: String) -> bool:
			var left: int = int(state.data.initiative_scores[a]) + int(state.data.cycle_2_modifiers.get(a, 0))
			var right: int = int(state.data.initiative_scores[b]) + int(state.data.cycle_2_modifiers.get(b, 0))
			return left > right if left != right else state.data.initiative_order.find(a) < state.data.initiative_order.find(b))
		state.data.next_cycle_order = ordered
		_emit("NextCycleOrderChanged", player_id, {"cause": cause, "modifier": amount, "order": ordered.duplicate(), "modifiers": state.data.cycle_2_modifiers.duplicate()})
	else:
		var hero: Dictionary = state.data.heroes[player_id]
		var prior: int = int(hero.statuses.get("next_round_initiative", {}).get("amount", 0))
		hero.statuses.next_round_initiative = {"amount": prior + amount}
		_emit("NextRoundInitiativeChanged", player_id, {"cause": cause, "modifier": amount, "total": prior + amount})

func _gain_fate(player_id: String, amount: int, cause: String) -> void:
	var hero: Dictionary = state.data.heroes[player_id]
	var before: int = hero.fate
	hero.fate = mini(int(definitions.rules.fate_cap), before + amount)
	_emit("FateGained", player_id, {"cause": cause, "amount": int(hero.fate) - before, "before": before, "after": hero.fate})

func _tower_defence(location: Dictionary) -> int:
	var tower_trait: Dictionary = definitions.tower_traits.get(location.trait, {})
	return int(definitions.rules.tower_defence) + (1 if int(location.level) >= 2 else 0) + int(tower_trait.get("tower_defence", 0))

func _capture(player_id: String) -> void:
	var location: Dictionary = _hero_location(player_id)
	var previous_owner: String = location.owner_id
	if location.kind in ["ancient_tower", "worldspire"]:
		if not state.data.commitments.has(player_id):
			state.data.commitments[player_id] = {"kind": "ancient_capture", "location_id": location.id, "hex": location.hex, "round": state.data.round_number, "cycle": state.data.action_cycle}
			_emit("LocationCaptureBegun", player_id, state.data.commitments[player_id])
			return
		state.data.commitments.erase(player_id)
	if not previous_owner.is_empty() and location.kind == "minor_tower":
		var hero: Dictionary = state.data.heroes[player_id]
		var attack_bonus: int = 1 if hero.class_id == "warlord" else 0
		if hero.statuses.has("recovering"): attack_bonus -= 1
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

func _discover(player_id: String, from_hex: String = "") -> void:
	var hero: Dictionary = state.data.heroes[player_id]
	var origins: Array = [{"hex": hero.hex if from_hex.is_empty() else from_hex, "radius": int(definitions.rules.discovery_radius)}]
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
		if int(location.level) == 3: amount += 1
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
	for owner_id: String in state.data.traps.keys():
		_emit("TrapExpired", owner_id, {"hex": state.data.traps[owner_id].hex})
	state.data.traps = {}
	for player_id: String in Enums.PLAYER_IDS:
		var hero: Dictionary = state.data.heroes[player_id]
		var before: int = hero.fate
		hero.fate = mini(int(definitions.rules.fate_cap), before + int(definitions.rules.round_fate))
		_emit("FateGained", player_id, {"cause": "resolution", "amount": int(hero.fate) - before, "before": before, "after": hero.fate})
	_emit("ResolutionCompleted", "", {"round": state.data.round_number})
	state.data.plans = {}
	state.data.ready = []
	state.data.round_number += 1
	for player_id: String in Enums.PLAYER_IDS:
		if state.data.heroes[player_id].statuses.has("recovering"):
			state.data.heroes[player_id].statuses.erase("recovering")
			_emit("StatusExpired", player_id, {"status_id": "recovering"})
	state.data.current_actor_index = 0
	_set_phase("world")
	_emit("RoundStarted", "", {"round": state.data.round_number, "world_event": "deferred_milestone_3"})

func _emit(event_type: String, actor_id: String, details: Dictionary, visibility: String = "public") -> void:
	state.data.event_sequence += 1
	var event: Dictionary = Event.new(int(state.data.event_sequence), event_type, int(state.data.round_number), state.data.phase, actor_id, details, visibility).to_dict()
	state.data.events.append(event)
	_emitted.append(event)
