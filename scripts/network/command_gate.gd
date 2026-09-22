extends RefCounted
## Transport ordering is separate from authoritative gameplay state.
const State = preload("res://scripts/domain/state/game_state.gd")

static func check(player_id: String, last_sequence: int, sequence: int, command: Dictionary, started: bool) -> Dictionary:
	var next: int = last_sequence + 1
	if sequence != next: return _reject("NETWORK_SEQUENCE", "Expected client sequence %d" % next, next)
	next += 1 # Consume one correctly ordered intent even when the intent is illegal.
	if player_id.is_empty(): return _reject("NETWORK_UNAUTHENTICATED", "Join a seat before submitting commands", next)
	if not started: return _reject("NETWORK_NOT_STARTED", "The host has not started this match", next)
	if not State.is_serializable(command) or JSON.stringify(command).length() > 16384:
		return _reject("NETWORK_MALFORMED", "Command exceeds the supported data envelope", next)
	if command.get("type", "") == "advance": return _reject("NETWORK_HOST_ONLY", "The host advances shared phases", next)
	if command.get("player_id", "") != player_id: return _reject("NETWORK_SEAT", "A client may only act for its assigned seat", next)
	if not command.has("expected_version") or not command.expected_version is int:
		return _reject("NETWORK_VERSION_REQUIRED", "An integer expected_version is required", next)
	return {"is_valid": true, "reason_code": "OK", "message": "Intent authenticated", "next_sequence": next}

static func _reject(code: String, message: String, next: int) -> Dictionary:
	return {"is_valid": false, "reason_code": code, "message": message, "next_sequence": next}
