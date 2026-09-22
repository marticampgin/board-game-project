extends RefCounted
## Ordinary equipment is additive and data-driven; base class stats stay intact.
static var _definitions: Dictionary = {}

static func definitions() -> Dictionary:
	if _definitions.is_empty():
		_definitions = JSON.parse_string(FileAccess.get_file_as_string("res://data/upgrades.json"))
	return _definitions.duplicate(true)

static func passive_bonus(hero: Dictionary, stat: String) -> int:
	var result := 0
	var table := definitions()
	for id: String in hero.get("upgrades", []):
		var effects: Dictionary = table.get(id, {}).get("effects", {})
		result += int(effects.get(stat, 0))
		if stat == "defence" and not hero.get("relics", []).is_empty():
			result += int(effects.get("relic_defence", 0))
	return result

static func movement_options(hero: Dictionary) -> Dictionary:
	return {"trail_boots": hero.get("upgrades", []).has("trail_boots")}

static func _market_access(game: RefCounted, player_id: String) -> bool:
	for location: Dictionary in game.state.data.map.locations.values():
		if location.kind == "settlement" and location.owner_id == player_id:
			return true
	return false

static func purchase_options(game: RefCounted, player_id: String) -> Dictionary:
	var result: Dictionary = {}
	for id: String in definitions():
		if validate_purchase(game, player_id, [id]).is_valid:
			result[id] = definitions()[id]
	return result

static func validate_purchase(game: RefCounted, player_id: String, upgrade_ids: Array) -> Dictionary:
	if not game.state.data.heroes.has(player_id):
		return game._reject("UNKNOWN_PLAYER", "Equipment needs a known hero.")
	if upgrade_ids.is_empty(): return {"is_valid": true}
	if game.state.data.phase != "planning":
		return game._reject("WRONG_PHASE", "Equipment purchases belong to Planning.")
	if not _market_access(game, player_id):
		return game._reject("MARKET_REQUIRED", "Control a Settlement to buy equipment during Planning.")
	var hero: Dictionary = game.state.data.heroes[player_id]
	if hero.upgrades.size() + upgrade_ids.size() > 3:
		return game._reject("EQUIPMENT_CAP", "At most three ordinary upgrades may be equipped.")
	var table := definitions()
	var seen: Dictionary = {}
	var cost := 0
	for id: Variant in upgrade_ids:
		if not id is String or not table.has(id):
			return game._reject("UNKNOWN_UPGRADE", "Choose a defined equipment upgrade.")
		if hero.upgrades.has(id) or seen.has(id):
			return game._reject("DUPLICATE_UPGRADE", "An upgrade may only be equipped once.")
		seen[id] = true
		cost += int(table[id].cost)
	if int(hero.gold) < cost:
		return game._reject("INSUFFICIENT_GOLD", "The combined equipment purchase costs %d Gold." % cost)
	return {"is_valid": true, "gold_cost": cost}

static func purchase(game: RefCounted, player_id: String, upgrade_ids: Array) -> void:
	var hero: Dictionary = game.state.data.heroes[player_id]
	var table := definitions()
	for id: String in upgrade_ids:
		hero.gold -= int(table[id].cost)
		hero.upgrades.append(id)
		game._emit("EquipmentPurchased", player_id, {"upgrade_id": id, "gold_cost": table[id].cost, "effects": table[id].effects.duplicate(true)})
	game._discover(player_id)

static func tower_upgrade_cost(hero: Dictionary, base: int) -> int:
	return maxi(0, base - (1 if hero.get("upgrades", []).has("tower_kit") else 0))

static func consume_tower_kit(game: RefCounted, player_id: String) -> void:
	var hero: Dictionary = game.state.data.heroes[player_id]
	if hero.upgrades.has("tower_kit"):
		hero.upgrades.erase("tower_kit")
		game._emit("EquipmentConsumed", player_id, {"upgrade_id": "tower_kit", "gold_saved": 1})

static func trade_gain(hero: Dictionary, base: int) -> int:
	return base + (1 if hero.get("upgrades", []).has("merchant_seal") else 0)

static func reroll_result(game: RefCounted, player_id: String, old: int, rolled: int) -> int:
	var hero: Dictionary = game.state.data.heroes[player_id]
	if old > rolled and hero.upgrades.has("lucky_charm") and not hero.flags.get("lucky_charm_used", false):
		hero.flags.lucky_charm_used = true
		game._emit("LuckyCharmUsed", player_id, {"old_die": old, "new_die": rolled, "kept_die": old})
		return old
	return rolled
