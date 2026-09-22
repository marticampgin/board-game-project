extends RefCounted
## Portable authoritative state. Validation rejects unknown schemas and definitions.
const Catalog = preload("res://scripts/domain/definitions/definition_catalog.gd")
const Enums = preload("res://scripts/domain/game_enums.gd")
const Combat = preload("res://scripts/domain/resolvers/combat.gd")
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
		if not hero.get("name") is String: errors.append("INVALID_HERO_NAME")
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
		for field: String in ["relics", "controlled_locations", "upgrades"]:
			if not hero.get(field) is Array:
				errors.append("INVALID_HERO_ARRAY:" + field)
		for field: String in ["statuses", "flags"]:
			if not hero.get(field) is Dictionary:
				errors.append("INVALID_HERO_DICTIONARY:" + field)
		if hero.get("hp", 0) > hero.get("max_hp", 0) or hero.get("power", 0) > catalog.rules.power_cap or hero.get("fate", 0) > catalog.rules.fate_cap:
			errors.append("RESOURCE_CAP_EXCEEDED:" + player_id)
		if hero.get("upgrades") is Array:
			var equipped: Dictionary = {}
			if hero.upgrades.size() > 3: errors.append("UPGRADE_SLOT_LIMIT")
			for upgrade_id: Variant in hero.upgrades:
				if not upgrade_id is String or not catalog.upgrades.has(upgrade_id) or equipped.has(upgrade_id): errors.append("UNKNOWN_OR_DUPLICATE_UPGRADE")
				equipped[upgrade_id] = true
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
	_validate_full_game(values, catalog, errors)
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
	var initiative_resolved: bool = phase in ["initiative", "cycle_1", "cycle_2", "bonus", "resolution", "victory"]
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

