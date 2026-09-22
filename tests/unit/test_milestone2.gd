extends RefCounted
const Rules = preload("res://scripts/domain/game_rules.gd")
const State = preload("res://scripts/domain/state/game_state.gd")
const Hex = preload("res://scripts/domain/hex/hex.gd")
const Battle = preload("res://scripts/domain/resolvers/battle_flow.gd")
var errors: Array[String] = []

func run() -> Array[String]:
	errors.clear()
	_test_secret_stances_and_fate_order()
	_test_bribe_and_prepared_hex()
	_test_down_every_class_and_displacement()
	_test_monsters_and_rest()
	_test_ancient_capture_and_upgrade()
	_test_planning_and_snare()
	_test_challenge_and_forced_march()
	_test_pending_snapshot_rejections()
	return errors

func _check(condition: bool, detail: String) -> void:
	if not condition: errors.append(detail)

func _send(game: RefCounted, command: Dictionary) -> Dictionary:
	var result: Dictionary = game.execute(command)
	_check(result.is_valid, "M2 command rejected %s: %s" % [str(command), str(result)])
	if result.is_valid:
		var snapshot_errors: Array = State.validation_errors(game.snapshot())
		_check(snapshot_errors.is_empty(), "M2 snapshot after %s: %s" % [command.type, str(snapshot_errors)])
	return result

func _reject(game: RefCounted, command: Dictionary) -> void:
	var checksum: String = game.checksum()
	var result: Dictionary = game.execute(command)
	_check(not result.is_valid, "M2 illegal command accepted: " + str(command))
	_check(game.checksum() == checksum, "M2 rejection mutated state or RNG")

func _start(game: RefCounted) -> void:
	_send(game, {"type": "advance"})
	for player: String in ["p1", "p2", "p3", "p4"]:
		_send(game, {"type": "ready", "player_id": player})
	_send(game, {"type": "advance"})

func _fixture(attacker: String = "p1", defender: String = "p2", seed: int = 7001) -> RefCounted:
	var game: RefCounted = Rules.new(seed)
	_start(game)
	for hero: Dictionary in game.state.data.heroes.values(): hero.hex = hero.sanctuary
	game.state.data.heroes[attacker].hex = "-1,0"
	game.state.data.heroes[defender].hex = "0,0"
	game.state.data.map.hexes["-1,0"].terrain = "plains"
	game.state.data.map.hexes["0,0"].terrain = "plains"
	var order: Array = [attacker, defender]
	for player: String in ["p1", "p2", "p3", "p4"]:
		if not order.has(player): order.append(player)
	game.state.data.initiative_order = order
	game.state.data.next_cycle_order = order.duplicate()
	game.state.data.current_actor_index = 0
	game._discover(attacker)
	game._discover(defender)
	return game

func _finish_combat(game: RefCounted, attack_stance: String = "assault", defend_stance: String = "guard") -> void:
	for step: int in range(12):
		if game.state.data.pending_combat.is_empty(): return
		if not game.state.data.pending_reaction.is_empty():
			_send(game, {"type": "resolve_reaction", "player_id": game.state.data.pending_reaction.actor_id, "choice": "decline"})
			continue
		var battle: Dictionary = game.state.data.pending_combat
		if battle.stage == "stances":
			var actor: String = battle.attacker_id if not battle.stances.has(battle.attacker_id) else battle.defender_id
			_send(game, {"type": "choose_stance", "player_id": actor, "stance": attack_stance if actor == battle.attacker_id else defend_stance})
		elif battle.stage in ["fate_attacker", "fate_defender"]:
			_send(game, {"type": "decline_fate", "player_id": battle.attacker_id if battle.stage == "fate_attacker" else battle.defender_id})
		elif battle.stage == "displacement":
			var targets: Dictionary = game.legal_actions(battle.defender_id).displace.targets
			_send(game, {"type": "displace", "player_id": battle.defender_id, "target": targets.keys()[0]})
	_check(false, "Combat decision windows terminate within twelve commands")

func _pass_to(game: RefCounted, player_id: String) -> void:
	for index: int in range(8):
		if game.current_actor() == player_id: return
		if game.current_actor().is_empty(): break
		_send(game, {"type": "pass", "player_id": game.current_actor()})
	_check(false, "Could not reach scheduled actor " + player_id)

