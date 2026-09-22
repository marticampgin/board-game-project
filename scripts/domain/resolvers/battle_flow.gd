extends RefCounted
## Explicit combat windows pause the declared action without removing the
## defender's scheduled action. Pure arithmetic lives in combat.gd.
const Hex = preload("res://scripts/domain/hex/hex.gd")
const Movement = preload("res://scripts/domain/resolvers/movement.gd")
const Combat = preload("res://scripts/domain/resolvers/combat.gd")
const Equipment = preload("res://scripts/domain/resolvers/equipment.gd")

static func targets(game: RefCounted, actor: String) -> Dictionary:
	var result: Dictionary = {}
	var hero: Dictionary = game.state.data.heroes[actor]
	for target_id: String in game.state.data.heroes:
		var other: Dictionary = game.state.data.heroes[target_id]
		if actor != target_id and not other.statuses.has("recovering") and Hex.distance(hero.hex, other.hex) == 1:
			result[target_id] = {"hex": other.hex, "name": other.name, "kind": "hero", "hp": other.hp, "defence": other.defence}
	for target_id: String in game.state.data.monsters:
		var monster: Dictionary = game.state.data.monsters[target_id]
		if int(monster.hp) > 0 and Hex.distance(hero.hex, monster.hex) == 1:
			result[target_id] = {"hex": monster.hex, "name": monster.name, "kind": "monster", "hp": monster.hp, "defence": monster.defence}
	return result

static func legal_window(game: RefCounted, player_id: String) -> Dictionary:
	var battle: Dictionary = game.state.data.pending_combat
	if battle.is_empty():
		return {}
	match str(battle.stage):
		"stances":
			if player_id not in [battle.attacker_id, battle.defender_id] or battle.stances.has(player_id):
				return {}
			var choices: Array[String] = ["assault", "guard", "counter"]
			if int(game.state.data.heroes[player_id].fate) >= 1:
				choices.append("trick")
			return {"choose_stance": {"choices": choices}}
		"fate_attacker", "fate_defender":
			var owner: String = battle.attacker_id if battle.stage == "fate_attacker" else battle.defender_id
			if owner != player_id:
				return {}
			var actions: Dictionary = {"decline_fate": {}}
			if int(game.state.data.heroes[player_id].fate) >= 1:
				actions.spend_fate = {"cost": 1, "die": battle.dice.attacker if battle.stage == "fate_attacker" else battle.dice.defender}
			return actions
		"displacement":
			if player_id == battle.defender_id:
				return {"displace": {"targets": displacement_targets(game, battle.defender_id)}}
	return {}

static func validate_window(game: RefCounted, command: Dictionary) -> Dictionary:
	var actions: Dictionary = legal_window(game, command.player_id)
	if not actions.has(command.type):
		return game._reject("COMBAT_DECISION_REQUIRED", "Only the participant owning this combat window may decide.")
	if command.type == "choose_stance" and not actions.choose_stance.choices.has(command.get("stance", "")):
		return game._reject("INVALID_STANCE", "Choose an available stance; Trick requires one Fate.")
	if command.type == "displace" and not actions.displace.targets.has(command.get("target", "")):
		return game._reject("INVALID_DISPLACEMENT", "Choose an unoccupied adjacent walkable hex.")
	return {"is_valid": true}

