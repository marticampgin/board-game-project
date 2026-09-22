extends RefCounted
## Projection and guard tests complement the separate-process ENet acceptance.
const Rules = preload("res://scripts/domain/game_rules.gd")
const State = preload("res://scripts/domain/state/game_state.gd")
const Observation = preload("res://scripts/network/observation.gd")
const Gate = preload("res://scripts/network/command_gate.gd")
const Session = preload("res://scripts/network/network_session.gd")
const ActionLog = preload("res://scripts/services/action_logger.gd")
var errors: Array[String] = []

func run() -> Array[String]:
	errors.clear()
	_test_projection()
	_test_sealed_combat()
	_test_protocol_gate()
	_test_timeout_identity()
	return errors

func _check(condition: bool, message: String) -> void:
	if not condition: errors.append(message)

func _test_projection() -> void:
	var game: RefCounted = Rules.new(20260922)
	game.state.data.plans = {"p1": {"snare": "private_plan_one"}, "p2": {"secret": "private_plan_two"}}
	game.state.data.heroes.p4.prepared_hex = {"target_id": "private_hex_target"}
	game.state.data.heroes.p4.occult_hint = {"regions": ["private_occult_region"]}
	game.state.data.traps = {"p1": {"owner_id": "p1", "hex": "0,0", "kind": "snare", "expires_round": 1}}
	game._emit("SnarePrepared", "p1", {"kind": "secret_trap_type"}, "owner_only")
	game._emit("RelicDropped", "p1", {"hex": "0,0", "relic_id": "relic_monster_3_1"})
	game._emit("GroundLootCollected", "p3", {"hex": "0,0", "relics": ["relic_ruin_1", "relic_monster_3_1"]})
	var before: String = game.checksum()
	var first: Dictionary = Observation.build(game, "p1")
	var second: Dictionary = Observation.build(game, "p2")
	var public_state: Dictionary = Observation.project_state(game.snapshot(), "")
	_check(first.public_checksum == second.public_checksum, "Public checksum must match across different private views")
	_check(first.view_checksum != second.view_checksum, "Private view checksums should distinguish authorized observations")
	_check(Observation.verify(first), "Fresh view must verify its canonical checksum")
	var decoded: Dictionary = State.normalize(JSON.parse_string(JSON.stringify(first)))
	_check(Observation.verify(decoded), "View checksum must survive real JSON normalization")
	_check(first.state.plans.keys() == ["p1"] and second.state.plans.keys() == ["p2"], "Only the recipient's plan may leave the host")
	_check(public_state.plans.is_empty(), "Public checksum projection must contain no private plans")
	var wire: String = State.canonical_json(second)
	for secret: String in ["private_plan_one", "private_hex_target", "private_occult_region", "secret_trap_type", "relic_monster_3_1", "relic_ruin_1", '"master_seed"', '"rng"', '"commands"', '"map_report"']:
		_check(not wire.contains(secret), "Secret reached p2 wire projection: " + secret)
	_check(not second.state.heroes.p4.has("prepared_hex") and not second.state.heroes.p4.has("occult_hint"), "Rival preparation/hints must be absent, not merely hidden in UI")
	_check(second.state.traps.values()[0].keys().size() == 3, "Rival trap must be a generic hex warning without owner/type")
	var hidden_count: int = 0
	for location_id: String in game.state.data.map.locations:
		var source: Dictionary = game.state.data.map.locations[location_id]
		if source.discovered_by.has("p2"): continue
		if source.kind in ["worldspire", "ancient_tower"]:
			_check(second.state.map.locations[location_id].trait == "", "Undiscovered landmark trait leaked")
		else:
			hidden_count += 1
			var alias: String = "site_" + str(source.hex)
			_check(not second.state.map.locations.has(location_id), "Undiscovered encoded location ID leaked")
			_check(second.state.map.locations.has(alias) and second.state.map.locations[alias].kind == "unknown", "Unknown site must render without its kind")
			_check(second.state.map.hexes[source.hex].location_id == alias, "Unknown site alias must match its tile reference")
	_check(hidden_count > 0, "Privacy fixture must actually contain undiscovered sites")
	for monster: Dictionary in second.state.monsters.values():
		_check(game.state.data.map.locations[monster.camp_id].discovered_by.has("p2"), "Undiscovered monster details leaked")
	var baseline_public: String = first.public_checksum
	game.state.data.plans.p2.secret = "changed_hidden_plan"
	game.state.data.heroes.p4.prepared_hex.target_id = "other_hidden_target"
	_check(Observation.build(game, "p1").public_checksum == baseline_public, "Private-only changes must not alter the shared public checksum")
	# Projection itself must not mutate any authoritative arrays/dictionaries.
	game.state.data.plans.p2.secret = "private_plan_two"
	game.state.data.heroes.p4.prepared_hex.target_id = "private_hex_target"
	_check(game.checksum() == before, "Observation building mutated authority state")
	first.state.heroes.p1.hp = -100
	_check(game.state.data.heroes.p1.hp > 0, "View must not retain mutable authority references")
	_check(not Observation.verify(first), "Tampered view must fail its integrity checksum")

