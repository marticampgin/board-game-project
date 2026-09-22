extends SceneTree
## No addon required. Failures are collected so a CI run reports every affected suite.

const HexMapTests = preload("res://tests/unit/test_hex_map.gd")
const RulesTests = preload("res://tests/unit/test_rules.gd")
const AcceptanceTests = preload("res://tests/integration/test_acceptance.gd")

func _initialize() -> void:
	var failures: Array[String] = []
	var started: int = Time.get_ticks_msec()
	for suite: Dictionary in [
		{"name": "hex, RNG, movement and 100 map seeds", "script": HexMapTests},
		{"name": "rules and state serialization", "script": RulesTests},
		{"name": "three-round vertical slice and replay", "script": AcceptanceTests}
	]:
		var suite_started: int = Time.get_ticks_msec()
		var instance: RefCounted = suite["script"].new()
		var errors: Array[String] = instance.run()
		print("%s %s (%d ms)" % ["PASS" if errors.is_empty() else "FAIL", suite["name"], Time.get_ticks_msec() - suite_started])
		for error: String in errors:
			failures.append("%s: %s" % [suite["name"], error])
	if OS.get_cmdline_user_args().has("--self-test-failure"):
		failures.append("Intentional runner failure: verifying a nonzero process exit.")
	for error: String in failures:
		printerr("  FAIL: ", error)
	print("%s: 3 suites, %d failure(s), %d ms" % ["PASS" if failures.is_empty() else "FAIL", failures.size(), Time.get_ticks_msec() - started])
	quit(0 if failures.is_empty() else 1)
