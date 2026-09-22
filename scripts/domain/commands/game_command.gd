extends RefCounted
## Typed envelope for adapters; payload contains only serializable domain values.
var type: String
var player_id: String
var command_id: String
var expected_phase: String
var expected_version: int = -1
var payload: Dictionary

func _init(command_type: String = "", actor: String = "", values: Dictionary = {}) -> void:
	type = command_type
	player_id = actor
	payload = values.duplicate(true)

func to_dict() -> Dictionary:
	var result: Dictionary = payload.duplicate(true)
	result["type"] = type
	if not player_id.is_empty():
		result["player_id"] = player_id
	if not command_id.is_empty():
		result["command_id"] = command_id
	if not expected_phase.is_empty():
		result["expected_phase"] = expected_phase
	if expected_version >= 0:
		result["expected_version"] = expected_version
	return result
