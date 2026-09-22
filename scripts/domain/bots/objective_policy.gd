extends RefCounted
## Public-information goal selection for complete local matches. No state mutation or RNG.

const Hex = preload("res://scripts/domain/hex/hex.gd")
const Movement = preload("res://scripts/domain/resolvers/movement.gd")

static func route(hero: Dictionary, preference: String = "") -> String:
	if not preference.is_empty(): return preference
	match str(hero["class_id"]):
		"warlord": return "conquest"
		"merchant": return "dominion"
	return "ascension"

static func choose(state: Dictionary, player: String, legal: Dictionary, progress: Dictionary, preference: String = "") -> Dictionary:
	var hero: Dictionary = state["heroes"][player]
	var goal: String = route(hero, preference)
	if goal == "passive": return {"type": "pass", "player_id": player}
	for command_type: String in ["complete_ritual", "begin_ritual"]:
		if legal.has(command_type): return {"type": command_type, "player_id": player}
	if state.get("commitments", {}).has(player) and legal.has("capture"):
		return {"type": "capture", "player_id": player}
	var specials: Dictionary = legal.get("special", {}).get("choices", {})
	if specials.has("rest") and int(hero["hp"]) <= int(hero["max_hp"]) - 3:
		return {"type": "special", "player_id": player, "special_id": "rest"}
	if legal.has("explore"):
		# Sources guarantee a Relic; do not spend scarce Fate on optional bonus rewards.
		return {"type": "explore", "player_id": player}
	var location: Dictionary = _location_at(state, hero["hex"])
	if legal.has("capture") and _useful_capture(location, goal, state, player, progress):
		return {"type": "capture", "player_id": player}
	var trade: Dictionary = legal.get("trade", {}).get("choices", {})
	if goal == "dominion" and trade.has("power_to_gold") and int(hero["gold"]) < 15:
		return {"type": "trade", "player_id": player, "direction": "power_to_gold"}
	var targets: Dictionary = legal.get("move", {}).get("targets", {})
	var destinations: Array[Dictionary] = _goals(state, player, goal, progress)
	var attacks: Dictionary = legal.get("attack", {}).get("targets", {})
	var desired: Dictionary = _select_goal(state, hero, destinations)
	var obstruction: String = _obstructing_enemy(state, player, desired, attacks)
	if not obstruction.is_empty(): return {"type": "attack", "player_id": player, "target_id": obstruction}
	# A visible nearby ritual/claim deserves immediate interference, without abandoning
	# a completed claim merely to walk toward an opponent who cannot be reached in time.
	var threat: String = _adjacent_threat(state, player, attacks)
	if not threat.is_empty(): return {"type": "attack", "player_id": player, "target_id": threat}
	if not desired.is_empty():
		if str(desired["hex"]) == str(hero["hex"]):
			if legal.has("capture"): return {"type": "capture", "player_id": player}
			if goal == "dominion" and trade.has("power_to_gold"):
				return {"type": "trade", "player_id": player, "direction": "power_to_gold"}
			return {"type": "pass", "player_id": player}
		var marching: Dictionary = specials.get("forced_march", {}).get("targets", {})
		if not marching.is_empty() and int(hero["power"]) >= 2:
			var marched: String = destination(state, player, desired["hex"], marching)
			if not marched.is_empty(): return {"type": "special", "player_id": player, "special_id": "forced_march", "target": marched}
		var moved: String = destination(state, player, desired["hex"], targets)
		if not moved.is_empty(): return {"type": "move", "player_id": player, "target": moved}
	if bool(progress.get(goal, {}).get("eligible", false)):
		return {"type": "pass", "player_id": player}
	var frontier: String = _frontier(state, player, targets)
	if not frontier.is_empty(): return {"type": "move", "player_id": player, "target": frontier}
	if not attacks.is_empty():
		var enemy_ids: Array = attacks.keys()
		enemy_ids.sort()
		return {"type": "attack", "player_id": player, "target_id": enemy_ids[0]}
	return {"type": "pass", "player_id": player}

