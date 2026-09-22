extends RefCounted
## Class planning and the two concrete movement reaction windows.
const Hex = preload("res://scripts/domain/hex/hex.gd")
const Movement = preload("res://scripts/domain/resolvers/movement.gd")
const Equipment = preload("res://scripts/domain/resolvers/equipment.gd")

static func planning_options(game: RefCounted, player_id: String) -> Dictionary:
	var hero: Dictionary = game.state.data.heroes[player_id]
	var result: Dictionary = {"choices": ["no_change"], "initiative_push": int(hero.fate) >= 2, "snare_targets": {}, "prepared_hex_targets": {}}
	result.purchases = Equipment.purchase_options(game, player_id)
	result.slots = maxi(0, 3 - hero.upgrades.size())
	if hero.class_id == "ranger" and int(hero.power) >= 1:
		for candidate: String in Hex.range_keys(hero.hex, 2):
			if Movement.is_walkable(game.state.data.map, candidate) and not game._is_occupied(candidate) and not game.state.data.map.sanctuaries.has(candidate):
				result.snare_targets[candidate] = {"hex": candidate}
	if hero.class_id == "cultist" and int(hero.power) >= 1:
		for target_id: String in game.state.data.heroes:
			if target_id != player_id:
				var target: Dictionary = game.state.data.heroes[target_id]
				result.prepared_hex_targets[target_id] = {"name": target.name, "hex": target.hex}
	return result

static func validate_plan(game: RefCounted, player_id: String, plan: Dictionary) -> Dictionary:
	var options: Dictionary = planning_options(game, player_id)
	for key: String in plan:
		if key not in ["no_change", "initiative_push", "snare", "prepared_hex", "purchases"]:
			return game._reject("INVALID_PLAN", "Unknown planning choice: " + key)
		if key in ["no_change", "initiative_push"] and not plan[key] is bool:
			return game._reject("INVALID_PLAN", "Planning flags must be boolean.")
	if plan.get("initiative_push", false) and not options.initiative_push:
		return game._reject("INSUFFICIENT_FATE", "Initiative Push costs two Fate.")
	if plan.has("snare") and (not plan.snare is String or not options.snare_targets.has(plan.snare)):
		return game._reject("INVALID_SNARE_TARGET", "Snare requires Ranger, one Power, and an eligible nearby hex.")
	if plan.has("prepared_hex") and (not plan.prepared_hex is String or not options.prepared_hex_targets.has(plan.prepared_hex)):
		return game._reject("INVALID_HEX_TARGET", "Prepared Hex requires Cultist, one Power, and a visible enemy.")
	if plan.has("purchases"):
		if not plan.purchases is Array: return game._reject("INVALID_PURCHASES", "Purchases must be an array of upgrade IDs.")
		return Equipment.validate_purchase(game, player_id, plan.purchases)
	return {"is_valid": true}

static func apply_plans(game: RefCounted) -> void:
	for player_id: String in ["p1", "p2", "p3", "p4"]:
		var plan: Dictionary = game.state.data.plans[player_id]
		var hero: Dictionary = game.state.data.heroes[player_id]
		if plan.has("purchases"): Equipment.purchase(game, player_id, plan.purchases)
		if plan.get("initiative_push", false):
			hero.fate -= 2
			hero.flags.initiative_push = 2
			game._emit("FateSpent", player_id, {"cause": "initiative_push", "amount": 2, "after": hero.fate})
		if plan.has("snare"):
			hero.power -= 1
			game.state.data.traps[player_id] = {"owner_id": player_id, "hex": plan.snare, "kind": "snare", "expires_round": game.state.data.round_number}
			game._emit("SnarePrepared", player_id, {"hex": plan.snare, "cost": 1, "expires_round": game.state.data.round_number}, "owner_only")
			game._emit("TrapWarningPlaced", player_id, {"hex": plan.snare, "warning": "trapped_hex"})
		if plan.has("prepared_hex"):
			hero.power -= 1
			hero.prepared_hex = {"target_id": plan.prepared_hex, "expires_planning_round": int(game.state.data.round_number) + 1}
			game._emit("HexPrepared", player_id, {"target_id": plan.prepared_hex, "cost": 1}, "owner_only")