static func _validate_full_game(values: Dictionary, catalog: RefCounted, errors: Array[String]) -> void:
	for field: String in ["victory_claims", "victory", "pending_exploration"]:
		if not values.get(field) is Dictionary: errors.append("INVALID_FULL_GAME_FIELD:" + field)
	if not values.get("world_effects") is Array or not values.get("market_hex") is String: errors.append("INVALID_WORLD_STATE")
	if not errors.is_empty(): return
	if not values.market_hex.is_empty() and not values.map.hexes.has(values.market_hex): errors.append("INVALID_MARKET_HEX")
	if not _integer(values.get("last_world_event_round")) or int(values.get("last_world_event_round", -1)) < 0 or int(values.get("last_world_event_round", -1)) > int(values.round_number): errors.append("INVALID_WORLD_EVENT_ROUND")
	for field: String in ["bridge_edges", "blocked_edges"]:
		if not values.map.get(field) is Array: errors.append("INVALID_WORLD_MAP_FIELD:" + field)
		else:
			for edge: Variant in values.map[field]:
				if not _valid_edge(edge, values.map.hexes): errors.append("INVALID_WORLD_MAP_EDGE:" + field)
	for location: Dictionary in values.map.locations.values():
		if not _integer(location.get("world_income_bonus")) or not _integer(location.get("world_defence_modifier")): errors.append("INVALID_WORLD_LOCATION_MODIFIER")
		if location.kind == "ruin" and (not location.get("exhausted") is bool or not location.get("relic_available") is bool): errors.append("INVALID_RUIN_STATE")
	for claim_id: String in values.victory_claims:
		var claim: Variant = values.victory_claims[claim_id]
		if not claim is Dictionary:
			errors.append("INVALID_VICTORY_CLAIM")
			continue
		if not values.heroes.has(claim.get("player_id", "")) or claim.get("route", "") not in ["conquest", "dominion"]:
			errors.append("INVALID_CLAIM_ROUTE_OR_PLAYER")
		if not _integer(claim.get("created_round")) or not _integer(claim.get("required_round")):
			errors.append("INVALID_CLAIM_ROUND")
		elif int(claim.created_round) < 1 or int(claim.created_round) > int(values.round_number) or int(claim.required_round) != int(claim.created_round) + 1:
			errors.append("INVALID_CLAIM_RESPONSE_WINDOW")
	if values.phase == "victory":
		if values.victory.is_empty() or not values.victory.get("winners") is Array or values.victory.get("route", "") not in ["conquest", "dominion", "ascension", "shared"]:
			errors.append("INVALID_VICTORY_RESULT")
		elif values.victory.winners.is_empty(): errors.append("MISSING_WINNER")
		else:
			var winner_seen: Dictionary = {}
			for player_id: Variant in values.victory.winners:
				if not values.heroes.has(player_id) or winner_seen.has(player_id): errors.append("INVALID_WINNER")
				winner_seen[player_id] = true
	elif not values.victory.is_empty(): errors.append("VICTORY_PHASE_MISMATCH")
	var pending: Dictionary = values.pending_exploration
	if not pending.is_empty():
		if values.phase not in ["cycle_1", "cycle_2"] or not values.pending_combat.is_empty() or not values.pending_reaction.is_empty(): errors.append("INVALID_EXPLORATION_PHASE")
		if not values.heroes.has(pending.get("player_id", "")): errors.append("INVALID_EXPLORATION_PLAYER")
		elif int(values.current_actor_index) >= 0 and int(values.current_actor_index) < values.initiative_order.size():
			if pending.player_id != values.initiative_order[values.current_actor_index]: errors.append("INVALID_EXPLORATION_ACTOR")
		if not values.map.locations.has(pending.get("location_id", "")): errors.append("INVALID_EXPLORATION_LOCATION")
		if pending.get("kind", "") != "ruin" or not pending.get("choices") is Dictionary or not pending.get("dark_bargain") is bool or pending.get("action", "") not in ["explore", "special"]: errors.append("INVALID_EXPLORATION_FIELDS")
		if not errors.is_empty(): return
		var ruin: Dictionary = values.map.locations[pending.location_id]
		var explorer: Dictionary = values.heroes[pending.player_id]
		if ruin.kind != "ruin" or ruin.exhausted or pending.get("hex", "") != ruin.hex or explorer.hex != ruin.hex: errors.append("EXPLORATION_REQUIREMENTS_LOST")
		if pending.choices.size() != 2: errors.append("INVALID_REWARD_CHOICE_COUNT")
		for reward_id: String in pending.choices:
			if not catalog.rewards.ruin_rewards.has(reward_id) or canonical_json(pending.choices[reward_id]) != canonical_json(catalog.rewards.ruin_rewards[reward_id]): errors.append("INVALID_PENDING_REWARD")
		if pending.dark_bargain and (explorer.class_id != "cultist" or int(explorer.hp) <= 2 or pending.action != "special"): errors.append("INVALID_PENDING_DARK_BARGAIN")
		if not pending.dark_bargain and pending.action != "explore": errors.append("INVALID_PENDING_EXPLORE_ACTION")
	for effect: Variant in values.world_effects:
		if not effect is Dictionary:
			errors.append("INVALID_WORLD_EFFECT")
			continue
		if not catalog.world_events.has(effect.get("event_id", "")) or not _integer(effect.get("started_round")) or not _integer(effect.get("expires_round")) or effect.get("expiry", "") not in ["world", "resolution"]:
			errors.append("INVALID_WORLD_EFFECT_FIELDS")
			continue
		if int(effect.started_round) < 1 or int(effect.started_round) > int(values.round_number) or int(effect.expires_round) < int(effect.started_round): errors.append("INVALID_WORLD_EFFECT_DURATION")
		match str(effect.event_id):
			"collapsed_bridge":
				if not _valid_edge(effect.get("edge"), values.map.hexes): errors.append("INVALID_COLLAPSED_BRIDGE")
			"unstable_leyline":
				if not values.map.locations.has(effect.get("location_id", "")): errors.append("INVALID_LEYLINE_LOCATION")
			"cursed_ground":
				if not effect.get("hexes") is Array: errors.append("INVALID_CURSED_REGION")
				else:
					for hex_id: Variant in effect.hexes:
						if not values.map.hexes.has(hex_id): errors.append("INVALID_CURSED_HEX")
			"wandering_market":
				if not values.map.hexes.has(effect.get("hex", "")): errors.append("INVALID_WANDERING_MARKET")
			_: errors.append("INVALID_TEMPORARY_WORLD_EFFECT")

