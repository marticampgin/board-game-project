extends RefCounted
## Portable authoritative state. Validation rejects unknown schemas and definitions.
const Catalog = preload("res://scripts/domain/definitions/definition_catalog.gd")
const Enums = preload("res://scripts/domain/game_enums.gd")
var data: Dictionary = {}

func _init(values: Dictionary = {}) -> void:
	data = values.duplicate(true)

func to_dict() -> Dictionary:
	return data.duplicate(true)

func to_json() -> String:
	return canonical_json(data)

func checksum() -> String:
	return to_json().sha256_text()

static func from_dict(values: Dictionary) -> RefCounted:
	if not validation_errors(values).is_empty():
		return null
	var script: GDScript = load("res://scripts/domain/state/game_state.gd")
	return script.new(normalize(values))

static func is_serializable(value: Variant) -> bool:
	if value == null or value is bool or value is int or value is String or value is StringName:
		return true
	if value is float:
		return is_finite(value)
	if value is Array:
		for item: Variant in value:
			if not is_serializable(item):
				return false
		return true
	if value is Dictionary:
		for key: Variant in value:
			if not (key is String or key is StringName) or not is_serializable(value[key]):
				return false
		return true
	return false

static func normalize(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort()
		for key: Variant in keys:
			result[str(key)] = normalize(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(normalize(item))
		return result
	if value is float and is_finite(value) and value == floor(value):
		return int(value)
	if value is StringName:
		return str(value)
	return value

static func canonical_json(value: Variant) -> String:
	return JSON.stringify(normalize(value), "", true, true)

static func validation_errors(values: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	if not is_serializable(values):
		return ["NON_SERIALIZABLE_STATE"]
	if values.get("schema_version", -1) != 1:
		return ["UNKNOWN_SCHEMA_VERSION"]
	var catalog: RefCounted = Catalog.new()
	if not catalog.errors.is_empty():
		return ["INVALID_DEFINITIONS"]
	if values.get("content_version", "") != catalog.rules.content_version:
		errors.append("UNKNOWN_CONTENT_VERSION")
	for field: String in ["master_seed", "round_number", "action_cycle", "current_actor_index", "command_sequence", "event_sequence", "state_version"]:
		if not values.has(field) or not (values[field] is int or values[field] is float) or values[field] != floor(float(values[field])):
			errors.append("INVALID_NUMBER:" + field)
	for field: String in ["heroes", "map", "plans", "rng", "initiative_scores"]:
		if not values.get(field) is Dictionary:
			errors.append("INVALID_DICTIONARY:" + field)
	for field: String in ["initiative_order", "ready", "events", "commands"]:
		if not values.get(field) is Array:
			errors.append("INVALID_ARRAY:" + field)
	if not Enums.PHASE_IDS.has(values.get("phase", "")):
		errors.append("INVALID_PHASE")
	if not errors.is_empty():
		return errors
	var map: Dictionary = values.map
	if not map.get("hexes") is Dictionary or not map.get("locations") is Dictionary or not map.get("sanctuaries") is Array or not map.get("roads") is Array or not map.get("report") is Dictionary:
		return ["INVALID_MAP"]
	if map.hexes.size() != 61 or map.locations.size() != 16 or map.sanctuaries.size() != 4:
		errors.append("INVALID_MAP_SIZE")
	for hex_id: String in map.hexes:
		var tile: Variant = map.hexes[hex_id]
		if not tile is Dictionary:
			errors.append("INVALID_HEX:" + hex_id)
			continue
		if tile.get("id", "") != hex_id or not tile.get("region") is String or not tile.get("location_id") is String:
			errors.append("INVALID_HEX_FIELDS:" + hex_id)
		if tile.get("terrain", "") not in ["plains", "forest", "swamp", "mountain", "water"]:
			errors.append("UNKNOWN_TERRAIN:" + hex_id)
		if not _integer(tile.get("q")) or not _integer(tile.get("r")):
			errors.append("INVALID_HEX_COORDINATES:" + hex_id)
		elif "%d,%d" % [int(tile.q), int(tile.r)] != hex_id:
			errors.append("HEX_COORDINATE_MISMATCH:" + hex_id)
		if not str(tile.get("location_id", "")).is_empty() and not map.locations.has(tile.location_id):
			errors.append("UNKNOWN_HEX_LOCATION:" + hex_id)
	var sanctuary_seen: Dictionary = {}
	for sanctuary: Variant in map.sanctuaries:
		if not sanctuary is String or not map.hexes.has(sanctuary) or sanctuary_seen.has(sanctuary):
			errors.append("INVALID_SANCTUARY")
		sanctuary_seen[sanctuary] = true
	for edge: Variant in map.roads:
		if not edge is Array or edge.size() != 2:
			errors.append("INVALID_ROAD")
		elif not edge[0] is String or not edge[1] is String or not map.hexes.has(edge[0]) or not map.hexes.has(edge[1]):
			errors.append("UNKNOWN_ROAD_ENDPOINT")
	if not errors.is_empty():
		return errors
	if values.heroes.size() != 4:
		errors.append("INVALID_HERO_COUNT")
	var occupied: Dictionary = {}
	for player_id: String in Enums.PLAYER_IDS:
		if not values.heroes.get(player_id) is Dictionary:
			errors.append("MISSING_HERO:" + player_id)
			continue
		var hero: Dictionary = values.heroes[player_id]
		if hero.get("id", "") != player_id or hero.get("player_id", "") != player_id:
			errors.append("INVALID_HERO_ID:" + player_id)
		if not catalog.classes.has(hero.get("class_id", "")):
			errors.append("UNKNOWN_CLASS:" + player_id)
		if not map.hexes.has(hero.get("hex", "")) or not map.sanctuaries.has(hero.get("sanctuary", "")):
			errors.append("INVALID_HERO_POSITION:" + player_id)
		elif map.hexes[hero.hex].terrain in ["mountain", "water"]:
			errors.append("IMPASSABLE_HERO_POSITION:" + player_id)
		if occupied.has(hero.get("hex", "")):
			errors.append("DUPLICATE_HERO_POSITION")
		occupied[hero.get("hex", "")] = true
		for field: String in ["hp", "max_hp", "attack", "defence", "speed", "move", "gold", "power", "fate"]:
			if not (hero.get(field) is int or hero.get(field) is float) or float(hero[field]) < 0 or float(hero[field]) != floor(float(hero[field])):
				errors.append("INVALID_HERO_STAT:%s:%s" % [player_id, field])
		for field: String in ["relics", "controlled_locations"]:
			if not hero.get(field) is Array:
				errors.append("INVALID_HERO_ARRAY:" + field)
		for field: String in ["statuses", "flags"]:
			if not hero.get(field) is Dictionary:
				errors.append("INVALID_HERO_DICTIONARY:" + field)
		if hero.get("hp", 0) > hero.get("max_hp", 0) or hero.get("power", 0) > catalog.rules.power_cap or hero.get("fate", 0) > catalog.rules.fate_cap:
			errors.append("RESOURCE_CAP_EXCEEDED:" + player_id)
	if not errors.is_empty():
		return errors
	for location_id: String in map.locations:
		var location: Variant = map.locations[location_id]
		if not location is Dictionary:
			errors.append("INVALID_LOCATION:" + location_id)
			continue
		if not map.hexes.has(location.get("hex", "")):
			errors.append("INVALID_LOCATION_HEX:" + location_id)
		elif map.hexes[location.hex].location_id != location_id:
			errors.append("INVALID_LOCATION_BACKLINK:" + location_id)
		if location.get("id", "") != location_id or not location.get("name") is String:
			errors.append("INVALID_LOCATION_ID:" + location_id)
		if location.get("kind", "") not in ["minor_tower", "ancient_tower", "worldspire", "settlement", "ruin", "monster_camp"]:
			errors.append("UNKNOWN_LOCATION_KIND:" + location_id)
		if not _integer(location.get("level")) or int(location.level) < 1 or int(location.level) > 3:
			errors.append("INVALID_LOCATION_LEVEL:" + location_id)
		if not location.get("owner_id") is String or not location.get("trait") is String or not location.get("discovered_by") is Array:
			errors.append("INVALID_LOCATION_FIELDS:" + location_id)
		else:
			var discovered_seen: Dictionary = {}
			for player_id: Variant in location.discovered_by:
				if not values.heroes.has(player_id) or discovered_seen.has(player_id):
					errors.append("INVALID_DISCOVERY:" + location_id)
				discovered_seen[player_id] = true
		if not str(location.get("trait", "")).is_empty() and not catalog.tower_traits.has(location.trait):
			errors.append("UNKNOWN_TOWER_TRAIT:" + location_id)
		if not str(location.get("owner_id", "")).is_empty() and not values.heroes.has(location.owner_id):
			errors.append("UNKNOWN_LOCATION_OWNER:" + location_id)
	if not errors.is_empty():
		return errors
	for player_id: String in values.heroes:
		var controlled_seen: Dictionary = {}
		for location_id: Variant in values.heroes[player_id].controlled_locations:
			if not map.locations.has(location_id) or controlled_seen.has(location_id):
				errors.append("INVALID_CONTROLLED_LOCATION:" + player_id)
			elif map.locations[location_id].owner_id != player_id:
				errors.append("LOCATION_OWNERSHIP_MISMATCH:" + player_id)
			controlled_seen[location_id] = true
	for location_id: String in map.locations:
		var owner_id: String = map.locations[location_id].owner_id
		if not owner_id.is_empty() and not values.heroes[owner_id].controlled_locations.has(location_id):
			errors.append("LOCATION_CONTROLLER_MISMATCH:" + location_id)
	if values.command_sequence != values.commands.size() or values.event_sequence != values.events.size() or values.state_version != values.command_sequence:
		errors.append("INVALID_SEQUENCE")
	if values.rng.get("algorithm", "") != "park_miller_48271_v1" or not values.rng.get("streams") is Dictionary or values.rng.get("master_seed") != values.master_seed:
		errors.append("INVALID_RNG")
	else:
		for stream: String in ["map", "initiative", "combat"]:
			if not values.rng.streams.has(stream):
				errors.append("MISSING_RNG_STREAM:" + stream)
		for stream: String in values.rng.streams:
			var item: Variant = values.rng.streams[stream]
			if not item is Dictionary or not (item.get("state") is int or item.get("state") is float) or not (item.get("draw_index") is int or item.get("draw_index") is float):
				errors.append("INVALID_RNG_STREAM:" + stream)
			elif not _integer(item.state) or not _integer(item.draw_index) or int(item.state) <= 0 or int(item.state) >= 2147483647 or int(item.draw_index) < 0:
				errors.append("INVALID_RNG_RANGE:" + stream)
	if int(values.round_number) < 1:
		errors.append("INVALID_ROUND")
	if values.phase in ["cycle_1", "cycle_2"]:
		if values.initiative_order.size() != 4 or int(values.current_actor_index) < 0 or int(values.current_actor_index) >= 4:
			errors.append("INVALID_ACTOR")
	var order_seen: Dictionary = {}
	for player_id: Variant in values.initiative_order:
		if not values.heroes.has(player_id) or order_seen.has(player_id):
			errors.append("INVALID_INITIATIVE_ORDER")
		order_seen[player_id] = true
	var ready_seen: Dictionary = {}
	for player_id: Variant in values.ready:
		if not values.heroes.has(player_id) or ready_seen.has(player_id):
			errors.append("INVALID_READY_LIST")
		ready_seen[player_id] = true
	for player_id: Variant in values.plans:
		if not values.heroes.has(player_id) or not values.plans[player_id] is Dictionary:
			errors.append("INVALID_PLAN")
	_validate_phase_consistency(values, errors)
	_validate_conflict_state(values, catalog, errors)
	for index: int in values.events.size():
		var event: Variant = values.events[index]
		if not event is Dictionary or event.get("sequence", -1) != index + 1 or not event.get("type") is String or not event.get("data") is Dictionary:
			errors.append("INVALID_EVENT_RECORD")
	for command: Variant in values.commands:
		if not command is Dictionary or not command.get("type") is String or not Enums.COMMAND_IDS.has(command.type):
			errors.append("INVALID_COMMAND_RECORD")
	return errors

static func _validate_phase_consistency(values: Dictionary, errors: Array[String]) -> void:
	var phase: String = values.phase
	var expected_cycle: int = {"cycle_1": 1, "cycle_2": 2, "bonus": 3}.get(phase, 0)
	if int(values.action_cycle) != expected_cycle:
		errors.append("PHASE_ACTION_CYCLE_MISMATCH")
	if phase not in ["cycle_1", "cycle_2"] and int(values.current_actor_index) != 0:
		errors.append("PHASE_ACTOR_INDEX_MISMATCH")
	var initiative_resolved: bool = phase in ["initiative", "cycle_1", "cycle_2", "bonus", "resolution"]
	# A later World/Planning phase retains last round's order for the HUD.
	var needs_order: bool = initiative_resolved or int(values.round_number) > 1
	if values.initiative_order.size() != (4 if needs_order else 0):
		errors.append("PHASE_INITIATIVE_ORDER_MISMATCH")
	if values.initiative_scores.size() != values.initiative_order.size():
		errors.append("INITIATIVE_SCORE_COUNT_MISMATCH")
	for player_id: Variant in values.initiative_order:
		if not values.initiative_scores.has(player_id) or not _integer(values.initiative_scores[player_id]):
			errors.append("INVALID_INITIATIVE_SCORE")
	if initiative_resolved:
		if values.ready.size() != 4 or values.plans.size() != 4:
			errors.append("PHASE_PLANNING_INCOMPLETE")
	elif phase == "world":
		if not values.ready.is_empty() or not values.plans.is_empty():
			errors.append("WORLD_PLANNING_NOT_RESET")
	elif phase == "planning" and values.ready.size() >= 4:
		# The fourth Ready command transitions atomically to Initiative.
		errors.append("PLANNING_ALREADY_COMPLETE")
	for player_id: Variant in values.ready:
		if not values.plans.has(player_id):
			errors.append("READY_WITHOUT_PLAN")

static func _integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value))

static func _validate_conflict_state(values: Dictionary, catalog: RefCounted, errors: Array[String]) -> void:
	for field: String in ["monsters", "pending_combat", "pending_reaction", "pending_move", "traps", "commitments", "ground_loot", "cycle_2_modifiers"]:
		if not values.get(field) is Dictionary:
			errors.append("INVALID_CONFLICT_DICTIONARY:" + field)
	if not values.get("next_cycle_order") is Array:
		errors.append("INVALID_NEXT_CYCLE_ORDER")
	if not errors.is_empty(): return
	if values.monsters.size() != 4: errors.append("INVALID_MONSTER_COUNT")
	for monster_id: String in values.monsters:
		var monster: Variant = values.monsters[monster_id]
		if not monster is Dictionary:
			errors.append("INVALID_MONSTER:" + monster_id)
			continue
		if monster.get("id", "") != monster_id or not catalog.monsters.has(monster.get("definition_id", "")):
			errors.append("UNKNOWN_MONSTER_DEFINITION:" + monster_id)
		if not values.map.hexes.has(monster.get("hex", "")) or not values.map.locations.has(monster.get("camp_id", "")):
			errors.append("INVALID_MONSTER_LOCATION:" + monster_id)
		elif values.map.locations[monster.camp_id].hex != monster.hex:
			errors.append("MONSTER_CAMP_MISMATCH:" + monster_id)
		for field: String in ["hp", "max_hp", "attack", "defence"]:
			if not _integer(monster.get(field)) or int(monster.get(field, -1)) < 0:
				errors.append("INVALID_MONSTER_STAT:" + monster_id)
	for player_id: String in values.heroes:
		var prepared: Variant = values.heroes[player_id].get("prepared_hex")
		if not prepared is Dictionary:
			errors.append("INVALID_PREPARED_HEX")
		elif not prepared.is_empty() and (not values.heroes.has(prepared.get("target_id", "")) or prepared.get("target_id", "") == player_id or not _integer(prepared.get("expires_planning_round"))):
			errors.append("INVALID_PREPARED_HEX_TARGET")
	for player_id: String in values.plans:
		var plan: Dictionary = values.plans[player_id]
		for key: String in plan:
			if key not in ["no_change", "initiative_push", "snare", "prepared_hex"]: errors.append("UNKNOWN_PLANNING_CHOICE")
			if key in ["no_change", "initiative_push"] and not plan[key] is bool: errors.append("INVALID_PLANNING_FLAG")
		if plan.has("snare") and (values.heroes[player_id].class_id != "ranger" or not values.map.hexes.has(plan.snare)): errors.append("INVALID_SNARE_PLAN")
		if plan.has("prepared_hex") and (values.heroes[player_id].class_id != "cultist" or not values.heroes.has(plan.prepared_hex) or plan.prepared_hex == player_id): errors.append("INVALID_PREPARED_HEX_PLAN")
		if values.phase == "planning":
			if plan.get("initiative_push", false) and int(values.heroes[player_id].fate) < 2: errors.append("UNAFFORDABLE_PLAN")
			if (plan.has("snare") or plan.has("prepared_hex")) and int(values.heroes[player_id].power) < 1: errors.append("UNAFFORDABLE_PLAN")
	for owner_id: String in values.traps:
		var trap: Variant = values.traps[owner_id]
		if not trap is Dictionary or not values.heroes.has(owner_id) or trap.get("owner_id", "") != owner_id or trap.get("kind", "") != "snare" or not values.map.hexes.has(trap.get("hex", "")) or not _integer(trap.get("expires_round")):
			errors.append("INVALID_TRAP")
	for player_id: String in values.commitments:
		var commitment: Variant = values.commitments[player_id]
		if not commitment is Dictionary or not values.heroes.has(player_id) or not values.map.locations.has(commitment.get("location_id", "")):
			errors.append("INVALID_COMMITMENT")
			continue
		var location: Dictionary = values.map.locations[commitment.location_id]
		if commitment.get("kind", "") != "ancient_capture" or location.kind not in ["ancient_tower", "worldspire"] or commitment.get("hex", "") != location.hex or values.heroes[player_id].hex != location.hex or location.owner_id == player_id:
			errors.append("COMMITMENT_REQUIREMENTS_LOST")
	if not values.next_cycle_order.is_empty():
		var next_seen: Dictionary = {}
		for player_id: Variant in values.next_cycle_order:
			if not values.heroes.has(player_id) or next_seen.has(player_id): errors.append("INVALID_NEXT_CYCLE_ORDER")
			next_seen[player_id] = true
		if next_seen.size() != 4: errors.append("INVALID_NEXT_CYCLE_ORDER")
	for player_id: String in values.cycle_2_modifiers:
		if not values.heroes.has(player_id) or not _integer(values.cycle_2_modifiers[player_id]): errors.append("INVALID_CYCLE_MODIFIER")
	var battle: Dictionary = values.pending_combat
	var reaction: Dictionary = values.pending_reaction
	var movement: Dictionary = values.pending_move
	if not battle.is_empty() or not reaction.is_empty() or not movement.is_empty():
		if values.phase not in ["cycle_1", "cycle_2"] or values.initiative_order.size() != 4:
			errors.append("WINDOW_OUTSIDE_ACTION_CYCLE")
			return
		if int(values.current_actor_index) < 0 or int(values.current_actor_index) >= 4: return
	if not battle.is_empty():
		if not values.heroes.has(battle.get("attacker_id", "")) or battle.get("attacker_id", "") != values.initiative_order[values.current_actor_index]: errors.append("INVALID_COMBAT_ATTACKER")
		if battle.get("defender_kind", "") not in ["hero", "monster"]: errors.append("INVALID_COMBAT_KIND")
		var opponents: Dictionary = values.heroes if battle.get("defender_kind", "") == "hero" else values.monsters
		if not opponents.has(battle.get("defender_id", "")) or battle.get("attacker_id", "") == battle.get("defender_id", ""): errors.append("INVALID_COMBAT_DEFENDER")
		if battle.get("stage", "") not in ["stances", "fate_attacker", "fate_defender", "displacement"]: errors.append("INVALID_COMBAT_STAGE")
		for field: String in ["stances", "dice", "calculation", "rerolled", "modifiers"]:
			if not battle.get(field) is Dictionary: errors.append("INVALID_COMBAT_FIELD:" + field)
		if not errors.is_empty(): return
		for participant: String in battle.stances:
			if participant not in [battle.attacker_id, battle.defender_id] or battle.stances[participant] not in ["assault", "guard", "counter", "trick", "none"]: errors.append("INVALID_STORED_STANCE")
		if battle.stage != "stances":
			if battle.stances.size() != 2 or battle.dice.size() != 2: errors.append("INCOMPLETE_REVEALED_COMBAT")
			for side: String in ["attacker", "defender"]:
				if not _integer(battle.dice.get(side)) or int(battle.dice.get(side, 0)) < 1 or int(battle.dice.get(side, 0)) > 6: errors.append("INVALID_COMBAT_DIE")
		if battle.stage in ["fate_defender", "displacement"] and battle.defender_kind != "hero": errors.append("MONSTER_DECISION_WINDOW")
	if not reaction.is_empty():
		if not values.heroes.has(reaction.get("actor_id", "")) or reaction.get("choices", []) != ["accept", "decline"]: errors.append("INVALID_REACTION_OWNER")
		if reaction.get("kind", "") == "challenge":
			if movement.is_empty() or not battle.is_empty(): errors.append("INVALID_CHALLENGE_CONTEXT")
		elif reaction.get("kind", "") in ["bribe_offer", "bribe_response"]:
			if battle.is_empty() or not movement.is_empty(): errors.append("INVALID_BRIBE_CONTEXT")
		else: errors.append("INVALID_REACTION_KIND")
	if not movement.is_empty():
		if not values.heroes.has(movement.get("actor_id", "")) or movement.get("actor_id", "") != values.initiative_order[values.current_actor_index]: errors.append("INVALID_MOVEMENT_ACTOR")
		if reaction.get("kind", "") != "challenge": errors.append("MOVEMENT_WITHOUT_REACTION")
		if not movement.get("path") is Array or not movement.get("route") is Dictionary or not _integer(movement.get("index")) or not movement.get("declined_challenges") is Array: errors.append("INVALID_PENDING_MOVEMENT")