func _next_round(game: RefCounted) -> void:
	for index: int in range(8):
		if game.current_actor().is_empty(): break
		_send(game, {"type": "pass", "player_id": game.current_actor()})
	_send(game, {"type": "advance"})
	_send(game, {"type": "advance"})

func _test_secret_stances_and_fate_order() -> void:
	var game: RefCounted = _fixture()
	game.state.data.heroes.p1.fate = 5
	game.state.data.heroes.p2.fate = 5
	_send(game, {"type": "attack", "player_id": "p1", "target_id": "p2"})
	_check(game.current_actor() == "p1", "Declaring attack pauses handoff until combat completes")
	_reject(game, {"type": "pass", "player_id": "p1"})
	_reject(game, {"type": "choose_stance", "player_id": "p3", "stance": "guard"})
	var result: Dictionary = _send(game, {"type": "choose_stance", "player_id": "p1", "stance": "trick"})
	_check(game.state.data.heroes.p1.fate == 5 and game.state.data.pending_combat.dice.is_empty(), "Secret Trick choice spends no public Fate before reveal")
	for event: Dictionary in result.events:
		if event.type == "StanceChosen": _check(event.visibility == "owner_only" and not event.data.has("stance"), "Stance submission event does not reveal choice")
	var restored: RefCounted = Rules.from_snapshot(JSON.parse_string(game.state.to_json()))
	_check(restored != null, "Save/load while only attacker has secretly submitted")
	_send(game, {"type": "choose_stance", "player_id": "p2", "stance": "guard"})
	if restored != null:
		_send(restored, {"type": "choose_stance", "player_id": "p2", "stance": "guard"})
		_check(game.checksum() == restored.checksum(), "Secret choice save resumes identical dice and state")
	_check(game.state.data.heroes.p1.fate == 4 and game.state.data.pending_combat.stage == "fate_attacker", "Trick costs one Fate on simultaneous reveal")
	_reject(game, {"type": "spend_fate", "player_id": "p2"})
	_send(game, {"type": "spend_fate", "player_id": "p1"})
	_check(game.state.data.heroes.p1.fate == 3 and game.state.data.pending_combat.stage == "fate_defender", "Attacker rerolls before defender")
	_reject(game, {"type": "spend_fate", "player_id": "p1"})
	_send(game, {"type": "spend_fate", "player_id": "p2"})
	_finish_combat(game)
	_check(game.current_actor() == "p2", "Defending preserves defender's upcoming action")
	_reject(game, {"type": "spend_fate", "player_id": "p2"})
	var rerolls: Array = []
	for event: Dictionary in game.state.data.events:
		if event.type == "CombatDieRerolled": rerolls.append(event)
	_check(rerolls.size() == 2 and rerolls[0].data.keeps_new and rerolls[1].data.keeps_new, "Both rerolls replace original dice exactly once")

func _test_bribe_and_prepared_hex() -> void:
	for choice: String in ["accept", "decline"]:
		var game: RefCounted = _fixture("p1", "p3")
		game.state.data.heroes.p4.prepared_hex = {"target_id": "p1", "expires_planning_round": 2}
		_send(game, {"type": "attack", "player_id": "p1", "target_id": "p3"})
		_check(game.state.data.heroes.p4.prepared_hex.is_empty(), "Prepared Hex triggers once when target declares combat")
		_check(game.state.data.pending_combat.modifiers.attacker_die_modifier == -1, "Prepared Hex supplies explicit die modifier")
		_check(game.state.data.pending_reaction.kind == "bribe_offer", "Only Merchant receives Bribe offer")
		_send(game, {"type": "resolve_reaction", "player_id": "p3", "choice": "accept"})
		_check(game.state.data.pending_reaction.kind == "bribe_response", "Attacker explicitly decides offered Bribe")
		_send(game, {"type": "resolve_reaction", "player_id": "p1", "choice": choice})
		if choice == "accept":
			_check(game.state.data.heroes.p1.gold == 6 and game.state.data.heroes.p3.gold == 2, "Accepted Bribe transfers exactly two Gold")
			_check(game.state.data.pending_combat.is_empty() and game.current_actor() == "p3", "Accepted Bribe consumes attacker action and preserves defender action")
		else:
			_check(game.state.data.pending_combat.modifiers.defender_modifiers.bribe_refused == 1, "Refused Bribe grants +1 Defence")
			_check(game.state.data.heroes.p3.gold == 4, "Refused offer does not transfer Gold")
			_finish_combat(game)
		_check(game.state.data.heroes.p3.flags.bribe_used, "Bribe offer is once per round")

