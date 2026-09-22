extends RefCounted
const Rules = preload("res://scripts/domain/game_rules.gd")
const Content = preload("res://scripts/domain/resolvers/exploration.gd")
const World = preload("res://scripts/domain/resolvers/world_events.gd")
const Equipment = preload("res://scripts/domain/resolvers/equipment.gd")
const Movement = preload("res://scripts/domain/resolvers/movement.gd")
const Hex = preload("res://scripts/domain/hex/hex.gd")
var errors: Array[String] = []

func run() -> Array[String]:
	errors.clear()
	_test_equipment()
	_test_equipment_movement()
	_test_world_events()
	_test_world_restore_order()
	_test_exploration()
	_test_hints()
	return errors

func _check(condition: bool, message: String) -> void:
	if not condition: errors.append(message)

func _send(game: RefCounted, command: Dictionary) -> Dictionary:
	var result: Dictionary = game.execute(command)
	_check(result.is_valid, "Content command rejected: %s -> %s" % [command, result])
	return result

func _action_game(player_id: String = "p1") -> RefCounted:
	var game: RefCounted = Rules.new(20260922)
	_send(game, {"type": "advance"})
	for id: String in ["p1", "p2", "p3", "p4"]: _send(game, {"type": "ready", "player_id": id})
	_send(game, {"type": "advance"})
	for index in range(4):
		if game.current_actor() == player_id: break
		_send(game, {"type": "pass", "player_id": game.current_actor()})
	return game

func _own(game: RefCounted, player_id: String, location_id: String) -> void:
	var location: Dictionary = game.state.data.map.locations[location_id]
	if not str(location.owner_id).is_empty(): game.state.data.heroes[location.owner_id].controlled_locations.erase(location_id)
	location.owner_id = player_id
	if not game.state.data.heroes[player_id].controlled_locations.has(location_id): game.state.data.heroes[player_id].controlled_locations.append(location_id)

func _test_equipment() -> void:
	_check(Equipment.definitions().size() == 8, "Eight implemented equipment definitions")
	for upgrade_id: String in Equipment.definitions():
		var game: RefCounted = Rules.new(11)
		var hero: Dictionary = game.state.data.heroes.p1
		hero.gold = 20
		_own(game, "p1", "settlement_1")
		_send(game, {"type": "advance"})
		var original_stats := [hero.attack, hero.defence, hero.speed]
		_send(game, {"type": "submit_plan", "player_id": "p1", "plan": {"purchases": [upgrade_id]}})
		_check(hero.upgrades.is_empty() and hero.gold == 20, "Purchase waits until all simultaneous plans lock")
		for id: String in ["p1", "p2", "p3", "p4"]: _send(game, {"type": "ready", "player_id": id})
		_check(hero.upgrades == [upgrade_id] and hero.gold == 20 - int(Equipment.definitions()[upgrade_id].cost), "Purchase equips and charges " + upgrade_id)
		_check([hero.attack, hero.defence, hero.speed] == original_stats, "Equipment preserves base class stats")
		match upgrade_id:
			"iron_weapon": _check(Equipment.passive_bonus(hero, "attack") == 1, "Iron Weapon Attack")
			"reinforced_armor": _check(Equipment.passive_bonus(hero, "defence") == 1 and Equipment.passive_bonus(hero, "initiative") == -1, "Armor defence and initiative tradeoff")
			"trail_boots": _check(Equipment.movement_options(hero).trail_boots, "Trail Boots feeds movement query")
			"scout_lens": _check(Equipment.passive_bonus(hero, "discovery") == 1, "Scout Lens expands discovery")
			"tower_kit":
				_check(Equipment.tower_upgrade_cost(hero, 3) == 2, "Tower Kit reduces next upgrade cost")
				Equipment.consume_tower_kit(game, "p1")
				_check(not hero.upgrades.has("tower_kit") and Equipment.tower_upgrade_cost(hero, 5) == 5, "Consumed Tower Kit frees its slot and cannot reset next round")
			"lucky_charm":
				_check(Equipment.reroll_result(game, "p1", 2, 5) == 5 and not hero.flags.has("lucky_charm_used"), "An improved reroll does not consume Lucky Charm")
				_check(Equipment.reroll_result(game, "p1", 6, 1) == 6 and hero.flags.lucky_charm_used, "Lucky Charm preserves a better old die once")
				_check(Equipment.reroll_result(game, "p1", 6, 2) == 2, "Lucky Charm cannot be used twice in a round")
			"merchant_seal": _check(Equipment.trade_gain(hero, 1) == 2 and Equipment.trade_gain(hero, 2) == 3, "Merchant Seal improves either market trade")
			"ward_stone":
				_check(Equipment.passive_bonus(hero, "defence") == 0, "Ward Stone needs a Relic")
				hero.relics.append("test_relic")
				_check(Equipment.passive_bonus(hero, "defence") == 1, "Ward Stone protects a Relic carrier")
	var game: RefCounted = Rules.new(22)
	_send(game, {"type": "advance"})
	game.state.data.heroes.p1.gold = 20
	var before: String = game.checksum()
	_check(not Equipment.validate_purchase(game, "p1", ["iron_weapon"]).is_valid, "A Settlement is required for buying")
	_check(game.checksum() == before, "Rejected equipment validation is pure")
	_own(game, "p1", "settlement_1")
	_check(not Equipment.validate_purchase(game, "p1", ["iron_weapon", "iron_weapon"]).is_valid, "Duplicate equipment rejected")
	_check(not Equipment.validate_purchase(game, "p1", ["iron_weapon", "reinforced_armor", "ward_stone", "scout_lens"]).is_valid, "Three-slot equipment cap")
	game.state.data.heroes.p1.gold = 7
	_check(not Equipment.validate_purchase(game, "p1", ["iron_weapon", "scout_lens"]).is_valid, "Combined Planning purchases cannot overspend")

