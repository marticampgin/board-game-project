extends RefCounted
## Five bounded, seeded event resolvers. Every temporary modification carries
## enough original state to expire cleanly through a save/load boundary.
const Hex = preload("res://scripts/domain/hex/hex.gd")
const Movement = preload("res://scripts/domain/resolvers/movement.gd")

static func initialize(game: RefCounted) -> void:
	game.state.data.world_effects = []
	game.state.data.market_hex = ""
	game.state.data.last_world_event_round = 0
	var map: Dictionary = game.state.data.map
	map.blocked_edges = []
	map.bridge_edges = []
	var candidates: Array = []
	for edge: Array in map.roads:
		if Hex.distance("0,0", edge[0]) == 2 and Hex.distance("0,0", edge[1]) == 2:
			candidates.append(edge.duplicate())
	candidates.sort_custom(func(a: Array, b: Array) -> bool: return Movement.road_key(a[0], a[1]) < Movement.road_key(b[0], b[1]))
	for index in range(mini(3, candidates.size())):
		map.bridge_edges.append(candidates[index * candidates.size() / 3].duplicate())
	for location: Dictionary in map.locations.values():
		location.world_income_bonus = 0
		location.world_defence_modifier = 0

static func world_phase(game: RefCounted) -> void:
	var round_number := int(game.state.data.round_number)
	if int(game.state.data.get("last_world_event_round", 0)) == round_number: return
	_expire(game, "world")
	game.state.data.last_world_event_round = round_number
	if round_number == 1:
		game._emit("WorldEventSkipped", "", {"reason": "first_round"})
		return
	var available := eligible_events(game)
	if available.is_empty():
		game._emit("WorldEventSkipped", "", {"reason": "no_eligible_effect"})
		return
	var roll: Dictionary = game._draw("world_events", 0, available.size() - 1, "", "world_event")
	var selected: String = available[int(roll.result)]
	game._emit("WorldEventSelected", "", {"event_id": selected, "round": round_number, "eligible_events": available.duplicate()})
	apply_event(game, selected)

static func eligible_events(game: RefCounted) -> Array[String]:
	var result: Array[String] = []
	var ids: Array = game.definitions.world_events.keys()
	ids.sort()
	for id: String in ids:
		if not _candidates(game, id).is_empty(): result.append(id)
	return result

static func apply_event(game: RefCounted, event_id: String) -> bool:
	var candidates := _candidates(game, event_id)
	if candidates.is_empty(): return false
	var roll: Dictionary = game._draw("world_events", 0, candidates.size() - 1, "", event_id + "_target")
	var target: Variant = candidates[int(roll.result)]
	var round_number := int(game.state.data.round_number)
	var effect := {"event_id": event_id, "started_round": round_number, "expires_round": round_number, "expiry": "resolution"}
	var details := {"event_id": event_id, "name": game.definitions.world_events[event_id].name}
	match event_id:
		"collapsed_bridge":
			var edge: Array = target
			game.state.data.map.blocked_edges.append(edge.duplicate())
			game.state.data.map.roads.erase(edge)
			effect.edge = edge.duplicate()
			effect.expires_round = round_number + 2
			effect.expiry = "world"
			details.edge = edge.duplicate()
			details.alternate_path = _alternate_path(game.state.data.map, edge[0], edge[1])
			details.expires_round = effect.expires_round
		"unstable_leyline":
			var location: Dictionary = game.state.data.map.locations[target]
			location.world_income_bonus += 1
			location.world_defence_modifier -= 1
			effect.location_id = target
			details.location_id = target
			details.power_bonus = 1
			details.defence_modifier = -1
		"monster_migration":
			var monster: Dictionary = game.state.data.monsters[target]
			monster.reinforcements = int(monster.get("reinforcements", 0)) + 1
			monster.max_hp += 1
			monster.hp += 1
			monster.defence += 1
			details.monster_id = target
			details.hex = monster.hex
			details.hp_bonus = 1
			details.defence_bonus = 1
			effect.expiry = "permanent"
		"cursed_ground":
			var changed: Array[String] = []
			for value: String in Hex.sort_keys(game.state.data.map.hexes.keys()):
				var tile: Dictionary = game.state.data.map.hexes[value]
				if tile.region == target and tile.terrain == "plains":
					tile.movement_terrain = "forest"
					changed.append(value)
			effect.hexes = changed
			details.region = target
			details.hexes = changed.duplicate()
			details.movement_only = true
		"wandering_market":
			game.state.data.market_hex = target
			effect.hex = target
			details.hex = target
	if effect.expiry != "permanent": game.state.data.world_effects.append(effect)
	game._emit("WorldEventApplied", "", details)
	game._emit("WorldEventResolved", "", details.duplicate(true))
	return true

