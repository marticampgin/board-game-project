extends RefCounted
const Hex = preload("res://scripts/domain/hex/hex.gd")
const Movement = preload("res://scripts/domain/resolvers/movement.gd")
const EXPECTED_COUNTS := {"worldspire": 1, "ancient_tower": 3, "minor_tower": 4, "settlement": 2, "ruin": 2, "monster_camp": 4}

static func validate(map: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var diagnostics: Dictionary = {"spawns": {}, "location_counts": {}, "terrain_counts": {}}
	var hexes: Dictionary = map.get("hexes", {})
	var locations: Dictionary = map.get("locations", {})
	var sanctuaries: Array = map.get("sanctuaries", [])
	if hexes.size() != 61:
		errors.append("Expected 61 hexes; got %d" % hexes.size())
	if locations.size() != 16:
		errors.append("Expected 16 locations; got %d" % locations.size())
	if sanctuaries.size() != 4:
		errors.append("Expected four sanctuaries")
	var location_hexes: Dictionary = {}
	for id in locations:
		var location: Dictionary = locations[id]
		var value: String = location.get("hex", "")
		var kind: String = location.get("kind", "")
		diagnostics.location_counts[kind] = int(diagnostics.location_counts.get(kind, 0)) + 1
		if not Movement.is_walkable(map, value):
			errors.append("Location %s is outside walkable terrain" % id)
		elif hexes[value].get("location_id", "") != id:
			errors.append("Location %s has inconsistent hex backlink" % id)
		if location_hexes.has(value):
			errors.append("Locations overlap at %s" % value)
		location_hexes[value] = id
	for kind in EXPECTED_COUNTS:
		if int(diagnostics.location_counts.get(kind, 0)) != int(EXPECTED_COUNTS[kind]):
			errors.append("Wrong count for %s" % kind)
	if not locations.has("worldspire") or locations.worldspire.get("hex", "") != "0,0":
		errors.append("The Worldspire must occupy the center")
	for value in hexes:
		if not Hex.in_bounds(value, 4):
			errors.append("Hex %s is outside radius four" % value)
		var terrain: String = hexes[value].get("terrain", "")
		diagnostics.terrain_counts[terrain] = int(diagnostics.terrain_counts.get(terrain, 0)) + 1
		if terrain not in ["plains", "forest", "swamp", "mountain", "water"]:
			errors.append("Unknown terrain %s" % terrain)
	for road in map.get("roads", []):
		if road.size() != 2 or not hexes.has(road[0]) or not hexes.has(road[1]):
			errors.append("Road endpoint is missing")
		elif Hex.distance(road[0], road[1]) != 1 or not Movement.is_walkable(map, road[0]) or not Movement.is_walkable(map, road[1]):
			errors.append("Road does not join adjacent walkable hexes")
	var connected := Movement.travel_costs(map, "0,0")
	for value in hexes:
		if Movement.is_walkable(map, value) and not connected.has(value):
			errors.append("Walkable hex %s is disconnected" % value)
	var world_costs: Array[int] = []
	var scores: Array[int] = []
	var roads := Movement.road_lookup(map)
	for index in range(sanctuaries.size()):
		var spawn: String = sanctuaries[index]
		if not Movement.is_walkable(map, spawn):
			errors.append("Sanctuary %s is impassable" % spawn)
			continue
		if location_hexes.has(spawn):
			errors.append("Sanctuary overlaps location at %s" % spawn)
		for other in sanctuaries.slice(index + 1):
			if Hex.distance(spawn, other) <= 1:
				errors.append("Sanctuaries begin within attack range")
		var costs := Movement.travel_costs(map, spawn)
		var capturable := 999
		var exploration := 999
		var score := 0
		var road_access := false
		var reachable_regions: Dictionary = {}
		for value in costs:
			reachable_regions[hexes[value].region] = true
			if int(costs[value]) <= 1:
				for neighbor in Hex.neighbors(value):
					if roads.has(Movement.road_key(value, neighbor)):
						road_access = true
		for location in locations.values():
			var cost := int(costs.get(location.hex, 999))
			if location.kind in ["minor_tower", "settlement"]:
				capturable = mini(capturable, cost)
				if cost <= 6:
					score += 3
			elif location.kind in ["ruin", "monster_camp"]:
				exploration = mini(exploration, cost)
				if cost <= 8:
					score += 2
		if road_access:
			score += 1
		var world_cost := int(costs.get("0,0", 999))
		world_costs.append(world_cost)
		scores.append(score)
		diagnostics.spawns[spawn] = {"worldspire_cost": world_cost, "nearest_capture_cost": capturable, "nearest_exploration_cost": exploration, "opportunity_score": score, "useful_road_access": road_access, "reachable_regions": reachable_regions.size()}
		if world_cost == 999:
			errors.append("Worldspire unreachable from %s" % spawn)
		if capturable > 6:
			errors.append("No capture within cost six from %s" % spawn)
		if exploration > 8:
			errors.append("No exploration within cost eight from %s" % spawn)
		if reachable_regions.size() < 3:
			errors.append("Spawn %s cannot reach two neighboring regions" % spawn)
	if not world_costs.is_empty():
		diagnostics.worldspire_cost_spread = int(world_costs.max()) - int(world_costs.min())
		if diagnostics.worldspire_cost_spread > 3:
			errors.append("Worldspire travel cost spread exceeds three")
	if not scores.is_empty():
		diagnostics.opportunity_spread = float(int(scores.max()) - int(scores.min())) / maxi(1, int(scores.min()))
		if diagnostics.opportunity_spread > 0.25:
			errors.append("Early opportunity score spread exceeds 25%%: %.3f" % diagnostics.opportunity_spread)
	_validate_regions(hexes, errors)
	_validate_alternate_routes(map, errors, diagnostics)
	diagnostics.valid = errors.is_empty()
	diagnostics.errors = errors
	diagnostics.seed = map.get("seed", 0)
	diagnostics.opportunity_definition = "Capture weight 3 within cost 6; ruin/camp weight 2 within cost 8; useful road within cost 1 weight 1; (max-min)/min <= 25%."
	return diagnostics

static func _validate_alternate_routes(map: Dictionary, errors: Array[String], diagnostics: Dictionary) -> void:
	# A rival standing on one tower must not seal a sanctuary's only route
	# to the central contest. Check topology separately from travel cost.
	var tested := 0
	for location in map.get("locations", {}).values():
		if location.get("kind", "") not in ["minor_tower", "ancient_tower"]:
			continue
		var blocked: String = location.hex
		var queue: Array[String] = ["0,0"]
		var visited: Dictionary = {"0,0": true}
		while not queue.is_empty():
			var current: String = queue.pop_front()
			for neighbor in Hex.neighbors(current):
				if neighbor != blocked and not visited.has(neighbor) and Movement.is_walkable(map, neighbor):
					visited[neighbor] = true
					queue.append(neighbor)
		for spawn in map.get("sanctuaries", []):
			if not visited.has(spawn):
				errors.append("Tower %s can block sanctuary %s from the Worldspire" % [location.id, spawn])
		tested += 1
	diagnostics.alternate_routes_checked = tested

static func _validate_regions(hexes: Dictionary, errors: Array[String]) -> void:
	var regions: Dictionary = {}
	for value in hexes:
		var region: String = hexes[value].get("region", "")
		if not regions.has(region):
			regions[region] = []
		regions[region].append(value)
	if regions.size() < 4 or regions.size() > 6 or regions.has(""):
		errors.append("Expected four to six named regions")
	for name in regions:
		var queue: Array = [regions[name][0]]
		var visited: Dictionary = {regions[name][0]: true}
		while not queue.is_empty():
			var current: String = queue.pop_front()
			for neighbor in Hex.neighbors(current):
				if hexes.has(neighbor) and hexes[neighbor].region == name and not visited.has(neighbor):
					visited[neighbor] = true
					queue.append(neighbor)
		if visited.size() != regions[name].size():
			errors.append("Region %s is not contiguous" % name)
