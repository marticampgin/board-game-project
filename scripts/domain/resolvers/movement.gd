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
	var blocked := blocked_lookup(map)
	for edge in map.get("roads", []):
		if edge.size() == 2 and not blocked.has(road_key(edge[0], edge[1])):
			result[road_key(edge[0], edge[1])] = true
	for edge in map.get("bridges", []):
		if edge.size() == 2 and not blocked.has(road_key(edge[0], edge[1])):
			result[road_key(edge[0], edge[1])] = true
	return result

static func blocked_lookup(map: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for edge in map.get("blocked_edges", []):
		if edge.size() == 2: result[road_key(edge[0], edge[1])] = true
	return result

static func reachable(map: Dictionary, heroes: Dictionary, hero_id: String, options: Dictionary = {}) -> Dictionary:
	if not heroes.has(hero_id):
		return {}
	var hero: Dictionary = heroes[hero_id]
	var start: String = hero.hex
	var occupied: Dictionary = {}
	for other_id in heroes:
		if other_id != hero_id:
			occupied[heroes[other_id].hex] = true
	var roads := road_lookup(map)
	var blocked := blocked_lookup(map)
	var frontier: Array[Dictionary] = [{"hex": start, "cost": 0, "path": [start], "road_only": true, "ignored_penalty": false, "ignored_terrain": "", "ignored_hex": "", "trail_boots_used": false, "trail_boots_hex": "", "waived_hexes": []}]
	var best: Dictionary = {start + "|road|available|boots_available": 0}
	var result: Dictionary = {}
	while not frontier.is_empty():
		frontier.sort_custom(_node_less)
		var current: Dictionary = frontier.pop_front()
		var state_key := _state_key(current)
		if int(current.cost) != int(best[state_key]):
			continue
		if current.hex != start and map.hexes[current.hex].terrain == "swamp":
			continue
		for neighbor in Hex.neighbors(current.hex):
			if not is_walkable(map, neighbor) or occupied.has(neighbor) or blocked.has(road_key(current.hex, neighbor)):
				continue
			var on_road := roads.has(road_key(current.hex, neighbor))
			var road_only: bool = current.road_only and on_road
			var budget := 4 if road_only else int(hero.get("move", 3))
			var terrain: String = map.hexes[neighbor].get("movement_terrain", map.hexes[neighbor].terrain)
			var step := 1 if on_road or terrain != "forest" or hero.get("class_id", "") == "ranger" else 2
			var choices: Array[String] = ["none"]
			if options.get("forced_march", false) and not current.ignored_penalty and (step > 1 or terrain == "swamp"):
				choices.append("forced")
			if options.get("trail_boots", false) and not current.trail_boots_used and terrain == "forest" and step > 1:
				choices.append("boots")
			for waiver in choices:
				var ignore_now := waiver != "none"
				var cost: int = int(current.cost) + (1 if ignore_now else step)
				if terrain == "swamp" and not ignore_now:
					# Neither roads nor Forced March remove the mandatory swamp stop.
					cost = maxi(int(current.cost) + 1, budget)
				if cost > budget:
					continue
				var path: Array = current.path.duplicate()
				path.append(neighbor)
				var waived: Array = current.waived_hexes.duplicate()
				if ignore_now: waived.append(neighbor)
				var next := {"hex": neighbor, "cost": cost, "path": path, "road_only": road_only,
					"ignored_penalty": current.ignored_penalty or waiver == "forced",
					"ignored_terrain": terrain if waiver == "forced" else current.ignored_terrain,
					"ignored_hex": neighbor if waiver == "forced" else current.ignored_hex,
					"trail_boots_used": current.trail_boots_used or waiver == "boots",
					"trail_boots_hex": neighbor if waiver == "boots" else current.trail_boots_hex, "waived_hexes": waived}
				var next_key := _state_key(next)
				if best.has(next_key) and int(best[next_key]) <= cost:
					continue
				best[next_key] = cost
				frontier.append(next)
				if neighbor != start and (not result.has(neighbor) or cost < int(result[neighbor].cost)):
					result[neighbor] = {"cost": cost, "path": path, "road_only": road_only,
						"ignored_penalty": next.ignored_penalty, "ignored_terrain": next.ignored_terrain, "ignored_hex": next.ignored_hex,
						"trail_boots_used": next.trail_boots_used, "trail_boots_hex": next.trail_boots_hex, "waived_hexes": waived}
	return result

static func _state_key(node: Dictionary) -> String:
	return str(node.hex) + ("|road" if node.road_only else "|mixed") + ("|used" if node.ignored_penalty else "|available") + ("|boots_used" if node.trail_boots_used else "|boots_available")

static func _node_less(a: Dictionary, b: Dictionary) -> bool:
	if a.cost != b.cost:
		return a.cost < b.cost
	if a.hex != b.hex:
		return a.hex < b.hex
	if a.road_only != b.road_only:
		return bool(a.road_only) and not bool(b.road_only)
	return not a.get("ignored_penalty", false) and b.get("ignored_penalty", false)

static func travel_costs(map: Dictionary, start: String) -> Dictionary:
	if not is_walkable(map, start):
		return {}
	var roads := road_lookup(map)
	var blocked := blocked_lookup(map)
	var result: Dictionary = {start: 0}
	var frontier: Array[Dictionary] = [{"hex": start, "cost": 0, "road_only": false}]
	while not frontier.is_empty():
		frontier.sort_custom(_node_less)
		var current: Dictionary = frontier.pop_front()
		if int(current.cost) != int(result[current.hex]):
			continue
		for neighbor in Hex.neighbors(current.hex):
			if not is_walkable(map, neighbor) or blocked.has(road_key(current.hex, neighbor)):
				continue
			var terrain: String = map.hexes[neighbor].get("movement_terrain", map.hexes[neighbor].terrain)
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