static func resolution_expiry(game: RefCounted) -> void:
	_expire(game, "resolution")

static func _expire(game: RefCounted, timing: String) -> void:
	var remaining: Array = []
	for effect: Dictionary in game.state.data.world_effects:
		if effect.expiry != timing or int(effect.expires_round) > int(game.state.data.round_number):
			remaining.append(effect)
			continue
		match str(effect.event_id):
			"collapsed_bridge":
				game.state.data.map.blocked_edges.erase(effect.edge)
				if not game.state.data.map.roads.has(effect.edge): game.state.data.map.roads.append(effect.edge.duplicate())
			"unstable_leyline":
				var location: Dictionary = game.state.data.map.locations[effect.location_id]
				location.world_income_bonus -= 1
				location.world_defence_modifier += 1
			"cursed_ground":
				for value: String in effect.hexes:
					game.state.data.map.hexes[value].erase("movement_terrain")
			"wandering_market":
				game.state.data.market_hex = ""
		game._emit("WorldEffectExpired", "", {"event_id": effect.event_id, "round": game.state.data.round_number})
	game.state.data.world_effects = remaining

static func _candidates(game: RefCounted, event_id: String) -> Array:
	var result: Array = []
	var map: Dictionary = game.state.data.map
	match event_id:
		"collapsed_bridge":
			for edge: Array in map.get("bridge_edges", []):
				if map.get("blocked_edges", []).has(edge): continue
				var trial: Dictionary = map.duplicate(true)
				trial.blocked_edges.append(edge.duplicate())
				var connected := Movement.travel_costs(trial, "0,0")
				var valid := true
				for value: String in map.hexes:
					if Movement.is_walkable(map, value) and not connected.has(value): valid = false
				if valid and not _alternate_path(trial, edge[0], edge[1]).is_empty(): result.append(edge.duplicate())
			result.sort_custom(func(a: Array, b: Array) -> bool: return Movement.road_key(a[0], a[1]) < Movement.road_key(b[0], b[1]))
		"unstable_leyline":
			for id: String in map.locations:
				if map.locations[id].kind in ["minor_tower", "ancient_tower", "worldspire"]: result.append(id)
			result.sort()
		"monster_migration":
			var richest: Dictionary = game.state.data.heroes.p1
			for id: String in ["p2", "p3", "p4"]:
				if int(game.state.data.heroes[id].gold) > int(richest.gold): richest = game.state.data.heroes[id]
			var nearest := 999
			var ids: Array = game.state.data.monsters.keys()
			ids.sort()
			for id: String in ids:
				var monster: Dictionary = game.state.data.monsters[id]
				if int(monster.hp) <= 0 or int(monster.get("reinforcements", 0)) >= 2: continue
				var distance := Hex.distance(monster.hex, richest.hex)
				if distance < nearest:
					nearest = distance
					result = [id]
				elif distance == nearest: result.append(id)
		"cursed_ground":
			for value: String in map.hexes:
				var tile: Dictionary = map.hexes[value]
				if tile.terrain == "plains" and not result.has(tile.region): result.append(tile.region)
			result.sort()
		"wandering_market":
			for value: String in Hex.sort_keys(map.hexes.keys()):
				if not Movement.is_walkable(map, value) or game._is_occupied(value) or map.sanctuaries.has(value): continue
				var location: Dictionary = map.locations.get(map.hexes[value].location_id, {})
				if location.is_empty(): result.append(value)
	return result

static func _alternate_path(map: Dictionary, start: String, finish: String) -> Array[String]:
	var blocked := Movement.blocked_lookup(map)
	var queue: Array[String] = [start]
	var parents: Dictionary = {start: ""}
	while not queue.is_empty():
		var current: String = queue.pop_front()
		if current == finish:
			var path: Array[String] = []
			while not current.is_empty():
				path.push_front(current)
				current = parents[current]
			return path
		for neighbor: String in Hex.neighbors(current):
			if not parents.has(neighbor) and Movement.is_walkable(map, neighbor) and not blocked.has(Movement.road_key(current, neighbor)):
				parents[neighbor] = current
				queue.append(neighbor)
	return []
