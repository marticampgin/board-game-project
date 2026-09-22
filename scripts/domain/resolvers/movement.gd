extends RefCounted
## A node is (hex, road_only). Retaining both states prevents an inexpensive
## mixed path from suppressing a longer all-road path with a larger budget.
const Hex = preload("res://scripts/domain/hex/hex.gd")

static func is_walkable(map: Dictionary, value: String) -> bool:
	if not map.get("hexes", {}).has(value):
		return false
	return map.hexes[value].terrain not in ["mountain", "water"]

static func road_key(a: String, b: String) -> String:
	return a + "|" + b if a < b else b + "|" + a

static func road_lookup(map: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for edge in map.get("roads", []):
		if edge.size() == 2:
			result[road_key(edge[0], edge[1])] = true
	for edge in map.get("bridges", []):
		if edge.size() == 2:
			result[road_key(edge[0], edge[1])] = true
	return result

static func reachable(map: Dictionary, heroes: Dictionary, hero_id: String) -> Dictionary:
	if not heroes.has(hero_id):
		return {}
	var hero: Dictionary = heroes[hero_id]
	var start: String = hero.hex
	var occupied: Dictionary = {}
	for other_id in heroes:
		if other_id != hero_id:
			occupied[heroes[other_id].hex] = true
	var roads := road_lookup(map)
	var frontier: Array[Dictionary] = [{"hex": start, "cost": 0, "path": [start], "road_only": true}]
	var best: Dictionary = {start + "|road": 0}
	var result: Dictionary = {}
	while not frontier.is_empty():
		frontier.sort_custom(_node_less)
		var current: Dictionary = frontier.pop_front()
		var state_key := str(current.hex) + ("|road" if current.road_only else "|mixed")
		if int(current.cost) != int(best[state_key]):
			continue
		if current.hex != start and map.hexes[current.hex].terrain == "swamp":
			continue
		for neighbor in Hex.neighbors(current.hex):
			if not is_walkable(map, neighbor) or occupied.has(neighbor):
				continue
			var on_road := roads.has(road_key(current.hex, neighbor))
			var road_only: bool = current.road_only and on_road
			var budget := 4 if road_only else int(hero.get("move", 3))
			var terrain: String = map.hexes[neighbor].terrain
			var step := 1 if on_road or terrain != "forest" or hero.get("class_id", "") == "ranger" else 2
			var cost: int = int(current.cost) + step
			if terrain == "swamp":
				# Roads never permit traversing a swamp within the same Move.
				cost = maxi(int(current.cost) + 1, budget)
			if cost > budget:
				continue
			var next_key: String = neighbor + ("|road" if road_only else "|mixed")
			if best.has(next_key) and int(best[next_key]) <= cost:
				continue
			best[next_key] = cost
			var path: Array = current.path.duplicate()
			path.append(neighbor)
			var next := {"hex": neighbor, "cost": cost, "path": path, "road_only": road_only}
			frontier.append(next)
			if neighbor != start and (not result.has(neighbor) or cost < int(result[neighbor].cost)):
				result[neighbor] = {"cost": cost, "path": path, "road_only": road_only}
	return result

static func _node_less(a: Dictionary, b: Dictionary) -> bool:
	if a.cost != b.cost:
		return a.cost < b.cost
	if a.hex != b.hex:
		return a.hex < b.hex
	return bool(a.road_only) and not bool(b.road_only)

static func travel_costs(map: Dictionary, start: String) -> Dictionary:
	if not is_walkable(map, start):
		return {}
	var roads := road_lookup(map)
	var result: Dictionary = {start: 0}
	var frontier: Array[Dictionary] = [{"hex": start, "cost": 0, "road_only": false}]
	while not frontier.is_empty():
		frontier.sort_custom(_node_less)
		var current: Dictionary = frontier.pop_front()
		if int(current.cost) != int(result[current.hex]):
			continue
		for neighbor in Hex.neighbors(current.hex):
			if not is_walkable(map, neighbor):
				continue
			var terrain: String = map.hexes[neighbor].terrain
			var step := 1
			if terrain == "swamp":
				step = 3
			elif terrain == "forest" and not roads.has(road_key(current.hex, neighbor)):
				step = 2
			var cost := int(current.cost) + step
			if not result.has(neighbor) or cost < int(result[neighbor]):
				result[neighbor] = cost
				frontier.append({"hex": neighbor, "cost": cost, "road_only": false})
	return result