static func begin_move(game: RefCounted, player_id: String, target: String, forced: bool) -> void:
	var route: Dictionary = game._movement_targets(player_id, forced)[target]
	var hero: Dictionary = game.state.data.heroes[player_id]
	if forced:
		hero.power -= 1
		game._modify_next_cycle(player_id, 2, "forced_march")
		game._emit("ForcedMarchUsed", player_id, {"power_cost": 1, "ignored_penalty": route.get("ignored_penalty", false), "ignored_hex": route.get("ignored_hex", "")})
	game.state.data.pending_move = {"actor_id": player_id, "origin": hero.hex, "target": target, "route": route.duplicate(true), "path": [hero.hex], "index": 1, "forced_march": forced, "declined_challenges": []}
	resume_move(game)

static func resume_move(game: RefCounted) -> void:
	var movement: Dictionary = game.state.data.pending_move
	var hero: Dictionary = game.state.data.heroes[movement.actor_id]
	var full_path: Array = movement.route.path
	while int(movement.index) < full_path.size():
		var next_hex: String = full_path[movement.index]
		# At least one step must actually occur before Challenge can halt a Move.
		if int(movement.index) > 1:
			for owner_id: String in game.state.data.heroes:
				var warlord: Dictionary = game.state.data.heroes[owner_id]
				if owner_id == movement.actor_id or warlord.class_id != "warlord" or warlord.flags.get("challenge_used", false) or movement.declined_challenges.has(owner_id): continue
				if Hex.distance(hero.hex, warlord.hex) == 1 and Hex.distance(next_hex, warlord.hex) > 1:
					game.state.data.pending_reaction = {"kind": "challenge", "actor_id": owner_id, "choices": ["accept", "decline"], "moving_id": movement.actor_id, "stop_hex": hero.hex, "next_hex": next_hex}
					game._emit("ReactionWindowOpened", owner_id, game.state.data.pending_reaction)
					return
		hero.hex = next_hex
		movement.path.append(next_hex)
		movement.index += 1
		game._discover(movement.actor_id)
		var triggered: bool = false
		for owner_id: String in game.state.data.traps.keys():
			var trap: Dictionary = game.state.data.traps[owner_id]
			if owner_id != movement.actor_id and trap.hex == next_hex:
				game.state.data.traps.erase(owner_id)
				game._modify_next_cycle(movement.actor_id, -2, "snare")
				game._emit("SnareTriggered", owner_id, {"target_id": movement.actor_id, "hex": next_hex, "initiative_modifier": -2, "movement_ended": true})
				triggered = true
				break
		if triggered:
			finish_move(game, "snare")
			return
	finish_move(game, "destination")

static func challenge_decision(game: RefCounted, choice: String) -> void:
	var reaction: Dictionary = game.state.data.pending_reaction
	var movement: Dictionary = game.state.data.pending_move
	game._emit("ReactionResolved", reaction.actor_id, {"kind": "challenge", "choice": choice, "moving_id": movement.actor_id})
	game.state.data.pending_reaction = {}
	if choice == "accept":
		game.state.data.heroes[reaction.actor_id].flags.challenge_used = true
		finish_move(game, "challenge")
	else:
		movement.declined_challenges.append(reaction.actor_id)
		resume_move(game)

static func finish_move(game: RefCounted, cause: String) -> void:
	var movement: Dictionary = game.state.data.pending_move
	var actor: String = movement.actor_id
	var hero: Dictionary = game.state.data.heroes[actor]
	var road_only: bool = true
	var road_edges: Dictionary = Movement.road_lookup(game.state.data.map)
	var actual_cost: int = 0
	for index: int in range(1, movement.path.size()):
		var entered: String = movement.path[index]
		var on_road: bool = road_edges.has(Movement.road_key(movement.path[index - 1], entered))
		road_only = road_only and on_road
		var terrain: String = game.state.data.map.hexes[entered].get("movement_terrain", game.state.data.map.hexes[entered].terrain)
		if movement.route.get("waived_hexes", []).has(entered) or entered == movement.route.get("ignored_hex", ""):
			actual_cost += 1
		elif terrain == "swamp": actual_cost = maxi(actual_cost + 1, 4 if road_only else int(hero.move))
		else: actual_cost += 2 if terrain == "forest" and not on_road and hero.class_id != "ranger" else 1
	game._emit("HeroMoved", actor, {"from": movement.origin, "to": hero.hex, "path": movement.path.duplicate(), "cost": actual_cost, "road_only": road_only, "stopped_by": cause, "requested_target": movement.target, "forced_march": movement.forced_march})
	var action: String = "special" if movement.forced_march else "move"
	game.state.data.pending_move = {}
	game._finish_action(actor, action)