static func declare(game: RefCounted, actor: String, target_id: String) -> void:
	var defender_kind: String = "hero" if game.state.data.heroes.has(target_id) else "monster"
	var target: Dictionary = game.state.data.heroes[target_id] if defender_kind == "hero" else game.state.data.monsters[target_id]
	var attacker: Dictionary = game.state.data.heroes[actor]
	if attacker.class_id == "warlord" and defender_kind == "hero":
		if _tower_count(game, target_id) > _tower_count(game, actor) or _equipped_tier(game, target) > _equipped_tier(game, attacker): game._class_fate(actor, "stronger_opponent")
	game.state.data.pending_combat = {
		"attacker_id": actor, "defender_id": target_id, "defender_kind": defender_kind,
		"stage": "stances", "stances": {}, "dice": {}, "calculation": {}, "rerolled": {},
		"modifiers": _modifiers(game, actor, target, defender_kind), "contested_hex": target.hex
	}
	var battle: Dictionary = game.state.data.pending_combat
	for owner_id: String in game.state.data.heroes:
		var prepared: Dictionary = game.state.data.heroes[owner_id].get("prepared_hex", {})
		if prepared.get("target_id", "") == actor:
			battle.modifiers.attacker_die_modifier -= 1
			game.state.data.heroes[owner_id].prepared_hex = {}
			game._emit("PreparedHexTriggered", owner_id, {"target_id": actor, "die_modifier": -1})
	game._emit("CombatStarted", actor, {"attacker_id": actor, "defender_id": target_id, "defender_kind": defender_kind, "hex": target.hex})
	if defender_kind == "hero" and target.class_id == "merchant" and int(target.gold) >= 2 and not target.flags.get("bribe_used", false):
		game.state.data.pending_reaction = {"kind": "bribe_offer", "actor_id": target_id, "choices": ["accept", "decline"], "attacker_id": actor, "cost": 2}
		game._emit("ReactionWindowOpened", target_id, game.state.data.pending_reaction)
	else:
		_open_stances(game)

static func _modifiers(game: RefCounted, attacker_id: String, defender: Dictionary, defender_kind: String) -> Dictionary:
	var attacker: Dictionary = game.state.data.heroes[attacker_id]
	var attack_parts: Dictionary = {}
	var defence_parts: Dictionary = {}
	var equipment_attack: int = Equipment.passive_bonus(attacker, "attack")
	if equipment_attack != 0: attack_parts.equipment = equipment_attack
	if defender_kind == "hero":
		var equipment_defence: int = Equipment.passive_bonus(defender, "defence")
		if equipment_defence != 0: defence_parts.equipment = equipment_defence
	if attacker.statuses.has("recovering"):
		attack_parts.recovering = -1
	if game.state.data.map.hexes[defender.hex].terrain == "forest":
		defence_parts.forest = 1
	var location_id: String = game.state.data.map.hexes[defender.hex].location_id
	var location: Dictionary = game.state.data.map.locations.get(location_id, {})
	if not location.is_empty() and location.kind in ["minor_tower", "ancient_tower", "worldspire"]:
		if attacker.class_id == "warlord" and not str(location.owner_id).is_empty() and location.owner_id != attacker_id:
			attack_parts.martial_presence = 1
		if defender_kind == "hero" and location.owner_id == defender.id:
			var tower_trait: Dictionary = game.definitions.tower_traits.get(location.trait, {})
			defence_parts.controlled_tower = int(game.definitions.rules.tower_owner_defence) + int(tower_trait.get("owner_defence", 0)) + (1 if int(location.level) >= 2 else 0)
	return {"attacker_modifier": _sum(attack_parts), "defender_modifier": _sum(defence_parts), "attacker_die_modifier": 0, "defender_die_modifier": 0, "attacker_modifiers": attack_parts, "defender_modifiers": defence_parts}

static func _tower_count(game: RefCounted, player_id: String) -> int:
	var count: int = 0
	for location_id: String in game.state.data.heroes[player_id].controlled_locations:
		if game.state.data.map.locations[location_id].kind in ["minor_tower", "ancient_tower", "worldspire"]: count += 1
	return count

static func _equipped_tier(game: RefCounted, hero: Dictionary) -> int:
	var tier: int = 0
	for upgrade_id: String in hero.upgrades:
		tier += int(game.definitions.upgrades[upgrade_id].get("tier", 1))
	return tier

static func _sum(parts: Dictionary) -> int:
	var total: int = 0
	for amount: int in parts.values(): total += amount
	return total

