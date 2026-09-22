extends RefCounted
## A varied outer landscape surrounds guaranteed contested routes. Regeneration
## and final corridor repair are bounded, and every seed emits its diagnostics.
const Hex = preload("res://scripts/domain/hex/hex.gd")
const Rng = preload("res://scripts/services/deterministic_rng.gd")
const Validator = preload("res://scripts/domain/generation/map_validator.gd")
const Movement = preload("res://scripts/domain/resolvers/movement.gd")
const MAX_ATTEMPTS := 8
const REGION_NAMES := ["Blackwood", "Ash Plains", "The Mire", "Crownlands"]

static func generate(seed_value: int) -> Dictionary:
	var rng = Rng.new(seed_value)
	var last: Dictionary = {}
	var failures: Array = []
	for attempt in range(MAX_ATTEMPTS):
		last = _candidate(seed_value, rng)
		var report := validate(last)
		if report.valid:
			report.attempts = attempt + 1
			report.repairs = 0
			report.previous_failures = failures
			report.rng = rng.snapshot()
			last.report = report
			return last
		failures.append({"attempt": attempt + 1, "errors": report.errors})
	# A deterministic final repair connects every location to the ring/center.
	# This cannot loop: at most sixteen routes, each at most four edges long.
	for location in last.locations.values():
		_add_route(last, location.hex, "0,0")
	var final_report := validate(last)
	final_report.attempts = MAX_ATTEMPTS
	final_report.repairs = 1
	final_report.previous_failures = failures
	final_report.rng = rng.snapshot()
	last.report = final_report
	if not final_report.valid:
		push_error("Map generation failed for seed %d after %d attempts: %s" % [seed_value, MAX_ATTEMPTS, str(final_report.errors)])
	return last

static func validate(map: Dictionary) -> Dictionary:
	return Validator.validate(map)

static func _candidate(seed_value: int, rng: RefCounted) -> Dictionary:
	var map := {"seed": seed_value, "radius": 4, "hexes": {}, "locations": {}, "sanctuaries": [], "roads": [], "report": {}}
	var rotation := _roll(rng, 0, 5)
	var reflected := _roll(rng, 0, 1) == 1
	for value in Hex.range_keys("0,0", 4):
		var point := Hex.parse(value)
		map.hexes[value] = {"id": value, "q": point.x, "r": point.y, "terrain": "plains", "region": "", "location_id": ""}
	# Cluster fields instead of independent per-tile noise.
	var terrain_centers := Hex.ring("0,0", 3)
	for terrain in ["forest", "forest", "forest", "swamp", "swamp"]:
		var center: String = terrain_centers[_roll(rng, 0, terrain_centers.size() - 1)]
		for value in Hex.range_keys(center, 1):
			if map.hexes.has(value):
				map.hexes[value].terrain = terrain
	# Boundary blockers shape routes without splitting the inner board.
	var boundary := Hex.ring("0,0", 4)
	_shuffle(boundary, rng)
	var blocked: Array[String] = []
	for value in boundary:
		var separated := true
		for previous in blocked:
			if Hex.distance(value, previous) < 2:
				separated = false
		if separated:
			map.hexes[value].terrain = "mountain" if blocked.size() < 2 else "water"
			blocked.append(value)
		if blocked.size() == 4:
			break
	for value in ["0,-4", "4,-2", "0,4", "-4,2"]:
		map.sanctuaries.append(_transform(value, rotation, reflected))
	map.hexes["0,0"].terrain = "plains"
	# A ring supports alternate approaches; radial roads are shorter/contested.
	var inner_ring := Hex.ring("0,0", 2)
	for value in inner_ring:
		_clear_route_hex(map, value)
		for neighbor in Hex.neighbors(value):
			if inner_ring.has(neighbor):
				_add_road(map, value, neighbor)
	for sanctuary in map.sanctuaries:
		_add_route(map, sanctuary, "0,0")
	_place(map, "worldspire", "worldspire", "0,0", "The Worldspire", rng)
	for index in range(4):
		var sanctuary: String = map.sanctuaries[index]
		var candidates: Array[String] = []
		for value in Hex.neighbors(sanctuary):
			if Hex.distance("0,0", value) == 3 and map.hexes.has(value):
				candidates.append(value)
		var minor_hex := candidates[_roll(rng, 0, candidates.size() - 1)]
		_place(map, "minor_%d" % (index + 1), "minor_tower", minor_hex, ["Briar Watch", "Ashguard", "Mire Lantern", "Crown Watch"][index], rng)
		_add_route(map, sanctuary, minor_hex)
	# Settlements and ruins use opposed ring positions; rotation varies their map orientation.
	for index in range(2):
		_place(map, "settlement_%d" % (index + 1), "settlement", _transform(["2,0", "-2,0"][index], rotation, reflected), ["Hearthmarket", "Greyhaven"][index], rng)
		_place(map, "ruin_%d" % (index + 1), "ruin", _transform(["0,2", "0,-2"][index], rotation, reflected), ["Fallen Archive", "Sunken Vault"][index], rng)
	var ancient_candidates: Array[String] = []
	for value in inner_ring:
		if str(map.hexes[value].location_id).is_empty():
			ancient_candidates.append(value)
	_shuffle(ancient_candidates, rng)
	for index in range(3):
		_place(map, "ancient_%d" % (index + 1), "ancient_tower", ancient_candidates[index], ["Dawn Pillar", "Hollow Crown", "Starfall Spire"][index], rng)
	for index in range(4):
		var camp_candidates: Array[String] = []
		for value in Hex.range_keys(map.sanctuaries[index], 2):
			if map.hexes.has(value) and Hex.distance("0,0", value) == 3 and str(map.hexes[value].location_id).is_empty():
				camp_candidates.append(value)
		_shuffle(camp_candidates, rng)
		_place(map, "camp_%d" % (index + 1), "monster_camp", camp_candidates[0], ["Wolf Den", "Ash Marauders", "Bog Stalkers", "Oathless Camp"][index], rng)
	_assign_regions(map)
	# Repair a rare isolated boundary pocket without rerolling the whole layout.
	var connected := Movement.travel_costs(map, "0,0")
	for value in Hex.sort_keys(map.hexes.keys()):
		if Movement.is_walkable(map, value) and not connected.has(value):
			_add_route(map, value, "0,0")
	return map

