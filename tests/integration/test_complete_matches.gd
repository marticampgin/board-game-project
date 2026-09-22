extends RefCounted

const Simulation = preload("res://tools/match_simulation.gd")

func run() -> Array[String]:
	var errors: Array[String] = []
	var reports: Array[Dictionary] = []
	for seed_value: int in range(1, 26):
		var report: Dictionary = Simulation.run_match(seed_value, 40)
		reports.append(report)
		if not report["finished"]:
			errors.append("Seed %s did not finish legally: %s" % [seed_value, report["stop_reason"]])
		if not report["replay_matches"]:
			errors.append("Seed %s did not replay deterministically" % seed_value)
		print("Complete match seed %s: %s, round %s, %s commands" % [seed_value, report["victory"].get("route", report["stop_reason"]), report["rounds"], report["commands"]])
	var summary: Dictionary = Simulation.summarize(reports)
	print("25-match report: ", JSON.stringify(summary))
	_write_report({"summary": summary, "matches": reports})
	return errors

func _write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	var ignore: FileAccess = FileAccess.open("res://artifacts/.gdignore", FileAccess.WRITE)
	if ignore != null: ignore.store_string("Generated validation reports.\n")
	var file: FileAccess = FileAccess.open("res://artifacts/bot_matches.json", FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(report, "  "))