static func _valid_edge(value: Variant, hexes: Dictionary) -> bool:
	return value is Array and value.size() == 2 and value[0] is String and value[1] is String and value[0] != value[1] and hexes.has(value[0]) and hexes.has(value[1])

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
		if not monster.get("name") is String: errors.append("INVALID_MONSTER_NAME")
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
			if key not in ["no_change", "initiative_push", "snare", "prepared_hex", "purchases"]: errors.append("UNKNOWN_PLANNING_CHOICE")
			if key in ["no_change", "initiative_push"] and not plan[key] is bool: errors.append("INVALID_PLANNING_FLAG")
		if plan.has("snare") and (values.heroes[player_id].class_id != "ranger" or not values.map.hexes.has(plan.snare)): errors.append("INVALID_SNARE_PLAN")
		if plan.has("prepared_hex") and (values.heroes[player_id].class_id != "cultist" or not values.heroes.has(plan.prepared_hex) or plan.prepared_hex == player_id): errors.append("INVALID_PREPARED_HEX_PLAN")
		if plan.has("purchases"):
			if not plan.purchases is Array: errors.append("INVALID_PURCHASE_PLAN")
			else:
				var purchase_ids: Dictionary = {}
				var cost: int = 0
				for upgrade_id: Variant in plan.purchases:
					if not upgrade_id is String or not catalog.upgrades.has(upgrade_id) or purchase_ids.has(upgrade_id): errors.append("INVALID_PURCHASE_DEFINITION")
					else: cost += int(catalog.upgrades[upgrade_id].cost)
					purchase_ids[upgrade_id] = true
				if values.phase == "planning" and (cost > int(values.heroes[player_id].gold) or plan.purchases.size() + values.heroes[player_id].upgrades.size() > 3): errors.append("UNAFFORDABLE_PURCHASE_PLAN")
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
		if commitment.get("kind", "") not in ["ancient_capture", "ritual"] or location.kind not in ["ancient_tower", "worldspire"] or commitment.get("hex", "") != location.hex or values.heroes[player_id].hex != location.hex:
			errors.append("COMMITMENT_REQUIREMENTS_LOST")
		elif commitment.kind == "ancient_capture" and location.owner_id == player_id: errors.append("CAPTURE_ALREADY_CONTROLLED")
		elif commitment.kind == "ritual" and (location.kind != "worldspire" or values.heroes[player_id].relics.size() < int(catalog.victory.ascension.relics)): errors.append("RITUAL_REQUIREMENTS_LOST")
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
			if values.heroes.has(participant) and battle.stances[participant] == "none": errors.append("HERO_WITHOUT_STANCE")
			if battle.stage == "stances" and values.heroes.has(participant) and battle.stances[participant] == "trick" and int(values.heroes[participant].fate) < 1: errors.append("UNAFFORDABLE_STORED_STANCE")
		if battle.get("contested_hex", "") != opponents[battle.defender_id].hex: errors.append("COMBAT_LOCATION_MISMATCH")
		for field: String in ["attacker_modifier", "defender_modifier", "attacker_die_modifier", "defender_die_modifier"]:
			if not _integer(battle.modifiers.get(field)): errors.append("INVALID_STORED_MODIFIER")
		for field: String in ["attacker_modifiers", "defender_modifiers"]:
			if not battle.modifiers.get(field) is Dictionary: errors.append("INVALID_STORED_MODIFIER_PARTS")
		if battle.stage != "stances":
			if battle.stances.size() != 2 or battle.dice.size() != 2: errors.append("INCOMPLETE_REVEALED_COMBAT")
			for side: String in ["attacker", "defender"]:
				if not _integer(battle.dice.get(side)) or int(battle.dice.get(side, 0)) < 1 or int(battle.dice.get(side, 0)) > 6: errors.append("INVALID_COMBAT_DIE")
			if errors.is_empty():
				var calculated: Dictionary = Combat.evaluate(values.heroes[battle.attacker_id], opponents[battle.defender_id], battle.stances[battle.attacker_id], battle.stances[battle.defender_id], int(battle.dice.attacker), int(battle.dice.defender), battle.modifiers)
				if not calculated.is_valid or canonical_json(calculated) != canonical_json(battle.calculation): errors.append("COMBAT_CALCULATION_MISMATCH")
		if battle.stage in ["fate_defender", "displacement"] and battle.defender_kind != "hero": errors.append("MONSTER_DECISION_WINDOW")
	if not reaction.is_empty():
		if not values.heroes.has(reaction.get("actor_id", "")) or reaction.get("choices", []) != ["accept", "decline"]: errors.append("INVALID_REACTION_OWNER")
		if reaction.get("kind", "") == "challenge":
			if movement.is_empty() or not battle.is_empty(): errors.append("INVALID_CHALLENGE_CONTEXT")
		elif reaction.get("kind", "") in ["bribe_offer", "bribe_response"]:
			if battle.is_empty() or not movement.is_empty(): errors.append("INVALID_BRIBE_CONTEXT")
			elif reaction.actor_id != (battle.defender_id if reaction.kind == "bribe_offer" else battle.attacker_id): errors.append("INVALID_BRIBE_DECISION_OWNER")
		else: errors.append("INVALID_REACTION_KIND")
	if not movement.is_empty():
		if not values.heroes.has(movement.get("actor_id", "")) or movement.get("actor_id", "") != values.initiative_order[values.current_actor_index]: errors.append("INVALID_MOVEMENT_ACTOR")
		if reaction.get("kind", "") != "challenge": errors.append("MOVEMENT_WITHOUT_REACTION")
		if not movement.get("path") is Array or not movement.get("route") is Dictionary or not _integer(movement.get("index")) or not movement.get("declined_challenges") is Array: errors.append("INVALID_PENDING_MOVEMENT")
		if errors.is_empty():
			if not movement.route.get("path") is Array or movement.path.is_empty() or movement.route.path.size() <= int(movement.index) or int(movement.index) != movement.path.size():
				errors.append("INVALID_MOVEMENT_PATH")
			elif movement.path.back() != values.heroes[movement.actor_id].hex or movement.path[0] != movement.get("origin", "") or movement.route.path.back() != movement.get("target", ""):
				errors.append("MOVEMENT_PATH_POSITION_MISMATCH")