static func _place(map: Dictionary, id: String, kind: String, value: String, label: String, rng: RefCounted) -> void:
	assert(str(map.hexes[value].location_id).is_empty(), "Locations must not overlap")
	_clear_route_hex(map, value)
	var trait_id := ""
	if kind in ["minor_tower", "ancient_tower", "worldspire"]:
		trait_id = ["watchtower", "fortress"][_roll(rng, 0, 1)]
	map.locations[id] = {"id": id, "hex": value, "kind": kind, "name": label, "owner_id": "", "level": 1, "trait": trait_id, "discovered_by": []}
	map.hexes[value].location_id = id

static func _clear_route_hex(map: Dictionary, value: String) -> void:
	if map.hexes[value].terrain in ["mountain", "water", "swamp"]:
		map.hexes[value].terrain = "plains"

static func _add_route(map: Dictionary, start: String, target: String) -> void:
	var current := start
	_clear_route_hex(map, current)
	while current != target:
		var candidates := Hex.neighbors(current)
		candidates.sort()
		for neighbor in candidates:
			if map.hexes.has(neighbor) and Hex.distance(neighbor, target) < Hex.distance(current, target):
				_clear_route_hex(map, neighbor)
				_add_road(map, current, neighbor)
				current = neighbor
				break

static func _add_road(map: Dictionary, a: String, b: String) -> void:
	var edge: Array = [a, b] if a < b else [b, a]
	if not map.roads.has(edge):
		map.roads.append(edge)

static func _assign_regions(map: Dictionary) -> void:
	# Deterministic multi-source flood fill guarantees four contiguous named regions.
	var queue: Array[String] = []
	for index in range(map.sanctuaries.size()):
		var value: String = map.sanctuaries[index]
		map.hexes[value].region = REGION_NAMES[index]
		queue.append(value)
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for neighbor in Hex.neighbors(current):
			if map.hexes.has(neighbor) and str(map.hexes[neighbor].region).is_empty():
				map.hexes[neighbor].region = map.hexes[current].region
				queue.append(neighbor)

static func _transform(value: String, rotation: int, reflected: bool) -> String:
	var cube := Hex.to_cube(value)
	if reflected:
		cube = Vector3i(cube.z, cube.y, cube.x)
	for index in range(rotation):
		cube = Vector3i(-cube.z, -cube.x, -cube.y)
	return Hex.from_cube(cube)

static func _roll(rng: RefCounted, minimum: int, maximum: int) -> int:
	return int(rng.draw("map", minimum, maximum).result)

static func _shuffle(values: Array, rng: RefCounted) -> void:
	for index in range(values.size() - 1, 0, -1):
		var other := _roll(rng, 0, index)
		var temporary: Variant = values[index]
		values[index] = values[other]
		values[other] = temporary
