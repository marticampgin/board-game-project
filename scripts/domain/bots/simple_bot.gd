extends RefCounted
## A deterministic development policy. It proposes ordinary commands and never mutates rules.
## Decisions use public hero stats, discovered locations, legal targets and revealed combat dice.
## Opponents' plans, sealed stances and hidden preparations are never inspected.

const Movement = preload("res://scripts/domain/resolvers/movement.gd")
const Hex = preload("res://scripts/domain/hex/hex.gd")
const Objectives = preload("res://scripts/domain/bots/objective_policy.gd")

static func choose(rules: RefCounted, preferences: Dictionary = {}) -> Dictionary:
	var state: Dictionary = rules.snapshot()
	if state["phase"] == "victory" or not state.get("victory", {}).is_empty(): return {}
	var players: Array = state["heroes"].keys()
	players.sort()
	var options: Dictionary = {}
	for player: String in players:
		options[player] = rules.legal_actions(player)
	# A response belongs to the eligible participant, which need not be the scheduled actor.
	for player: String in players:
		var legal: Dictionary = options[player]
		var response: Dictionary = _window_choice(state, player, legal)
		if not response.is_empty():
			return response
	if state["phase"] in ["world", "initiative", "bonus", "resolution"]:
		return {"type": "advance"}
	if state["phase"] == "planning":
		for player: String in players:
			var legal: Dictionary = options[player]
			if legal.has("submit_plan") and not state["plans"].has(player):
				return {"type": "submit_plan", "player_id": player, "plan": _plan(state, player, legal["submit_plan"], str(preferences.get(player, "")))}
			if legal.has("ready"):
				return {"type": "ready", "player_id": player}
		return {}
	var actor: String = rules.current_actor()
	if actor.is_empty() or not options.has(actor):
		return {}
	if state.has("victory"):
		return Objectives.choose(state, actor, options[actor], rules.victory_progress(actor), str(preferences.get(actor, "")))
	return _action(state, actor, options[actor])

static func _window_choice(state: Dictionary, player: String, legal: Dictionary) -> Dictionary:
	var hero: Dictionary = state["heroes"][player]
	if legal.has("choose_reward"):
		var choices: Dictionary = legal["choose_reward"].get("choices", {})
		var ids: Array = choices.keys()
		ids.sort()
		var selected: String = ""
		var best: int = -100000
		for reward_id: String in ids:
			var reward: Dictionary = choices[reward_id]
			var score: int = int(reward.get("relics", 0)) * 100 + int(reward.get("gold", 0)) * 3 + int(reward.get("power", 0)) * 2 + int(reward.get("fate", 0)) * 2
			if score > best:
				best = score
				selected = reward_id
		if not selected.is_empty(): return {"type": "choose_reward", "player_id": player, "choice": selected}
	if legal.has("resolve_reaction"):
		var reaction: Dictionary = state.get("pending_reaction", {})
		var accept: bool = str(reaction.get("kind", "")) == "challenge"
		if reaction.get("kind", "") in ["bribe_offer", "bribe_response"]:
			# A wounded Merchant offers; a wounded attacker accepts. Otherwise keep the duel.
			accept = int(hero["hp"]) * 2 <= int(hero["max_hp"])
		var choice: String = "accept" if accept else "decline"
		var choices: Array = legal["resolve_reaction"].get("choices", [])
		if not choices.has(choice):
			choice = str(choices[0]) if not choices.is_empty() else "decline"
		return {"type": "resolve_reaction", "player_id": player, "choice": choice}
	if legal.has("choose_stance"):
		var stance: String = "guard" if int(hero["hp"]) * 2 <= int(hero["max_hp"]) else "assault"
		var choices: Array = legal["choose_stance"].get("choices", ["guard", "assault"])
		if not choices.has(stance):
			stance = str(choices[0])
		return {"type": "choose_stance", "player_id": player, "stance": stance}
	if legal.has("decline_fate"):
		var pending: Dictionary = state.get("pending_combat", {})
		var role: String = "attacker" if pending.get("attacker_id", "") == player else "defender"
		var dice: Dictionary = pending.get("dice", {})
		var value: Variant = dice.get(role, dice.get(player, 6))
		var die: int = int(value.get("result", 6)) if value is Dictionary else int(value)
		return {"type": "spend_fate" if legal.has("spend_fate") and die <= 2 else "decline_fate", "player_id": player}
	if legal.has("displace"):
		var choices: Array = legal["displace"].get("targets", {}).keys()
		choices.sort()
		var destination: String = ""
		var best_safety: int = -1
		for target: String in choices:
			var closest_enemy: int = 1000
			for enemy: String in state["heroes"]:
				if enemy != player:
					closest_enemy = mini(closest_enemy, Hex.distance(target, state["heroes"][enemy]["hex"]))
			if closest_enemy > best_safety:
				best_safety = closest_enemy
				destination = target
		if not destination.is_empty():
			return {"type": "displace", "player_id": player, "target": destination}
	return {}

