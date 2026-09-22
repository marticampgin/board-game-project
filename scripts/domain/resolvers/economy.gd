extends RefCounted
const Movement = preload("res://scripts/domain/resolvers/movement.gd")
const Hex = preload("res://scripts/domain/hex/hex.gd")
const Equipment = preload("res://scripts/domain/resolvers/equipment.gd")

static func settlements(game: RefCounted, player_id: String) -> Array[String]:
	var result: Array[String] = []
	for location_id: String in game.state.data.map.locations:
		var location: Dictionary = game.state.data.map.locations[location_id]
		if location.kind == "settlement" and location.owner_id == player_id: result.append(location_id)
	result.sort()
	return result

static func network(game: RefCounted, player_id: String) -> Dictionary:
	var owned: Array[String] = settlements(game, player_id)
	var result: Dictionary = {"connected": false, "path": [], "settlements": owned}
	if owned.size() < 2: return result
	var map: Dictionary = game.state.data.map
	var start: String = map.locations[owned[0]].hex
	var goal: String = map.locations[owned[1]].hex
	var roads: Dictionary = Movement.road_lookup(map)
	var queue: Array[String] = [start]
	var previous: Dictionary = {start: ""}
	while not queue.is_empty():
		var current: String = queue.pop_front()
		if current == goal:
			var path: Array[String] = []
			while not current.is_empty():
				path.push_front(current)
				current = previous[current]
			result.connected = true
			result.path = path
			return result
		for neighbor: String in Hex.neighbors(current):
			if previous.has(neighbor) or not Movement.is_walkable(map, neighbor) or not roads.has(Movement.road_key(current, neighbor)): continue
			var location: Dictionary = map.locations.get(map.hexes[neighbor].location_id, {})
			if not location.is_empty() and location.owner_id not in ["", player_id]: continue
			previous[neighbor] = current
			queue.append(neighbor)
	return result

static func trade_options(game: RefCounted, player_id: String) -> Dictionary:
	var hero: Dictionary = game.state.data.heroes[player_id]
	var location: Dictionary = game._hero_location(player_id)
	var at_market: bool = hero.hex == game.state.data.get("market_hex", "")
	if not at_market and (location.is_empty() or location.kind != "settlement" or location.owner_id not in ["", player_id]): return {}
	var options: Dictionary = {}
	var power_gain: int = Equipment.trade_gain(hero, 1)
	var gold_gain: int = Equipment.trade_gain(hero, 2)
	if int(hero.gold) >= 2 and int(hero.power) + power_gain <= int(game.definitions.rules.power_cap):
		options.gold_to_power = {"cost_resource": "gold", "cost": 2, "gain_resource": "power", "gain": power_gain}
	if int(hero.power) >= 1:
		options.power_to_gold = {"cost_resource": "power", "cost": 1, "gain_resource": "gold", "gain": gold_gain}
	return options

static func trade(game: RefCounted, player_id: String, direction: String) -> void:
	var offer: Dictionary = trade_options(game, player_id)[direction]
	var hero: Dictionary = game.state.data.heroes[player_id]
	hero[offer.cost_resource] -= int(offer.cost)
	hero[offer.gain_resource] += int(offer.gain)
	game._emit("TradeCompleted", player_id, {"direction": direction, "offer": offer.duplicate(true), "hex": hero.hex, "gold": hero.gold, "power": hero.power})
	if hero.class_id == "merchant": game._class_fate(player_id, "trade")

static func income(game: RefCounted) -> void:
	var location_ids: Array = game.state.data.map.locations.keys()
	location_ids.sort()
	var merchant_networks: Dictionary = {}
	for player_id: String in game.state.data.heroes:
		merchant_networks[player_id] = game.state.data.heroes[player_id].class_id == "merchant" and network(game, player_id).connected
	for location_id: String in location_ids:
		var location: Dictionary = game.state.data.map.locations[location_id]
		var owner_id: String = location.owner_id
		if owner_id.is_empty(): continue
		var hero: Dictionary = game.state.data.heroes[owner_id]
		var resource: String = "power"
		var amount: int = 0
		match str(location.kind):
			"minor_tower": amount = int(game.definitions.rules.minor_tower_income)
			"ancient_tower", "worldspire": amount = int(game.definitions.rules.ancient_tower_income)
			"settlement":
				resource = "gold"
				amount = int(game.definitions.rules.settlement_income)
				if merchant_networks[owner_id]: amount += 1
		if int(location.level) == 3: amount += 1
		amount += int(location.get("world_income_bonus", 0))
		var before: int = hero[resource]
		hero[resource] = mini(before + amount, int(game.definitions.rules.power_cap)) if resource == "power" else before + amount
		game._emit("IncomeGranted", owner_id, {"location_id": location_id, "resource": resource, "amount": int(hero[resource]) - before, "base_amount": amount, "before": before, "after": hero[resource], "capped": int(hero[resource]) < before + amount, "network_bonus": resource == "gold" and merchant_networks[owner_id]})