static func _useful_capture(location: Dictionary, goal: String, state: Dictionary, player: String, progress: Dictionary) -> bool:
	var kind: String = location.get("kind", "")
	if goal == "conquest" and kind in ["ancient_tower", "worldspire"]: return true
	if goal == "dominion" and kind == "settlement": return true
	if goal == "dominion" and int(progress.get("dominion", {}).get("settlements", 0)) >= 2 and not bool(progress.get("dominion", {}).get("connected", false)):
		return kind in ["minor_tower", "ancient_tower", "worldspire"]
	# A small early income base supports preparations and Fate without trapping the
	# policy in repeated enemy-Minor-Tower exchanges unrelated to its victory route.
	return kind == "minor_tower" and str(location.get("owner_id", "")).is_empty() and state["heroes"][player]["controlled_locations"].is_empty()

static func _goals(state: Dictionary, player: String, goal: String, progress: Dictionary) -> Array[Dictionary]:
	var hero: Dictionary = state["heroes"][player]
	var goals: Array[Dictionary] = []
	if goal == "ascension" and hero["relics"].size() >= 3:
		return [{"hex": "0,0", "priority": 0}]
	if goal == "dominion" and bool(progress.get("dominion", {}).get("eligible", false)):
		return []
	if goal == "conquest" and bool(progress.get("conquest", {}).get("eligible", false)):
		return []
	for location: Dictionary in state["map"]["locations"].values():
		var kind: String = location["kind"]
		var visible: bool = kind in ["ancient_tower", "worldspire"] or location.get("discovered_by", []).has(player)
		if not visible: continue
		if goal == "conquest" and kind in ["ancient_tower", "worldspire"] and location.get("owner_id", "") != player:
			goals.append({"hex": location["hex"], "priority": 0, "location_id": location["id"]})
		elif goal == "dominion" and kind == "settlement" and location.get("owner_id", "") != player:
			goals.append({"hex": location["hex"], "priority": 0, "location_id": location["id"]})
		elif goal == "ascension" and kind == "ruin" and not bool(location.get("exhausted", false)):
			goals.append({"hex": location["hex"], "priority": 0, "location_id": location["id"]})
		elif goal == "ascension" and kind == "monster_camp" and not bool(location.get("cleared", false)):
			for monster: Dictionary in state.get("monsters", {}).values():
				if monster.get("camp_id", "") == location["id"] and monster.get("definition_id", "") == "relic_wraith" and int(monster.get("hp", 0)) > 0:
					goals.append({"hex": monster["hex"], "priority": 5, "target_id": monster["id"]})
	if goal == "ascension":
		for hex_id: String in state.get("ground_loot", {}):
			if state["ground_loot"][hex_id].get("relics", []).is_empty(): continue
			# Drops are public events, hence their marked hexes are authorized observations.
			goals.append({"hex": hex_id, "priority": -3})
		if goals.is_empty():
			for enemy: Dictionary in state["heroes"].values():
				if enemy["id"] != player and not enemy.get("relics", []).is_empty():
					goals.append({"hex": enemy["hex"], "priority": 15, "target_id": enemy["id"]})
	if goal == "dominion" and int(progress.get("dominion", {}).get("settlements", 0)) >= 2:
		if not bool(progress.get("dominion", {}).get("connected", false)):
			goals.append_array(_road_blockers(state, player))
		if goals.is_empty() and int(hero["gold"]) < 15:
			for location: Dictionary in state["map"]["locations"].values():
				if location["kind"] == "settlement" and location.get("owner_id", "") == player:
					goals.append({"hex": location["hex"], "priority": 0})
	return goals

