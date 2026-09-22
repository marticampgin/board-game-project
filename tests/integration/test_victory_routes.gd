extends RefCounted

const Simulation = preload("res://tools/match_simulation.gd")

func run() -> Array[String]:
	var errors: Array[String] = []
	for route: String in ["conquest", "dominion", "ascension"]:
		# Each scenario begins with the real generator and normal starting resources.
		# Other seats make legal no-change plans and Pass; no state or winner is injected.
		var report: Dictionary = Simulation.run_match(20260922, 40, {"p1": route, "p2": "passive", "p3": "passive", "p4": "passive"})
		if not report["finished"] or report["victory"].get("route", "") != route:
			errors.append("Fresh-game %s proof failed: %s" % [route, JSON.stringify(report)])
		elif not report["victory"].get("winners", []).has("p1"):
			errors.append("Fresh-game %s proof produced the wrong winner" % route)
		if not report["replay_matches"]: errors.append("Fresh-game %s proof failed replay" % route)
		print("Victory route proof: %s, round %s, %s commands, %s" % [route, report["rounds"], report["commands"], report["stop_reason"]])
	return errors