static func _plan(state: Dictionary, player: String, options: Dictionary, preference: String = "") -> Dictionary:
	var hero: Dictionary = state["heroes"][player]
	if preference == "passive": return {}
	var plan: Dictionary = {}
	if bool(options.get("initiative_push", false)) and int(hero["fate"]) >= 4:
		plan["initiative_push"] = true
	var snare_options: Variant = options.get("snare_targets", {})
	var snares: Array = snare_options.keys() if snare_options is Dictionary else snare_options
	if hero["class_id"] == "ranger" and not snares.is_empty():
		snares.sort()
		var best: String = str(snares[0])
		var nearest: int = 100000
		for target: String in snares:
			for enemy: String in state["heroes"]:
				if enemy == player: continue
				var distance: int = Hex.distance(target, state["heroes"][enemy]["hex"])
				if distance < nearest:
					nearest = distance
					best = target
		plan["snare"] = best
	var hex_options: Variant = options.get("prepared_hex_targets", {})
	var hex_targets: Array = hex_options.keys() if hex_options is Dictionary else hex_options
	if hero["class_id"] == "cultist" and not hex_targets.is_empty():
		hex_targets.sort()
		var target: String = str(hex_targets[0])
		for enemy: String in hex_targets:
			if int(state["heroes"][enemy]["attack"]) > int(state["heroes"][target]["attack"]): target = enemy
		plan["prepared_hex"] = target
	var purchases: Dictionary = options.get("purchases", {})
	var owned: Array = hero.get("upgrades", [])
	var keep_gold: int = 15 if Objectives.route(hero, preference) == "dominion" else 2
	var available: int = int(hero["gold"]) - keep_gold
	var selected: Array[String] = []
	var priorities: Array[String] = ["iron_weapon", "reinforced_armor", "trail_boots", "ward_stone", "lucky_charm", "scout_lens"]
	for upgrade_id: String in priorities:
		if not purchases.has(upgrade_id) or owned.has(upgrade_id): continue
		var cost: int = int(purchases[upgrade_id].get("cost", 4))
		if cost > available or selected.size() >= int(options.get("slots", 0)): continue
		available -= cost
		selected.append(upgrade_id)
	if not selected.is_empty(): plan["purchases"] = selected
	return plan

static func _action(state: Dictionary, player: String, legal: Dictionary) -> Dictionary:
	var hero: Dictionary = state["heroes"][player]
	var specials: Dictionary = legal.get("special", {}).get("choices", {})
	if specials.has("rest") and int(hero["hp"]) <= int(hero["max_hp"]) - 3:
		return {"type": "special", "player_id": player, "special_id": "rest"}
	if legal.has("capture"):
		return {"type": "capture", "player_id": player}
	if legal.has("upgrade"):
		return {"type": "upgrade", "player_id": player}
	var enemies: Array = legal.get("attack", {}).get("targets", {}).keys()
	if not enemies.is_empty():
		enemies.sort()
		var chosen: String = str(enemies[0])
		var lowest: int = 100000
		for enemy: String in enemies:
			var victim: Dictionary = state["heroes"].get(enemy, state.get("monsters", {}).get(enemy, {}))
			var score: int = int(victim.get("hp", 8)) + int(victim.get("defence", 3))
			if score < lowest:
				lowest = score
				chosen = enemy
		return {"type": "attack", "player_id": player, "target_id": chosen}
	var targets: Dictionary = legal.get("move", {}).get("targets", {})
	if specials.has("forced_march"):
		var marching: Dictionary = specials["forced_march"].get("targets", {})
		if not marching.is_empty() and int(hero["power"]) >= 2:
			var target: String = _destination(state, player, marching)
			if not target.is_empty():
				return {"type": "special", "player_id": player, "special_id": "forced_march", "target": target}
	var destination: String = _destination(state, player, targets)
	if not destination.is_empty():
		return {"type": "move", "player_id": player, "target": destination}
	if legal.has("pass"):
		return {"type": "pass", "player_id": player}
	return {}

static func _destination(state: Dictionary, player: String, targets: Dictionary) -> String:
	var choices: Array = targets.keys()
	choices.sort()
	if choices.is_empty(): return ""
	var chosen: String = str(choices[0])
	var best: int = 1000000
	for target: String in choices:
		var distances: Dictionary = Movement.travel_costs(state["map"], target)
		var score: int = 100000
		for location: Dictionary in state["map"]["locations"].values():
			var kind: String = location["kind"]
			if kind not in ["ancient_tower", "worldspire"] and not location.get("discovered_by", []).has(player): continue
			if kind not in ["minor_tower", "ancient_tower", "worldspire"] or location.get("owner_id", "") == player: continue
			var cost: int = int(distances.get(location["hex"], 100000)) * 10
			cost += 3 if kind in ["ancient_tower", "worldspire"] else 0
			cost += 15 if not str(location.get("owner_id", "")).is_empty() else 0
			score = mini(score, cost)
		if score < best:
			best = score
			chosen = target
	return chosen