func _test_equipment_movement() -> void:
	var map := {"hexes": {}, "roads": [], "blocked_edges": []}
	for q in range(4): map.hexes[Hex.key(q, 0)] = {"terrain": "forest" if q in [1, 2] else "plains"}
	var heroes := {"p1": {"hex": "0,0", "move": 3, "class_id": "warlord"}}
	var boots := Movement.reachable(map, heroes, "p1", {"trail_boots": true})
	_check(boots.has("2,0") and not boots.has("3,0"), "Boots waive exactly one Forest penalty")
	var combined := Movement.reachable(map, heroes, "p1", {"trail_boots": true, "forced_march": true})
	_check(combined.has("3,0") and combined["3,0"].waived_hexes.size() == 2, "Boots and Forced March independently waive two distinct penalties")
	map.hexes["1,0"].terrain = "swamp"
	boots = Movement.reachable(map, heroes, "p1", {"trail_boots": true})
	_check(boots["1,0"].cost == 3 and not boots["1,0"].trail_boots_used and not boots.has("2,0"), "Boots neither discount nor cross a swamp")
	map.hexes["1,0"].terrain = "plains"
	map.hexes["2,0"].terrain = "plains"
	map.hexes["1,0"].movement_terrain = "forest"
	_check(Movement.reachable(map, heroes, "p1")["2,0"].cost == 3 and map.hexes["1,0"].terrain == "plains", "Curse changes movement without granting Forest combat terrain")
	map.blocked_edges = [["0,0", "1,0"]]
	_check(Movement.reachable(map, heroes, "p1").is_empty() and Movement.travel_costs(map, "0,0").size() == 1, "Closed bridge blocks its logical edge, not merely the road bonus")

