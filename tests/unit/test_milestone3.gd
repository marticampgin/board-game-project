extends RefCounted
## Focused state fixtures exercise timing boundaries; full-match acceptance
## separately reaches every route using only ordinary game commands.
const Rules = preload("res://scripts/domain/game_rules.gd")
const State = preload("res://scripts/domain/state/game_state.gd")
const Economy = preload("res://scripts/domain/resolvers/economy.gd")
const Victory = preload("res://scripts/domain/resolvers/victory.gd")
const Equipment = preload("res://scripts/domain/resolvers/equipment.gd")
const Hex = preload("res://scripts/domain/hex/hex.gd")
const Rng = preload("res://scripts/services/deterministic_rng.gd")
var errors: Array[String] = []

func run() -> Array[String]:
	errors.clear()
	_test_settlement_trade_and_equipment()
	_test_conquest_response_and_preincome_win()
	_test_dominion_postincome_and_cancellation()
	_test_network_and_shared_claims()
	_test_ritual_timing_and_cancel()
	_test_exploration_and_world_events()
	_test_class_fate()
	return errors

func _check(condition: bool, message: String) -> void:
	if not condition: errors.append(message)

func _send(game: RefCounted, command: Dictionary) -> Dictionary:
	var result: Dictionary = game.execute(command)
	_check(result.is_valid, "M3 command rejected %s: %s" % [str(command), str(result)])
	if result.is_valid:
		var faults: Array = State.validation_errors(game.snapshot())
		_check(faults.is_empty(), "M3 snapshot after %s: %s" % [command.type, str(faults)])
	return result

func _reject(game: RefCounted, command: Dictionary) -> void:
	var checksum: String = game.checksum()
	_check(not game.execute(command).is_valid, "Expected rejection: " + str(command))
	_check(game.checksum() == checksum, "M3 rejection mutated state/RNG")

func _own(game: RefCounted, location_id: String, player_id: String) -> void:
	var location: Dictionary = game.state.data.map.locations[location_id]
	if not str(location.owner_id).is_empty(): game.state.data.heroes[location.owner_id].controlled_locations.erase(location_id)
	location.owner_id = player_id
	if not player_id.is_empty():
		game.state.data.heroes[player_id].controlled_locations.append(location_id)
		if not location.discovered_by.has(player_id): location.discovered_by.append(player_id)

func _start(game: RefCounted) -> void:
	_send(game, {"type": "advance"})
	for player_id: String in ["p1", "p2", "p3", "p4"]: _send(game, {"type": "ready", "player_id": player_id})
	_send(game, {"type": "advance"})

func _pass_to(game: RefCounted, player_id: String) -> void:
	for guard: int in range(8):
		if game.current_actor() == player_id: return
		if game.current_actor().is_empty(): break
		_send(game, {"type": "pass", "player_id": game.current_actor()})
	_check(false, "Expected next scheduled action for " + player_id)

func _resolve(game: RefCounted) -> void:
	for guard: int in range(8):
		if game.current_actor().is_empty(): break
		_send(game, {"type": "pass", "player_id": game.current_actor()})
	_send(game, {"type": "advance"})
	_send(game, {"type": "advance"})

func _test_settlement_trade_and_equipment() -> void:
	var game: RefCounted = Rules.new(904)
	_start(game)
	var actor: String = game.current_actor()
	var settlement: Dictionary = game.state.data.map.locations.settlement_1
	game.state.data.heroes[actor].hex = settlement.hex
	game._discover(actor)
	_send(game, {"type": "capture", "player_id": actor})
	_check(settlement.owner_id == actor, "Neutral Settlement captures in one action")
	_pass_to(game, actor)
	_send(game, {"type": "trade", "player_id": actor, "direction": "power_to_gold"})
	_check(game.state.data.heroes[actor].power == 1 and game.state.data.heroes[actor].gold == 6, "Trade converts one Power to two Gold")
	_resolve(game)
	_check(game.state.data.heroes[actor].gold == 8, "Settlement pays two Gold during Resolution")
	_send(game, {"type": "advance"})
	var options: Dictionary = game.legal_actions(actor).submit_plan.purchases
	_check(options.has("iron_weapon") and game.definitions.upgrades.size() == 8, "Eight data-driven upgrades available through controlled Settlement")
	_send(game, {"type": "submit_plan", "player_id": actor, "plan": {"purchases": ["iron_weapon", "reinforced_armor"]}})
	_check(game.state.data.heroes[actor].upgrades.is_empty(), "Equipment plans are stored until all Ready")
	for player_id: String in ["p1", "p2", "p3", "p4"]: _send(game, {"type": "ready", "player_id": player_id})
	var hero: Dictionary = game.state.data.heroes[actor]
	_check(hero.gold == 0 and hero.upgrades.size() == 2, "Planning buys and equips selected upgrades together")
	_check(Equipment.passive_bonus(hero, "attack") == 1 and Equipment.passive_bonus(hero, "defence") == 1 and Equipment.passive_bonus(hero, "initiative") == -1, "Weapon and Armor effects compose without changing base stats")
	_send(game, {"type": "advance"})
	_resolve(game)
	_send(game, {"type": "advance"})
	_reject(game, {"type": "submit_plan", "player_id": actor, "plan": {"purchases": ["iron_weapon"]}})
	_reject(game, {"type": "submit_plan", "player_id": actor, "plan": {"purchases": ["trail_boots", "scout_lens"]}})