static func reaction(game: RefCounted, choice: String) -> void:
	var reaction_data: Dictionary = game.state.data.pending_reaction.duplicate(true)
	var battle: Dictionary = game.state.data.pending_combat
	game.state.data.pending_reaction = {}
	game._emit("ReactionResolved", reaction_data.actor_id, {"kind": reaction_data.kind, "choice": choice})
	var merchant: Dictionary = game.state.data.heroes[battle.defender_id]
	if reaction_data.kind == "bribe_offer":
		if choice == "accept":
			merchant.flags.bribe_used = true
			game.state.data.pending_reaction = {"kind": "bribe_response", "actor_id": battle.attacker_id, "choices": ["accept", "decline"], "merchant_id": battle.defender_id, "amount": 2}
			game._emit("ReactionWindowOpened", battle.attacker_id, game.state.data.pending_reaction)
		else:
			_open_stances(game)
	elif choice == "accept":
		merchant.gold -= 2
		game.state.data.heroes[battle.attacker_id].gold += 2
		game._emit("BribeAccepted", battle.attacker_id, {"merchant_id": battle.defender_id, "gold": 2})
		game._emit("CombatCanceled", battle.attacker_id, {"cause": "bribe", "action_consumed": true})
		_finish(game)
	else:
		battle.modifiers.defender_modifier += 1
		battle.modifiers.defender_modifiers.bribe_refused = 1
		game._emit("BribeRefused", battle.attacker_id, {"merchant_id": battle.defender_id, "defence_bonus": 1})
		_open_stances(game)

static func _open_stances(game: RefCounted) -> void:
	var battle: Dictionary = game.state.data.pending_combat
	battle.stage = "stances"
	game._emit("StanceWindowOpened", "", {"attacker_id": battle.attacker_id, "defender_id": battle.defender_id, "defender_kind": battle.defender_kind})

static func choose_stance(game: RefCounted, player_id: String, stance: String) -> void:
	var battle: Dictionary = game.state.data.pending_combat
	battle.stances[player_id] = stance
	game._emit("StanceChosen", player_id, {"submitted": true}, "owner_only")
	if not battle.stances.has(battle.attacker_id) or (battle.defender_kind == "hero" and not battle.stances.has(battle.defender_id)):
		return
	for hero_id: String in battle.stances:
		if battle.stances[hero_id] == "trick":
			game.state.data.heroes[hero_id].fate -= 1
			game._emit("FateSpent", hero_id, {"cause": "trick", "amount": 1, "after": game.state.data.heroes[hero_id].fate})
	if battle.defender_kind == "monster": battle.stances[battle.defender_id] = "none"
	game._emit("StancesRevealed", "", {"stances": battle.stances.duplicate()})
	battle.dice = {"attacker": game._draw("combat", 1, 6, battle.attacker_id, "combat").result, "defender": game._draw("combat", 1, 6, battle.defender_id, "combat").result}
	_update_calculation(game)
	_next_fate_window(game, true)

static func _update_calculation(game: RefCounted) -> void:
	var battle: Dictionary = game.state.data.pending_combat
	var attacker: Dictionary = game.state.data.heroes[battle.attacker_id]
	var defender: Dictionary = game.state.data.heroes[battle.defender_id] if battle.defender_kind == "hero" else game.state.data.monsters[battle.defender_id]
	battle.calculation = Combat.evaluate(attacker, defender, battle.stances[battle.attacker_id], battle.stances[battle.defender_id], int(battle.dice.attacker), int(battle.dice.defender), battle.modifiers)
	game._emit("CombatCalculationUpdated", battle.attacker_id, battle.calculation)

static func _next_fate_window(game: RefCounted, attacker_window: bool) -> void:
	var battle: Dictionary = game.state.data.pending_combat
	if attacker_window and int(game.state.data.heroes[battle.attacker_id].fate) >= 1:
		battle.stage = "fate_attacker"
		game._emit("FateWindowOpened", battle.attacker_id, {"side": "attacker", "cost": 1})
	elif battle.defender_kind == "hero" and int(game.state.data.heroes[battle.defender_id].fate) >= 1:
		battle.stage = "fate_defender"
		game._emit("FateWindowOpened", battle.defender_id, {"side": "defender", "cost": 1})
	else:
		_resolve(game)