func _test_sealed_combat() -> void:
	var game: RefCounted = Rules.new(88)
	game.state.data.pending_combat = {"attacker_id": "p2", "defender_id": "p3", "defender_kind": "hero", "stage": "stances",
		"stances": {"p2": "assault"}, "dice": {}, "calculation": {}, "modifiers": {}}
	var attacker: Dictionary = Observation.build(game, "p2")
	var defender: Dictionary = Observation.build(game, "p3")
	_check(attacker.state.pending_combat.stances == {"p2": "assault"}, "Attacker must receive its own sealed selection")
	_check(defender.state.pending_combat.stances.is_empty(), "Defender must not receive attacker's sealed stance")
	_check(not defender.state.pending_combat.has("dice") and not defender.state.pending_combat.has("calculation"), "Unrolled/reveal-only combat fields must not be transported")
	var prior: String = defender.public_checksum
	game.state.data.pending_combat.stances.p2 = "counter"
	_check(Observation.build(game, "p3").public_checksum == prior, "Changing a sealed stance must not change public state checksum")
	game.state.data.pending_combat.stage = "fate_attacker"
	game.state.data.pending_combat.stances.p3 = "guard"
	game.state.data.pending_combat.dice = {"attacker": 3, "defender": 4}
	_check(Observation.build(game, "p1").state.pending_combat.stances.size() == 2, "Revealed stance pair must become public")
	game.state.data.pending_exploration = {"player_id": "p2", "kind": "ruin", "choices": {"secret_reward": {}}, "dark_bargain": false}
	_check(not Observation.build(game, "p1").state.pending_exploration.has("choices"), "Alternative reward choices must stay owner-private")

func _test_protocol_gate() -> void:
	var command: Dictionary = {"type": "pass", "player_id": "p2", "expected_version": 17}
	_check(Gate.check("p2", 0, 1, command, true).is_valid, "Authenticated own-seat command should reach domain validation")
	var duplicate: Dictionary = Gate.check("p2", 1, 1, command, true)
	_check(not duplicate.is_valid and duplicate.next_sequence == 2, "Duplicate sequence must reject without consuming another sequence")
	var skipped: Dictionary = Gate.check("p2", 1, 4, command, true)
	_check(not skipped.is_valid and skipped.next_sequence == 2, "Out-of-order sequence must preserve required next sequence")
	var forged: Dictionary = command.duplicate()
	forged.player_id = "p3"
	_check(Gate.check("p2", 0, 1, forged, true).reason_code == "NETWORK_SEAT", "Forged rival seat must reject at transport boundary")
	var missing: Dictionary = command.duplicate()
	missing.erase("expected_version")
	_check(Gate.check("p2", 0, 1, missing, true).reason_code == "NETWORK_VERSION_REQUIRED", "Client must provide expected authoritative version")
	missing.expected_version = "17"
	_check(not Gate.check("p2", 0, 1, missing, true).is_valid, "String version must not silently coerce")
	_check(Gate.check("p2", 0, 1, {"type": "advance"}, true).reason_code == "NETWORK_HOST_ONLY", "Client phase advancement must reject")
	_check(Gate.check("", 0, 1, command, true).reason_code == "NETWORK_UNAUTHENTICATED", "Unseated peer must reject")
	_check(Gate.check("p2", 0, 1, command, false).reason_code == "NETWORK_NOT_STARTED", "Lobby cannot accept gameplay before host starts")
	_check(Gate.check("p2", 0, 1, forged, true).next_sequence == 2, "A correctly ordered illegal intent consumes its transport sequence")

func _test_timeout_identity() -> void:
	var session: Node = Session.new()
	session.rules = Rules.new(10)
	session.is_host = true
	session.started = true
	session.auto_drive = false
	session.planning_timeout_seconds = 10.0
	session.action_log = ActionLog.new()
	var advanced: Dictionary = session.submit_as_host({"type": "advance"})
	_check(advanced.is_valid, "Timeout fixture must enter planning through command path")
	session.tick(9.0)
	_check(session.rules.state.data.ready.is_empty(), "Planning must not time out before deadline")
	var changed: Dictionary = session.submit_as_host({"type": "submit_plan", "player_id": "p2", "plan": {}})
	_check(changed.is_valid, "Planning edit fixture must be legal")
	session.tick(2.0)
	_check(session.rules.state.data.ready.has("p1"), "Another player's plan must not reset p1's original deadline")
	for index: int in range(3): session.tick(0.0)
	_check(session.rules.state.data.phase == "initiative", "Simultaneous planning timeouts must ready all seats without erasing submitted plans")
	_check(session.action_log.entries.size() == 6, "Every timeout must use the common audited domain command path")
	_check(Session._safe_default("p2", {"resolve_reaction": {"choices": ["accept", "decline"]}}).choice == "decline", "Optional reaction timeout must decline")
	_check(Session._safe_default("p2", {"choose_stance": {}}).stance == "guard", "Mandatory stance timeout must use Guard")
	_check(Session._safe_default("p2", {"pass": {}}).type == "pass", "Inactive scheduled action timeout must Pass")
	session.free()