func _test_conquest_response_and_preincome_win() -> void:
	var game: RefCounted = Rules.new(911)
	for location_id: String in ["worldspire", "ancient_1", "ancient_2", "ancient_3"]: _own(game, location_id, "p1")
	_start(game)
	_resolve(game)
	_check(game.state.data.phase == "world" and game.state.data.round_number == 2 and game.state.data.victory.is_empty(), "New Conquest claim cannot win in its creation Resolution")
	_check(game.state.data.victory_claims.p1_conquest.created_round == 1 and game.state.data.victory_claims.p1_conquest.required_round == 2, "Conquest exposes a full response round")
	var power_before: int = game.state.data.heroes.p1.power
	_start(game)
	_resolve(game)
	_check(game.state.data.phase == "victory" and game.state.data.victory.route == "conquest" and game.state.data.victory.winners == ["p1"], "Conquest confirms at following Resolution")
	_check(game.state.data.heroes.p1.power == power_before, "Existing victory confirmation stops before income")
	_reject(game, {"type": "advance"})
	_check(Rules.from_snapshot(JSON.parse_string(game.state.to_json())) != null, "Terminal victory snapshot round-trips")

func _test_dominion_postincome_and_cancellation() -> void:
	var game: RefCounted = Rules.new(33)
	_own(game, "settlement_1", "p3")
	_own(game, "settlement_2", "p3")
	game.state.data.heroes.p3.gold = 9
	_check(Economy.network(game, "p3").connected, "Generated road network connects the Settlements")
	_start(game)
	_resolve(game)
	_check(game.state.data.heroes.p3.gold == 15 and game.state.data.victory_claims.has("p3_dominion"), "Merchant connected income creates Dominion after crossing fifteen Gold")
	_start(game)
	_pass_to(game, "p3")
	game.state.data.heroes.p3.hex = game.state.data.map.locations.settlement_1.hex
	_send(game, {"type": "trade", "player_id": "p3", "direction": "gold_to_power"})
	_check(game.state.data.heroes.p3.gold == 13 and not game.state.data.victory_claims.has("p3_dominion"), "Spending below fifteen cancels Dominion immediately")
	_resolve(game)
	_check(game.state.data.victory.is_empty() and game.state.data.victory_claims.p3_dominion.created_round == 2, "Restored post-income eligibility creates a new response window")
	var other: RefCounted = Rules.new(33)
	_own(other, "settlement_1", "p3")
	_own(other, "settlement_2", "p3")
	other.state.data.heroes.p3.gold = 15
	_start(other)
	_resolve(other)
	_start(other)
	_pass_to(other, "p1")
	other.state.data.heroes.p1.hex = other.state.data.map.locations.settlement_1.hex
	other._discover("p1")
	_send(other, {"type": "capture", "player_id": "p1"})
	_check(not other.state.data.victory_claims.has("p3_dominion"), "Rival Settlement capture immediately cancels Dominion")

