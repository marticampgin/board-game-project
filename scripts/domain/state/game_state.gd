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
	if not map.get("hexes") is Dictionary or not map.get("locations") is Dictionary or not map.get("sanctuaries") is Array:
		return ["INVALID_MAP"]
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
	for location_id: String in map.locations:
		var location: Variant = map.locations[location_id]
		if not location is Dictionary:
			errors.append("INVALID_LOCATION:" + location_id)
			continue
		if not map.hexes.has(location.get("hex", "")):
			errors.append("INVALID_LOCATION_HEX:" + location_id)
		if not str(location.get("trait", "")).is_empty() and not catalog.tower_traits.has(location.trait):
			errors.append("UNKNOWN_TOWER_TRAIT:" + location_id)
		if not str(location.get("owner_id", "")).is_empty() and not values.heroes.has(location.owner_id):
			errors.append("UNKNOWN_LOCATION_OWNER:" + location_id)
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
			elif int(item.state) <= 0 or int(item.state) >= 2147483647 or int(item.draw_index) < 0:
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
	return errors