static func fate_decision(game: RefCounted, player_id: String, reroll: bool) -> void:
	var battle: Dictionary = game.state.data.pending_combat
	var side: String = "attacker" if battle.stage == "fate_attacker" else "defender"
	if reroll:
		game.state.data.heroes[player_id].fate -= 1
		game._emit("FateSpent", player_id, {"cause": "combat_reroll", "amount": 1, "after": game.state.data.heroes[player_id].fate})
		var old: int = battle.dice[side]
		var rolled: int = game._draw("combat", 1, 6, player_id, "combat_reroll").result
		battle.dice[side] = Equipment.reroll_result(game, player_id, old, rolled)
		battle.rerolled[player_id] = true
		game._emit("CombatDieRerolled", player_id, {"before": old, "rolled": rolled, "after": battle.dice[side], "keeps_new": int(battle.dice[side]) == rolled})
		_update_calculation(game)
	else:
		game._emit("FateDeclined", player_id, {"side": side})
	if side == "attacker": _next_fate_window(game, false)
	else: _resolve(game)

static func _resolve(game: RefCounted) -> void:
	var battle: Dictionary = game.state.data.pending_combat
	var calculation: Dictionary = battle.calculation
	game._emit("CombatResolved", battle.attacker_id, {"attacker_id": battle.attacker_id, "defender_id": battle.defender_id, "calculation": calculation.duplicate(true)})
	if battle.defender_kind == "hero" and int(calculation.margin) > 0 and game.state.data.commitments.get(battle.defender_id, {}).get("kind", "") == "ancient_capture":
		game._cancel_commitment(battle.defender_id, "combat_contested")
	if battle.defender_kind == "hero" and bool(calculation.drop_gold):
		var defender: Dictionary = game.state.data.heroes[battle.defender_id]
		if int(defender.gold) > 0:
			defender.gold -= 1
			_drop(game, battle.contested_hex, "gold", 1)
			game._emit("GoldDropped", defender.id, {"hex": battle.contested_hex, "amount": 1, "cause": "severe_combat_loss"})
	var defender_downed: bool = false
	if int(calculation.defender_damage) > 0:
		if battle.defender_kind == "hero":
			defender_downed = damage_hero(game, battle.defender_id, int(calculation.defender_damage), "combat")
		else:
			var monster: Dictionary = game.state.data.monsters[battle.defender_id]
			monster.hp = maxi(0, int(monster.hp) - int(calculation.defender_damage))
			game._emit("MonsterDamaged", battle.attacker_id, {"monster_id": monster.id, "amount": calculation.defender_damage, "hp": monster.hp})
			if int(monster.hp) == 0: _defeat_monster(game, monster)
	if int(calculation.attacker_damage) > 0:
		damage_hero(game, battle.attacker_id, int(calculation.attacker_damage), "combat")
	if battle.defender_kind == "hero":
		if int(calculation.margin) >= 4: _loss_fate(game, battle.defender_id, "severe_combat_loss")
		elif int(calculation.margin) <= -4: _loss_fate(game, battle.attacker_id, "severe_combat_loss")
		if bool(calculation.displace) and not defender_downed:
			game._cancel_commitment(battle.defender_id, "contested")
			var destinations: Dictionary = displacement_targets(game, battle.defender_id)
			if destinations.is_empty():
				damage_hero(game, battle.defender_id, 1, "blocked_displacement")
			else:
				battle.stage = "displacement"
				game._emit("DisplacementRequired", battle.defender_id, {"targets": destinations})
				return
	_finish(game)