func _test_network_and_shared_claims() -> void:
	var game: RefCounted = Rules.new(500)
	_own(game, "settlement_1", "p3")
	_own(game, "settlement_2", "p3")
	_check(Economy.network(game, "p3").connected, "Neutral roads connect owned Settlements")
	var roads: Array = game.state.data.map.roads.duplicate(true)
	game.state.data.map.roads = []
	_check(not Economy.network(game, "p3").connected, "Disconnected road network invalidates Dominion")
	game.state.data.map.roads = roads
	for location_id: String in ["worldspire", "ancient_1", "ancient_2", "ancient_3"]: _own(game, location_id, "p1")
	# Add a legal road detour around opposing Towers to isolate simultaneous
	# confirmation from the generated network's ownership choke points.
	var from_hex: String = game.state.data.map.locations.settlement_1.hex
	var to_hex: String = game.state.data.map.locations.settlement_2.hex
	var queue: Array[String] = [from_hex]
	var predecessors: Dictionary = {from_hex: ""}
	while not queue.is_empty() and not predecessors.has(to_hex):
		var current: String = queue.pop_front()
		for neighbor: String in Hex.neighbors(current):
			if predecessors.has(neighbor) or not game.state.data.map.hexes.has(neighbor): continue
			var tile: Dictionary = game.state.data.map.hexes[neighbor]
			if tile.terrain in ["mountain", "water"]: continue
			var landmark: Dictionary = game.state.data.map.locations.get(tile.location_id, {})
			if landmark.get("owner_id", "") == "p1": continue
			predecessors[neighbor] = current
			queue.append(neighbor)
	_check(predecessors.has(to_hex), "Scenario has a walkable road detour around enemy Towers")
	var step: String = to_hex
	while predecessors.has(step) and not str(predecessors[step]).is_empty():
		var edge: Array = [predecessors[step], step]
		if not game.state.data.map.roads.has(edge) and not game.state.data.map.roads.has([edge[1], edge[0]]): game.state.data.map.roads.append(edge)
		step = predecessors[step]
	game.state.data.heroes.p3.gold = 15
	_start(game)
	_resolve(game)
	_check(game.state.data.victory_claims.has("p1_conquest") and game.state.data.victory_claims.has("p3_dominion"), "Both route claims are eligible in the same Resolution")
	_start(game)
	_resolve(game)
	_check(game.state.data.victory.get("shared", false) and game.state.data.victory.get("winners", []) == ["p1", "p3"], "Equal-age simultaneous claims share victory")

func _test_ritual_timing_and_cancel() -> void:
	var game: RefCounted = Rules.new(802)
	_start(game)
	var actor: String = game.current_actor()
	game.state.data.heroes[actor].hex = "0,0"
	game.state.data.heroes[actor].relics = ["fixture_relic_a", "fixture_relic_b", "fixture_relic_c"]
	_reject(game, {"type": "complete_ritual", "player_id": actor})
	_send(game, {"type": "begin_ritual", "player_id": actor})
	_check(game.state.data.victory.is_empty() and game.state.data.commitments[actor].kind == "ritual", "Begin Ritual is public and does not win immediately")
	_reject(game, {"type": "complete_ritual", "player_id": actor})
	_pass_to(game, actor)
	_send(game, {"type": "complete_ritual", "player_id": actor})
	_check(game.state.data.phase == "victory" and game.state.data.victory.route == "ascension", "Next scheduled action completes Ascension immediately")
	var canceled: RefCounted = Rules.new(802)
	_start(canceled)
	actor = canceled.current_actor()
	canceled.state.data.heroes[actor].hex = "0,0"
	canceled.state.data.heroes[actor].relics = ["fixture_relic_a", "fixture_relic_b", "fixture_relic_c"]
	_send(canceled, {"type": "begin_ritual", "player_id": actor})
	_pass_to(canceled, actor)
	_send(canceled, {"type": "pass", "player_id": actor})
	_check(canceled.state.data.commitments.is_empty(), "Choosing another scheduled action cancels Ritual")
	var contested: RefCounted = Rules.new(802)
	_start(contested)
	actor = contested.current_actor()
	contested.state.data.heroes[actor].hex = "0,0"
	contested.state.data.heroes[actor].relics = ["fixture_relic_a", "fixture_relic_b", "fixture_relic_c"]
	contested.state.data.heroes[actor].defence = 10
	contested.state.data.map.hexes["0,0"].terrain = "plains"
	_send(contested, {"type": "begin_ritual", "player_id": actor})
	var attacker_id: String = contested.current_actor()
	contested.state.data.heroes[attacker_id].hex = "-1,0"
	contested.state.data.map.hexes["-1,0"].terrain = "plains"
	# Clone the RNG to arrange a non-displacing margin of two, without
	# replacing any gameplay roll or manufacturing a victory result.
	var preview: RefCounted = Rng.new(1)
	preview.restore(contested.state.data.rng)
	var attacker_die: int = preview.draw("combat", 1, 6).result
	var defender_die: int = preview.draw("combat", 1, 6).result
	contested.state.data.heroes[attacker_id].attack = 12 + defender_die - attacker_die
	_send(contested, {"type": "attack", "player_id": attacker_id, "target_id": actor})
	_send(contested, {"type": "choose_stance", "player_id": attacker_id, "stance": "guard"})
	_send(contested, {"type": "choose_stance", "player_id": actor, "stance": "guard"})
	for decision: int in range(2):
		var battle: Dictionary = contested.state.data.pending_combat
		if battle.is_empty(): break
		_send(contested, {"type": "decline_fate", "player_id": battle.attacker_id if battle.stage == "fate_attacker" else battle.defender_id})
	_check(contested.state.data.commitments.get(actor, {}).get("kind", "") == "ritual", "A non-displacing hit does not invent a Ritual disruption rule")