func _test_down_every_class_and_displacement() -> void:
	for defender: String in ["p1", "p2", "p3", "p4"]:
		var attacker: String = "p2" if defender == "p1" else "p1"
		var game: RefCounted = _fixture(attacker, defender)
		var hero: Dictionary = game.state.data.heroes[defender]
		game.state.data.heroes[attacker].attack = 20
		hero.hp = 1
		hero.fate = 4
		hero.relics = ["test_relic"] if defender == "p1" else []
		_send(game, {"type": "attack", "player_id": attacker, "target_id": defender})
		_finish_combat(game)
		_check(hero.hex == hero.sanctuary and hero.hp == ceili(float(hero.max_hp) * 0.6), "Downed " + defender + " immediately recovers at 60% in Sanctuary")
		_check(hero.statuses.has("recovering") and hero.flags.downed_this_round, "Downed hero receives Recovering and healing flag")
		_check(hero.fate == 5, "Down and severe loss share once-per-round capped Fate compensation")
		_check(game.current_actor() == defender, "Downed defender keeps next action")
		_check(not game.legal_actions(defender).is_empty(), "Recovering hero may act")
		_check(game.state.data.ground_loot["0,0"].gold == 1, "Decisive combat drops one Gold at contested hex even on down")
		if defender == "p1": _check(hero.relics.is_empty() and game.state.data.ground_loot["0,0"].relics == ["test_relic"], "Defeat drops exactly one carried Relic")
		else: _check(hero.gold == 1, "Defeat loses up to two Gold after decisive drop")
		var recovered_hp: int = hero.hp
		_next_round(game)
		_check(hero.hp == recovered_hp and not hero.statuses.has("recovering"), "Downed hero skips same-round regeneration; Recovering ends at next World")
	var blocked: RefCounted = _fixture()
	blocked.state.data.heroes.p1.attack = 20
	for neighbor: String in Hex.neighbors("0,0"):
		if neighbor != "-1,0": blocked.state.data.map.hexes[neighbor].terrain = "mountain"
	_send(blocked, {"type": "attack", "player_id": "p1", "target_id": "p2"})
	_finish_combat(blocked)
	_check(blocked.state.data.heroes.p2.hp == 8 and blocked.state.data.heroes.p2.hex == "0,0", "Blocked displacement adds one damage after Guard reduces decisive hit to three")

func _test_monsters_and_rest() -> void:
	var game: RefCounted = _fixture()
	game.state.data.heroes.p2.hex = game.state.data.heroes.p2.sanctuary
	var monster: Dictionary = game.state.data.monsters.monster_1
	var camp: Dictionary = game.state.data.map.locations[monster.camp_id]
	var adjacent: String = ""
	for candidate: String in Hex.neighbors(monster.hex):
		if game.state.data.map.hexes.has(candidate) and game.state.data.map.hexes[candidate].terrain not in ["mountain", "water"] and not game._is_occupied(candidate) and game._sanctuary_allowed("p1", candidate):
			adjacent = candidate
			break
	game.state.data.heroes.p1.hex = adjacent
	game.state.data.heroes.p1.attack = 20
	_send(game, {"type": "attack", "player_id": "p1", "target_id": monster.id})
	_finish_combat(game)
	_check(monster.hp == 0 and camp.cleared and game.state.data.heroes.p1.gold == 6, "Wolf Pack uses shared damage and pays Gold once on permanent defeat")
	_check(not Battle.targets(game, "p1").has(monster.id), "Defeated monster is no longer an attack target")
	var actor: String = game.current_actor()
	var hero: Dictionary = game.state.data.heroes[actor]
	hero.hex = hero.sanctuary
	hero.hp -= 2
	_send(game, {"type": "special", "player_id": actor, "special_id": "rest"})
	_check(hero.hp == hero.max_hp, "Rest heals three at Sanctuary without exceeding maximum")

