extends RefCounted
var is_valid: bool = false
var reason_code: String = "INVALID_COMMAND"
var message: String = "Invalid command"
var events: Array = []
var state_version: int = 0

func _init(valid: bool = false, reason: String = "INVALID_COMMAND", detail: String = "Invalid command", version: int = 0, emitted: Array = []) -> void:
	is_valid = valid
	reason_code = reason
	message = detail
	state_version = version
	events = emitted.duplicate(true)

func to_dict() -> Dictionary:
	return {"is_valid": is_valid, "reason_code": reason_code, "message": message, "events": events.duplicate(true), "state_version": state_version}
