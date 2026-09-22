extends SceneTree
## No addon required. Failures are collected so a CI run reports every affected suite.

const HexMapTests = preload("res://tests/unit/test_hex_map.gd")
const RulesTests = preload("res://tests/unit/test_rules.gd")
const AcceptanceTests = preload("res://tests/integration/test_acceptance.gd")
const CombatTests = preload("res://tests/unit/test_combat.gd")
const BotTests = preload("res://tests/integration/test_bots.gd")
const Milestone2Tests = preload("res://tests/unit/test_milestone2.gd")
const PersistenceTests = preload("res://tests/unit/test_persistence.gd")
const Milestone3Tests = preload("res://tests/unit/test_milestone3.gd")
const VictoryRouteTests = preload("res://tests/integration/test_victory_routes.gd")
const CompleteMatchTests = preload("res://tests/integration/test_complete_matches.gd")
const ContentTests = preload("res://tests/unit/test_content.gd")

func _initialize() -> void:
	var failures: Array[String] = []
	var started: int = Time.get_ticks_msec()
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	var selected: String = ""
	var selected_index: int = arguments.find("--suite")
	if selected_index >= 0 and selected_index + 1 < arguments.size():
		selected = arguments[selected_index + 1]
	var count: int = 0
	var suites: Array[Dictionary] = [
		{"id": "hex", "name": "hex, RNG, movement and 100 map seeds", "script": HexMapTests},
		{"id": "rules", "name": "rules and state serialization", "script": RulesTests},
		{"id": "combat", "name": "combat stance matrix and outcome bands", "script": CombatTests},
		{"id": "milestone2", "name": "conflict, Fate, class timing and recovery", "script": Milestone2Tests},
		{"id": "persistence", "name": "atomic snapshots and recovery", "script": PersistenceTests},
		{"id": "milestone3", "name": "economy, equipment and victory timing", "script": Milestone3Tests},
		{"id": "content", "name": "world events, exploration rewards and equipment", "script": ContentTests},
		{"id": "acceptance", "name": "three-round vertical slice and replay", "script": AcceptanceTests},
		{"id": "bots", "name": "20-round four-bot conflict or victory and replay", "script": BotTests},
		{"id": "victory_routes", "name": "fresh-command proof of all three victory routes", "script": VictoryRouteTests},
		{"id": "complete_matches", "name": "25 complete deterministic bot matches", "script": CompleteMatchTests}
	]
	for suite: Dictionary in suites:
		if not selected.is_empty() and suite["id"] != selected: continue
		count += 1
		var suite_started: int = Time.get_ticks_msec()
		var instance: RefCounted = suite["script"].new()
		var errors: Array[String] = instance.run()
		print("%s %s (%d ms)" % ["PASS" if errors.is_empty() else "FAIL", suite["name"], Time.get_ticks_msec() - suite_started])
		for error: String in errors:
			failures.append("%s: %s" % [suite["name"], error])
	if count == 0:
		failures.append("Unknown test suite: " + selected)
	if arguments.has("--self-test-failure"):
		failures.append("Intentional runner failure: verifying a nonzero process exit.")
	for error: String in failures:
		printerr("  FAIL: ", error)
	print("%s: %d suites, %d failure(s), %d ms" % ["PASS" if failures.is_empty() else "FAIL", count, failures.size(), Time.get_ticks_msec() - started])
	quit(0 if failures.is_empty() else 1)