func _test_ancient_capture_and_upgrade() -> void:
	var game: RefCounted = _fixture()
	game.state.data.heroes.p2.hex = game.state.data.heroes.p2.sanctuary
	game.state.data.heroes.p1.hex = "0,0"
	_send(game, {"type": "capture", "player_id": "p1"})
	_check(game.state.data.commitments.has("p1") and game.state.data.map.locations.worldspire.owner_id == "", "Ancient capture begins a public commitment without ownership")
	_pass_to(game, "p1")
	_send(game, {"type": "capture", "player_id": "p1"})
	_check(not game.state.data.commitments.has("p1") and game.state.data.map.locations.worldspire.owner_id == "p1", "Ancient capture completes on next scheduled action")
	_next_round(game)
	_check(game.state.data.heroes.p1.power == 4, "Ancient Tower pays two Power")
	var canceled: RefCounted = _fixture()
	canceled.state.data.heroes.p2.hex = canceled.state.data.heroes.p2.sanctuary
	canceled.state.data.heroes.p1.hex = "0,0"
	_send(canceled, {"type": "capture", "player_id": "p1"})
	_pass_to(canceled, "p1")
	_send(canceled, {"type": "pass", "player_id": "p1"})
	_check(canceled.state.data.commitments.is_empty(), "Choosing another action cancels Ancient commitment")
	var contested: RefCounted = _fixture()
	contested.state.data.heroes.p1.attack = 20
	contested.state.data.commitments.p2 = {"kind": "ancient_capture", "location_id": "worldspire", "hex": "0,0", "round": 1, "cycle": 1}
	_send(contested, {"type": "attack", "player_id": "p1", "target_id": "p2"})
	_finish_combat(contested)
	_check(not contested.state.data.commitments.has("p2"), "Successful enemy contest cancels Ancient commitment")
	var upgrade: RefCounted = _fixture()
	var tower: Dictionary = upgrade.state.data.map.locations.minor_1
	upgrade.state.data.heroes.p1.hex = tower.hex
	tower.owner_id = "p1"
	upgrade.state.data.heroes.p1.controlled_locations = [tower.id]
	upgrade.state.data.heroes.p1.gold = 8
	_send(upgrade, {"type": "upgrade", "player_id": "p1"})
	_check(tower.level == 2 and upgrade.state.data.heroes.p1.gold == 5, "Level two costs three Gold")
	_pass_to(upgrade, "p1")
	_send(upgrade, {"type": "upgrade", "player_id": "p1"})
	_check(tower.level == 3 and upgrade.state.data.heroes.p1.gold == 0, "Level three costs five Gold")
	_next_round(upgrade)
	_check(upgrade.state.data.heroes.p1.power == 4, "Level three improves income by one")
	_start(upgrade)
	_pass_to(upgrade, "p1")
	_reject(upgrade, {"type": "upgrade", "player_id": "p1"})

func _test_planning_and_snare() -> void:
	var game: RefCounted = Rules.new(812)
	game.state.data.heroes.p1.hex = "-1,0"
	game.state.data.heroes.p2.hex = "1,0"
	game.state.data.heroes.p1.fate = 3
	game.state.data.map.hexes["-1,0"].terrain = "plains"
	game.state.data.map.hexes["1,0"].terrain = "plains"
	_send(game, {"type": "advance"})
	_send(game, {"type": "submit_plan", "player_id": "p1", "plan": {"initiative_push": true, "snare": "0,0"}})
	_send(game, {"type": "submit_plan", "player_id": "p4", "plan": {"prepared_hex": "p2"}})
	_check(game.state.data.heroes.p1.fate == 3 and game.state.data.traps.is_empty(), "Planning submissions remain stored until all ready")
	for player: String in ["p1", "p2", "p3", "p4"]: _send(game, {"type": "ready", "player_id": player})
	_check(game.state.data.heroes.p1.fate == 1 and game.state.data.heroes.p1.power == 1 and game.state.data.heroes.p4.power == 1, "Plans charge explicit Fate/Power costs together")
	_check(game.state.data.heroes.p4.prepared_hex.target_id == "p2", "Prepared Hex records visible enemy")
	var score: int = game.state.data.initiative_scores.p1
	_check(score >= 8 and score <= 10, "Planning Push adds exactly two to Speed plus d3")
	_send(game, {"type": "advance"})
	game.state.data.initiative_order = ["p2", "p1", "p3", "p4"]
	game.state.data.next_cycle_order = game.state.data.initiative_order.duplicate()
	_send(game, {"type": "move", "player_id": "p2", "target": "0,0"})
	_check(game.state.data.heroes.p2.hex == "0,0" and game.state.data.traps.is_empty(), "Enemy entering Snare triggers and consumes trap")
	_check(game.state.data.cycle_2_modifiers.p2 == -2, "Snare modifies next cycle by minus two")
	_check(game.state.data.initiative_order == ["p2", "p1", "p3", "p4"], "Snare does not reorder current cycle or erase actions")
	_check(game.state.data.next_cycle_order.size() == 4, "All heroes retained in changed next-cycle order")