static func displacement_targets(game: RefCounted, player_id: String) -> Dictionary:
	var result: Dictionary = {}
	var origin: String = game.state.data.heroes[player_id].hex
	for candidate: String in Hex.neighbors(origin):
		if not Movement.is_walkable(game.state.data.map, candidate) or game._is_occupied(candidate) or not game._sanctuary_allowed(player_id, candidate): continue
		result[candidate] = {"hex": candidate}
	return result

static func displace(game: RefCounted, player_id: String, target: String) -> void:
	var hero: Dictionary = game.state.data.heroes[player_id]
	var origin: String = hero.hex
	hero.hex = target
	game._cancel_commitment(player_id, "displaced")
	game._emit("HeroDisplaced", player_id, {"from": origin, "to": target})
	game._discover(player_id)
	_finish(game)

static func damage_hero(game: RefCounted, player_id: String, amount: int, cause: String) -> bool:
	var hero: Dictionary = game.state.data.heroes[player_id]
	var before: int = hero.hp
	hero.hp = maxi(0, before - amount)
	game._emit("HeroDamaged", player_id, {"cause": cause, "amount": amount, "before": before, "after": hero.hp})
	if int(hero.hp) > 0: return false
	var defeat_hex: String = hero.hex
	hero.flags.downed_this_round = true
	game._emit("HeroDowned", player_id, {"hex": defeat_hex})
	if not hero.relics.is_empty():
		var relic: String = hero.relics.pop_back()
		_drop(game, defeat_hex, "relics", relic)
		game._emit("RelicDropped", player_id, {"hex": defeat_hex, "relic_id": relic})
	else:
		var lost: int = mini(2, int(hero.gold))
		hero.gold -= lost
		game._emit("GoldLost", player_id, {"amount": lost, "cause": "downed"})
	game._cancel_commitment(player_id, "downed")
	# Sanctuaries are reserved to their hero by ordinary movement, so recovery
	# always has a deterministic unoccupied destination.
	hero.hex = hero.sanctuary
	hero.hp = ceili(float(hero.max_hp) * 0.6)
	hero.statuses.recovering = {"until_world": int(game.state.data.round_number) + 1}
	game._emit("HeroRecovered", player_id, {"from": defeat_hex, "to": hero.hex, "hp": hero.hp, "attack_modifier": -1, "defence_modifier": -1, "untargetable": true})
	_loss_fate(game, player_id, "downed")
	return true

static func _loss_fate(game: RefCounted, player_id: String, cause: String) -> void:
	var hero: Dictionary = game.state.data.heroes[player_id]
	if hero.flags.get("loss_fate", false): return
	hero.flags.loss_fate = true
	game._gain_fate(player_id, 1, cause)

static func _drop(game: RefCounted, hex_id: String, resource: String, amount: Variant) -> void:
	if not game.state.data.ground_loot.has(hex_id): game.state.data.ground_loot[hex_id] = {"gold": 0, "relics": []}
	if resource == "gold": game.state.data.ground_loot[hex_id].gold += int(amount)
	else: game.state.data.ground_loot[hex_id].relics.append(amount)

static func _defeat_monster(game: RefCounted, monster: Dictionary) -> void:
	var actor: String = game.state.data.pending_combat.attacker_id
	var hero: Dictionary = game.state.data.heroes[actor]
	var reward: Dictionary = game.definitions.monsters[monster.definition_id].reward
	hero.gold += int(reward.get("gold", 0))
	hero.power = mini(int(game.definitions.rules.power_cap), int(hero.power) + int(reward.get("power", 0)))
	for index: int in int(reward.get("relics", 0)):
		hero.relics.append("relic_%s_%d" % [monster.id, index + 1])
	game.state.data.map.locations[monster.camp_id].cleared = true
	game._emit("MonsterDefeated", actor, {"monster_id": monster.id, "camp_id": monster.camp_id, "reward": reward.duplicate(true)})

static func _finish(game: RefCounted) -> void:
	var actor: String = game.state.data.pending_combat.attacker_id
	game.state.data.pending_combat = {}
	game.state.data.pending_reaction = {}
	game._finish_action(actor, "attack")