func _test_exploration_and_world_events() -> void:
	var game: RefCounted = Rules.new(93)
	_start(game)
	var actor: String = game.current_actor()
	var ruin: Dictionary = game.state.data.map.locations.ruin_1
	game.state.data.heroes[actor].hex = ruin.hex
	game.state.data.heroes[actor].fate = 3
	game._discover(actor)
	_send(game, {"type": "explore", "player_id": actor, "use_fate": true})
	_check(not game.state.data.pending_exploration.is_empty(), "Explore Alternatives opens explicit reward choice")
	var choices: Variant = game.legal_actions(actor).choose_reward.choices
	var selected: String = str(choices.keys()[0]) if choices is Dictionary else str(choices[0])
	var restored: RefCounted = Rules.from_snapshot(JSON.parse_string(game.state.to_json()))
	_check(restored != null, "Exploration reward choice saves and resumes")
	_send(game, {"type": "choose_reward", "player_id": actor, "choice": selected})
	_check(ruin.exhausted and game.state.data.heroes[actor].relics.size() == 1, "Ruin exhausts after awarding its contested Relic")
	if restored != null:
		_send(restored, {"type": "choose_reward", "player_id": actor, "choice": selected})
		_check(restored.checksum() == game.checksum(), "Reward choice continuation is deterministic")
	_resolve(game)
	_send(game, {"type": "advance"})
	var event_count: int = 0
	for event: Dictionary in game.state.data.events:
		if event.type == "WorldEventSelected": event_count += 1
	_check(event_count == 1 and game.definitions.world_events.size() == 5, "World draws one of five data-driven events from round two")

func _test_class_fate() -> void:
	var scout_game: RefCounted = Rules.new(64)
	_start(scout_game)
	_pass_to(scout_game, "p1")
	var ranger: Dictionary = scout_game.state.data.heroes.p1
	var scout_target: String = ""
	for candidate: String in scout_game.legal_actions("p1").move.targets:
		for location: Dictionary in scout_game.state.data.map.locations.values():
			if not location.discovered_by.has("p1") and Hex.distance(candidate, location.hex) <= 2:
				scout_target = candidate
				break
		if not scout_target.is_empty(): break
	_check(not scout_target.is_empty(), "Ranger has a reachable new discovery")
	if not scout_target.is_empty():
		var scout_fate: int = ranger.fate
		_send(scout_game, {"type": "move", "player_id": "p1", "target": scout_target})
		while not scout_game.state.data.pending_reaction.is_empty():
			_send(scout_game, {"type": "resolve_reaction", "player_id": scout_game.state.data.pending_reaction.actor_id, "choice": "decline"})
		_check(ranger.fate == scout_fate + 1 and ranger.flags.class_fate, "Ranger discovery grants exactly one class Fate despite multiple discoveries")
	var war_game: RefCounted = Rules.new(64)
	_start(war_game)
	_pass_to(war_game, "p2")
	war_game.state.data.heroes.p2.hex = "-1,0"
	war_game.state.data.heroes.p1.hex = "0,0"
	_own(war_game, "worldspire", "p1")
	var war_fate: int = war_game.state.data.heroes.p2.fate
	_send(war_game, {"type": "attack", "player_id": "p2", "target_id": "p1"})
	_check(war_game.state.data.heroes.p2.fate == war_fate + 1, "Warlord attacks a rival controlling more Towers and gains class Fate")
	var game: RefCounted = Rules.new(64)
	_start(game)
	_pass_to(game, "p3")
	var merchant: Dictionary = game.state.data.heroes.p3
	merchant.hex = game.state.data.map.locations.settlement_1.hex
	var fate_before: int = merchant.fate
	_send(game, {"type": "trade", "player_id": "p3", "direction": "power_to_gold"})
	_check(merchant.fate == fate_before + 1 and merchant.flags.class_fate, "Merchant first Trade grants class Fate")
	_pass_to(game, "p3")
	_send(game, {"type": "trade", "player_id": "p3", "direction": "power_to_gold"})
	_check(merchant.fate == fate_before + 1, "Merchant class Fate is capped once per round")
	var cultist_game: RefCounted = Rules.new(64)
	_start(cultist_game)
	_pass_to(cultist_game, "p4")
	var cultist: Dictionary = cultist_game.state.data.heroes.p4
	cultist.hex = cultist_game.state.data.map.locations.ruin_1.hex
	cultist_game._discover("p4")
	var hp_before: int = cultist.hp
	fate_before = cultist.fate
	_send(cultist_game, {"type": "special", "player_id": "p4", "special_id": "dark_bargain"})
	_check(cultist.hp <= hp_before - 2 and cultist.fate == fate_before + 1, "Cultist knowingly accepts Dark Bargain cost and gains class Fate")