static func _road_blockers(state: Dictionary, player: String) -> Array[Dictionary]:
	var settlements: Array[String] = []
	for location: Dictionary in state["map"]["locations"].values():
		if location["kind"] == "settlement" and location.get("owner_id", "") == player: settlements.append(location["hex"])
	if settlements.size() < 2: return []
	settlements.sort()
	var graph: Dictionary = {}
	for edge: Array in state["map"].get("roads", []):
		if not graph.has(edge[0]): graph[edge[0]] = []
		if not graph.has(edge[1]): graph[edge[1]] = []
		graph[edge[0]].append(edge[1])
		graph[edge[1]].append(edge[0])
	var frontier: Array[String] = [settlements[0]]
	var paths: Dictionary = {settlements[0]: [settlements[0]]}
	while not frontier.is_empty():
		var hex_id: String = frontier.pop_front()
		if hex_id == settlements[1]: break
		var neighbors: Array = graph.get(hex_id, [])
		neighbors.sort()
		for next_hex: String in neighbors:
			if paths.has(next_hex): continue
			paths[next_hex] = paths[hex_id].duplicate()
			paths[next_hex].append(next_hex)
			frontier.append(next_hex)
	var result: Array[Dictionary] = []
	for hex_id: String in paths.get(settlements[1], []):
		var location: Dictionary = _location_at(state, hex_id)
		if not location.is_empty() and not str(location.get("owner_id", "")).is_empty() and location["owner_id"] != player:
			result.append({"hex": hex_id, "priority": 0, "location_id": location["id"]})
	return result

static func _select_goal(state: Dictionary, hero: Dictionary, goals: Array[Dictionary]) -> Dictionary:
	var costs: Dictionary = Movement.travel_costs(state["map"], hero["hex"])
	var chosen: Dictionary = {}
	var best: int = 1000000
	for goal: Dictionary in goals:
		var score: int = int(costs.get(goal["hex"], 100000)) * 10 + int(goal.get("priority", 0))
		if score < best or (score == best and str(goal["hex"]) < str(chosen.get("hex", "~"))):
			best = score
			chosen = goal
	return chosen

static func _obstructing_enemy(state: Dictionary, player: String, goal: Dictionary, targets: Dictionary) -> String:
	if goal.is_empty(): return ""
	var goal_hex: String = goal["hex"]
	var names: Array = targets.keys()
	names.sort()
	for target: String in names:
		if str(targets[target].get("hex", "")) == goal_hex: return target
	return ""

static func _adjacent_threat(state: Dictionary, player: String, targets: Dictionary) -> String:
	var names: Array = targets.keys()
	names.sort()
	for enemy: String in names:
		if not state["heroes"].has(enemy): continue
		if state.get("rituals", {}).has(enemy): return enemy
		var commitment: Dictionary = state.get("commitments", {}).get(enemy, {})
		if commitment.get("kind", "") == "ritual": return enemy
		for claim: Dictionary in state.get("victory_claims", {}).values():
			if claim.get("player_id", "") == enemy: return enemy
	return ""

static func destination(state: Dictionary, player: String, goal_hex: String, targets: Dictionary) -> String:
	var candidates: Array = targets.keys()
	candidates.sort()
	var best: int = 1000000
	var selected: String = ""
	for candidate: String in candidates:
		var costs: Dictionary = Movement.travel_costs(state["map"], candidate)
		var score: int = int(costs.get(goal_hex, 100000)) * 10
		# Equivalent progress prefers a cheaper legal path, then stable hex order.
		score += int(targets[candidate].get("cost", 0))
		if score < best:
			best = score
			selected = candidate
	return selected

static func _frontier(state: Dictionary, player: String, targets: Dictionary) -> String:
	var seen: Dictionary = {}
	for value: String in Hex.range_keys(state["heroes"][player]["sanctuary"], 2): seen[value] = true
	for event: Dictionary in state["events"]:
		if event.get("actor_id", "") != player: continue
		if event.get("type", "") not in ["HeroMoved", "HeroDisplaced", "HeroRecovered"]: continue
		var path: Array = event["data"].get("path", [event["data"].get("to", "")])
		for value: String in path:
			if value.is_empty(): continue
			for nearby: String in Hex.range_keys(value, 2): seen[nearby] = true
	var best: int = -1000000
	var selected: String = ""
	var candidates: Array = targets.keys()
	candidates.sort()
	for candidate: String in candidates:
		var discoveries: int = 0
		for nearby: String in Hex.range_keys(candidate, 2):
			if state["map"]["hexes"].has(nearby) and not seen.has(nearby): discoveries += 1
		var score: int = discoveries * 10 - int(targets[candidate].get("cost", 0))
		if score > best:
			best = score
			selected = candidate
	return selected

static func _location_at(state: Dictionary, hex_id: String) -> Dictionary:
	var location_id: String = state["map"]["hexes"].get(hex_id, {}).get("location_id", "")
	return state["map"]["locations"].get(location_id, {})