func _test_world_events() -> void:
	var first: RefCounted = Rules.new(42)
	var before: Dictionary = first.snapshot().rng
	World.world_phase(first)
	_check(first.snapshot().rng == before and first.state.data.world_effects.is_empty(), "Round one applies no world event and consumes no event RNG")
	var second: RefCounted = Rules.new(42)
	first.state.data.round_number = 2
	second.state.data.round_number = 2
	World.world_phase(first)
	World.world_phase(second)
	_check(first.state.data.world_effects == second.state.data.world_effects and first._rng.snapshot() == second._rng.snapshot(), "Seeded world event and target reproduce")
	for event_id: String in ["collapsed_bridge", "unstable_leyline", "monster_migration", "cursed_ground", "wandering_market"]:
		var game: RefCounted = Rules.new(73)
		game.state.data.round_number = 2
		_check(World.apply_event(game, event_id), "World event is eligible: " + event_id)
		match event_id:
			"collapsed_bridge":
				var edge: Array = game.state.data.map.blocked_edges[0].duplicate()
				_check(not Movement.road_lookup(game.state.data.map).has(Movement.road_key(edge[0], edge[1])), "Closed bridge removed from road network")
				var costs := Movement.travel_costs(game.state.data.map, "0,0")
				for sanctuary: String in game.state.data.map.sanctuaries: _check(costs.has(sanctuary), "Bridge closure preserves all Sanctuary alternatives")
				game.state.data.round_number = 3
				World._expire(game, "world")
				_check(game.state.data.map.blocked_edges.has(edge), "Bridge stays closed for its second round")
				game.state.data.round_number = 4
				World._expire(game, "world")
				_check(not game.state.data.map.blocked_edges.has(edge) and game.state.data.map.roads.has(edge), "Bridge restores after two rounds")
			"unstable_leyline":
				var location: Dictionary = game.state.data.map.locations[game.state.data.world_effects[0].location_id]
				_check(location.world_income_bonus == 1 and location.world_defence_modifier == -1, "Leyline improves income and weakens Defence")
				World.resolution_expiry(game)
				_check(location.world_income_bonus == 0 and location.world_defence_modifier == 0, "Leyline modifiers cleanly expire")
			"monster_migration":
				var reinforced := 0
				for monster: Dictionary in game.state.data.monsters.values(): reinforced += int(monster.get("reinforcements", 0))
				_check(reinforced == 1 and game.state.data.world_effects.is_empty(), "Migration reinforces one living camp permanently")
			"cursed_ground":
				var changed: Array = game.state.data.world_effects[0].hexes
				_check(not changed.is_empty(), "Curse selects a Plains region")
				for hex_id: String in changed: _check(game.state.data.map.hexes[hex_id].terrain == "plains" and game.state.data.map.hexes[hex_id].movement_terrain == "forest", "Curse keeps original terrain")
				World.resolution_expiry(game)
				for hex_id: String in changed: _check(not game.state.data.map.hexes[hex_id].has("movement_terrain"), "Curse expires without corrupting terrain")
			"wandering_market":
				_check(not game.state.data.market_hex.is_empty() and not game._is_occupied(game.state.data.market_hex), "Wandering Market selects neutral unoccupied ground")
				World.resolution_expiry(game)
				_check(game.state.data.market_hex.is_empty(), "Wandering Market ends at Resolution")

func _test_world_restore_order() -> void:
	# JSON restoration canonicalizes Dictionary order; event arrays must remain
	# identical to a fresh process, including every affected hex and target draw.
	for event_id: String in ["collapsed_bridge", "unstable_leyline", "monster_migration", "cursed_ground", "wandering_market"]:
		var fresh: RefCounted = Rules.new(20260922)
		var restored: RefCounted = Rules.from_snapshot(JSON.parse_string(fresh.state.to_json()))
		_check(restored != null, "Fresh world fixture restores for " + event_id)
		if restored == null: continue
		fresh.state.data.round_number = 2
		restored.state.data.round_number = 2
		World.apply_event(fresh, event_id)
		World.apply_event(restored, event_id)
		_check(fresh.checksum() == restored.checksum() and fresh._rng.snapshot() == restored._rng.snapshot(), "World target, audit arrays and state survive Dictionary reordering: " + event_id)
		fresh.state.data.round_number = 4
		restored.state.data.round_number = 4
		World.resolution_expiry(fresh)
		World.resolution_expiry(restored)
		World._expire(fresh, "world")
		World._expire(restored, "world")
		_check(fresh.checksum() == restored.checksum(), "World expiry survives Dictionary reordering: " + event_id)

func _at_ruin(game: RefCounted, player_id: String, location_id: String = "ruin_1") -> void:
	game.state.data.heroes[player_id].hex = game.state.data.map.locations[location_id].hex
	game._discover(player_id)

