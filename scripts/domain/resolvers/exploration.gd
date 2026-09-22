extends RefCounted
## Content facade: exploration, equipment finds, imprecise class hints and the
## event lifecycle all stay on the authoritative command path.
const Hex = preload("res://scripts/domain/hex/hex.gd")
const World = preload("res://scripts/domain/resolvers/world_events.gd")
const Equipment = preload("res://scripts/domain/resolvers/equipment.gd")

static func initialize(game: RefCounted) -> void:
	World.initialize(game)
	game.state.data.pending_exploration = {}
	for hero: Dictionary in game.state.data.heroes.values(): hero.occult_hint = {"regions": []}
	for location: Dictionary in game.state.data.map.locations.values():
		if location.kind == "ruin":
			location.exhausted = false
			location.relic_available = true
	# Two Ruins and two Wraith camps form four reliable, contested Relic sources.
	var fourth: Dictionary = game.state.data.monsters.get("monster_4", {})
	if not fourth.is_empty():
		var profile: Dictionary = game.definitions.monsters.relic_wraith
		fourth.definition_id = profile.id
		fourth.name = profile.name
		fourth.hp = int(profile.hp)
		fourth.max_hp = int(profile.hp)
		fourth.attack = int(profile.attack)
		fourth.defence = int(profile.defence)

static func world_phase(game: RefCounted) -> void:
	World.world_phase(game)

static func resolution_expiry(game: RefCounted) -> void:
	World.resolution_expiry(game)

static func explore_options(game: RefCounted, player_id: String) -> Dictionary:
	if not game.state.data.heroes.has(player_id): return {}
	var hero: Dictionary = game.state.data.heroes[player_id]
	var loot: Dictionary = game.state.data.ground_loot.get(hero.hex, {})
	if int(loot.get("gold", 0)) > 0 or not loot.get("relics", []).is_empty():
		return {"kind": "loot", "hex": hero.hex, "gold": loot.get("gold", 0), "relics": loot.get("relics", []).size(), "alternatives_available": false, "description": "Collect all unclaimed Gold and Relics here."}
	var location_id: String = game.state.data.map.hexes[hero.hex].location_id
	var location: Dictionary = game.state.data.map.locations.get(location_id, {})
	if location.is_empty() or location.kind != "ruin" or location.get("exhausted", false): return {}
	if not location.discovered_by.has(player_id): return {}
	var rewards: Dictionary = game.definitions.rewards.ruin_rewards
	var total := 0
	for item: Dictionary in rewards.values(): total += int(item.weight)
	var odds: Dictionary = {}
	for id: String in rewards:
		odds[id] = {"name": rewards[id].name, "weight": rewards[id].weight, "out_of": total, "description": rewards[id].description}
	return {"kind": "ruin", "location_id": location_id, "guaranteed_relics": 1, "alternatives_available": int(hero.fate) >= 2, "alternatives_cost": 2, "rewards": odds, "dark_bargain": hero.class_id == "cultist" and int(hero.hp) > 2, "description": "Claim the Ruin's Relic and a seeded bonus reward. Spend 2 Fate to choose between two distinct bonuses."}

static func validate_explore(game: RefCounted, command: Dictionary) -> Dictionary:
	var player: Variant = command.get("player_id", "")
	if not player is String or not game.state.data.heroes.has(player): return game._reject("UNKNOWN_PLAYER", "Exploration requires a known hero.")
	var options := explore_options(game, player)
	if options.is_empty(): return game._reject("NOT_EXPLORABLE", "Stand on an unexhausted discovered Ruin or unclaimed ground loot.")
	if not command.get("use_fate", false) is bool: return game._reject("INVALID_FATE_CHOICE", "Exploration Fate choice must be boolean.")
	var dark: bool = command.get("special_id", "") == "dark_bargain"
	if dark and (options.kind != "ruin" or not options.get("dark_bargain", false)):
		return game._reject("DARK_BARGAIN_UNAVAILABLE", "Cultist must explore a fresh Ruin with more than 2 Health.")
	if command.get("use_fate", false) and (options.kind != "ruin" or not options.alternatives_available):
		return game._reject("INSUFFICIENT_FATE", "Exploration alternatives require a Ruin and 2 Fate.")
	return {"is_valid": true}

static func begin_explore(game: RefCounted, player_id: String, dark_bargain: bool = false, use_fate: bool = false) -> void:
	var options := explore_options(game, player_id)
	var hero: Dictionary = game.state.data.heroes[player_id]
	if options.kind == "loot":
		var loot: Dictionary = game.state.data.ground_loot[hero.hex]
		hero.gold += int(loot.get("gold", 0))
		for relic: String in loot.get("relics", []): hero.relics.append(relic)
		game._emit("GroundLootCollected", player_id, {"hex": hero.hex, "gold": loot.get("gold", 0), "relics": loot.get("relics", []).duplicate()})
		game.state.data.ground_loot.erase(hero.hex)
		_update_all_hints(game)
		game._finish_action(player_id, "explore")
		return
	var pending := {"player_id": player_id, "kind": "ruin", "location_id": options.location_id, "hex": hero.hex, "choices": {}, "dark_bargain": dark_bargain, "action": "special" if dark_bargain else "explore"}
	var first := _draw_reward(game, player_id, [])
	pending.choices[first] = game.definitions.rewards.ruin_rewards[first].duplicate(true)
	if use_fate:
		hero.fate -= 2
		game._emit("FateSpent", player_id, {"cause": "exploration_alternatives", "amount": 2, "after": hero.fate})
		var second := _draw_reward(game, player_id, [first])
		pending.choices[second] = game.definitions.rewards.ruin_rewards[second].duplicate(true)
		game.state.data.pending_exploration = pending
		game._emit("ExplorationChoicesOffered", player_id, {"location_id": options.location_id, "choices": pending.choices.duplicate(true), "guaranteed_relics": 1, "dark_bargain": dark_bargain})
	else:
		_complete(game, pending, first)