func _test_challenge_and_forced_march() -> void:
	var game: RefCounted = _fixture("p1", "p2")
	game.state.data.heroes.p1.hex = "-1,1"
	game.state.data.heroes.p2.hex = "0,0"
	for key: String in ["-1,1", "0,1", "1,1"]: game.state.data.map.hexes[key].terrain = "plains"
	# Request a legal route that approaches then leaves the Warlord's adjacency.
	var target: String = ""
	for candidate: String in game.legal_actions("p1").move.targets:
		var path: Array = game.legal_actions("p1").move.targets[candidate].path
		for index: int in range(2, path.size()):
			if Hex.distance(path[index - 1], "0,0") == 1 and Hex.distance(path[index], "0,0") > 1:
				target = candidate
				break
		if not target.is_empty(): break
	_check(not target.is_empty(), "Challenge fixture has eligible route")
	if not target.is_empty():
		var origin: String = game.state.data.heroes.p1.hex
		_send(game, {"type": "move", "player_id": "p1", "target": target})
		_check(game.state.data.pending_reaction.get("kind", "") == "challenge", "Leaving adjacency after movement opens Warlord Challenge")
		_check(game.state.data.heroes.p1.hex != origin, "Challenge never cancels all movement before first step")
		_send(game, {"type": "resolve_reaction", "player_id": "p2", "choice": "accept"})
		_check(game.state.data.heroes.p2.flags.challenge_used and Hex.distance(game.state.data.heroes.p1.hex, "0,0") == 1, "Challenge halts movement adjacent and spends once-per-round use")
		_check(game.current_actor() == "p2", "Challenger retains normal scheduled action")
		var forced: Dictionary = game.legal_actions("p2").special.choices.forced_march.targets
		var destination: String = forced.keys()[0]
		_send(game, {"type": "special", "player_id": "p2", "special_id": "forced_march", "target": destination})
		_check(game.state.data.heroes.p2.power == 1 and game.state.data.cycle_2_modifiers.p2 == 2, "Forced March spends one Power and adds two initiative next cycle")

func _test_pending_snapshot_rejections() -> void:
	var game: RefCounted = _fixture()
	_send(game, {"type": "attack", "player_id": "p1", "target_id": "p2"})
	for field: String in ["stage", "attacker", "defender", "monster", "phase"]:
		var bad: Dictionary = game.snapshot()
		match field:
			"stage": bad.pending_combat.stage = "unknown"
			"attacker": bad.pending_combat.attacker_id = "p9"
			"defender": bad.pending_combat.defender_id = "p9"
			"monster": bad.monsters.monster_1.definition_id = "unknown"
			"phase": bad.phase = "resolution"
		_check(Rules.from_snapshot(bad) == null, "Reject malformed combat snapshot: " + field)
	_send(game, {"type": "choose_stance", "player_id": "p1", "stance": "guard"})
	_send(game, {"type": "choose_stance", "player_id": "p2", "stance": "guard"})
	for field: String in ["calculation", "dice", "modifiers"]:
		var bad: Dictionary = game.snapshot()
		match field:
			"calculation": bad.pending_combat.calculation = {}
			"dice": bad.pending_combat.dice.attacker = 7
			"modifiers": bad.pending_combat.modifiers.attacker_modifier = "unknown"
		_check(Rules.from_snapshot(bad) == null, "Reject malformed revealed combat continuation: " + field)