func _test_exploration() -> void:
	var game := _action_game()
	_at_ruin(game, "p1")
	game.state.data.heroes.p1.fate = 2
	var starting_gold: int = game.state.data.heroes.p1.gold
	_send(game, {"type": "explore", "player_id": "p1", "use_fate": true})
	_check(game.current_actor() == "p1" and game.state.data.heroes.p1.fate == 0, "Fate alternatives pause the same scheduled action and spend exactly two")
	var choices: Dictionary = game.legal_actions("p1").choose_reward.choices
	_check(choices.size() == 2 and game.legal_actions("p2").is_empty(), "Two distinct rewards belong only to exploring hero")
	var before: String = game.checksum()
	_check(not game.execute({"type": "choose_reward", "player_id": "p2", "choice": choices.keys()[0]}).is_valid, "Other heroes cannot take a revealed reward")
	_check(not game.execute({"type": "choose_reward", "player_id": "p1", "choice": "invented"}).is_valid and game.checksum() == before, "Invalid reward choice preserves state and RNG")
	var restored: RefCounted = Rules.from_snapshot(JSON.parse_string(game.state.to_json()))
	_check(restored != null, "Pending exploration survives JSON validation")
	var choice: String = choices.keys()[0]
	_send(game, {"type": "choose_reward", "player_id": "p1", "choice": choice})
	if restored != null:
		_send(restored, {"type": "choose_reward", "player_id": "p1", "choice": choice})
		_check(game.checksum() == restored.checksum(), "Saved exploration choice continues identically")
	_check(game.state.data.heroes.p1.relics == ["relic_ruin_1"] and game.state.data.map.locations.ruin_1.exhausted, "Ruin grants one Relic and exhausts permanently")
	_check(game.state.data.heroes.p1.gold >= starting_gold + 1, "Ranger exploration affinity grants one extra Gold")
	_check(Content.explore_options(game, "p1").is_empty(), "Exhausted Ruin cannot be farmed")
	game = _action_game("p4")
	_at_ruin(game, "p4")
	var power: int = game.state.data.heroes.p4.power
	var fate: int = game.state.data.heroes.p4.fate
	_send(game, {"type": "special", "special_id": "dark_bargain", "player_id": "p4"})
	_check(game.state.data.heroes.p4.power >= power + 2 and game.state.data.heroes.p4.fate == mini(5, fate + 1), "Dark Bargain grants extra Power and the Cultist's capped class Fate")
	var negative_logged := false
	for event: Dictionary in game.state.data.events:
		if event.type == "DarkBargainAccepted" and event.data.health_cost == 2: negative_logged = true
	_check(negative_logged, "Dark Bargain records the accepted Health cost")
	game = _action_game("p4")
	_at_ruin(game, "p4")
	game.state.data.heroes.p4.hp = 2
	before = game.checksum()
	_check(not game.execute({"type": "special", "special_id": "dark_bargain", "player_id": "p4"}).is_valid and game.checksum() == before, "Dark Bargain cannot down the accepting Cultist")
	game = _action_game()
	var hero: Dictionary = game.state.data.heroes.p1
	game.state.data.ground_loot[hero.hex] = {"gold": 2, "relics": ["dropped_relic"]}
	starting_gold = hero.gold
	_send(game, {"type": "explore", "player_id": "p1"})
	_check(hero.gold == starting_gold + 2 and hero.relics.has("dropped_relic") and not game.state.data.ground_loot.has(hero.hex), "Explore collects ground Gold/Relics exactly once")
	var relic_sources := 2
	for monster: Dictionary in game.state.data.monsters.values():
		if int(game.definitions.monsters[monster.definition_id].reward.relics) > 0: relic_sources += 1
	_check(relic_sources == 4, "Two Ruins and two Wraiths supply four actual Relics")

func _test_hints() -> void:
	var game: RefCounted = Rules.new(90)
	var cultist: Dictionary = game.state.data.heroes.p4
	var ruin: Dictionary = game.state.data.map.locations.ruin_1
	for value: String in game.state.data.map.hexes:
		if Hex.distance(value, ruin.hex) == 3:
			cultist.hex = value
			break
	ruin.discovered_by.erase("p4")
	Content.update_hints(game, "p4")
	_check(cultist.occult_hint.regions.has(game.state.data.map.hexes[ruin.hex].region), "Occult Sense hints at nearby undiscovered Relic region")
	_check(cultist.occult_hint.keys() == ["regions"] and not JSON.stringify(cultist.occult_hint).contains(ruin.hex), "Occult Sense never reveals exact source hex")
	var count: int = game.state.data.events.size()
	Content.update_hints(game, "p4")
	_check(game.state.data.events.size() == count, "Unchanged Occult Sense hints do not spam the event log")