static func exploration_legal(game: RefCounted, player_id: String) -> Dictionary:
	var pending: Dictionary = game.state.data.pending_exploration
	if pending.is_empty() or pending.player_id != player_id: return {}
	return {"choose_reward": {"choices": pending.choices.duplicate(true), "location_id": pending.location_id}}

static func validate_choice(game: RefCounted, command: Dictionary) -> Dictionary:
	var pending: Dictionary = game.state.data.pending_exploration
	if pending.is_empty(): return game._reject("NO_PENDING_EXPLORATION", "No exploration choice is pending.")
	if command.get("type", "") != "choose_reward" or command.get("player_id", "") != pending.player_id:
		return game._reject("EXPLORATION_DECISION_REQUIRED", "Only the exploring hero may choose the pending reward.")
	if not command.get("choice", "") is String or not pending.choices.has(command.choice):
		return game._reject("INVALID_REWARD_CHOICE", "Choose one of the revealed rewards.")
	return {"is_valid": true}

static func choose(game: RefCounted, command: Dictionary) -> void:
	var pending: Dictionary = game.state.data.pending_exploration.duplicate(true)
	game.state.data.pending_exploration = {}
	_complete(game, pending, command.choice)

static func _draw_reward(game: RefCounted, player_id: String, excluded: Array) -> String:
	var table: Dictionary = game.definitions.rewards.ruin_rewards
	var ids: Array = table.keys()
	ids.sort()
	var total := 0
	for id: String in ids:
		if not excluded.has(id): total += int(table[id].weight)
	var roll: Dictionary = game._draw("exploration", 1, total, player_id, "ruin_bonus_reward")
	var ticket := int(roll.result)
	for id: String in ids:
		if excluded.has(id): continue
		ticket -= int(table[id].weight)
		if ticket <= 0: return id
	return ""

static func _complete(game: RefCounted, pending: Dictionary, reward_id: String) -> void:
	var player_id: String = pending.player_id
	var hero: Dictionary = game.state.data.heroes[player_id]
	var location: Dictionary = game.state.data.map.locations[pending.location_id]
	var reward: Dictionary = game.definitions.rewards.ruin_rewards[reward_id]
	var before := {"gold": hero.gold, "power": hero.power, "hp": hero.hp}
	if pending.dark_bargain:
		hero.hp -= int(game.definitions.rewards.dark_bargain.health_cost)
		hero.power = mini(int(game.definitions.rules.power_cap), int(hero.power) + int(game.definitions.rewards.dark_bargain.power_bonus))
		game._emit("DarkBargainAccepted", player_id, {"health_cost": 2, "power_gain": int(hero.power) - int(before.power), "location_id": location.id})
		game._class_fate(player_id, "dark_bargain")
	hero.gold += int(reward.gold)
	hero.power = mini(int(game.definitions.rules.power_cap), int(hero.power) + int(reward.power))
	hero.hp = mini(int(hero.max_hp), int(hero.hp) + int(reward.healing))
	if hero.class_id == "ranger": hero.gold += int(game.definitions.rewards.ranger_affinity.gold_bonus)
	var found_upgrade: String = reward.upgrade_id
	if not found_upgrade.is_empty():
		if hero.upgrades.size() < 3 and not hero.upgrades.has(found_upgrade):
			hero.upgrades.append(found_upgrade)
			game._emit("EquipmentFound", player_id, {"upgrade_id": found_upgrade, "location_id": location.id})
		else:
			hero.gold += int(Equipment.definitions()[found_upgrade].cost)
	var relic_id := "relic_" + str(location.id)
	hero.relics.append(relic_id)
	location.exhausted = true
	location.relic_available = false
	game._emit("RelicCollected", player_id, {"relic_id": relic_id, "source": location.id, "hex": location.hex})
	game._emit("RuinExplored", player_id, {"location_id": location.id, "reward_id": reward_id, "reward": reward.duplicate(true), "ranger_affinity": hero.class_id == "ranger", "dark_bargain": pending.dark_bargain, "before": before, "after": {"gold": hero.gold, "power": hero.power, "hp": hero.hp}, "exhausted": true})
	game._discover(player_id)
	_update_all_hints(game)
	game._finish_action(player_id, pending.action)

static func update_hints(game: RefCounted, player_id: String) -> void:
	var hero: Dictionary = game.state.data.heroes[player_id]
	if hero.class_id != "cultist": return
	var regions: Array[String] = []
	for location: Dictionary in game.state.data.map.locations.values():
		if location.discovered_by.has(player_id) or Hex.distance(hero.hex, location.hex) > 3: continue
		var has_relic: bool = location.kind == "ruin" and not location.get("exhausted", false)
		if location.kind == "monster_camp":
			for monster: Dictionary in game.state.data.monsters.values():
				if monster.camp_id == location.id and int(monster.hp) > 0 and int(game.definitions.monsters[monster.definition_id].reward.get("relics", 0)) > 0: has_relic = true
		if has_relic:
			var region: String = game.state.data.map.hexes[location.hex].region
			if not regions.has(region): regions.append(region)
	regions.sort()
	var hint := {"regions": regions}
	if hero.get("occult_hint", {}) != hint:
		hero.occult_hint = hint
		game._emit("OccultSenseChanged", player_id, hint.duplicate(true), "owner_only")

static func _update_all_hints(game: RefCounted) -> void:
	var ids: Array = game.state.data.heroes.keys()
	ids.sort()
	for player_id: String in ids: update_hints(game, player_id)
