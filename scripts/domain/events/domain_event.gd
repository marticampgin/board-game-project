extends RefCounted
var sequence: int
var type: String
var round_number: int
var phase: String
var actor_id: String
var visibility: String
var data: Dictionary

func _init(event_sequence: int = 0, event_type: String = "", round_value: int = 1, phase_id: String = "world", actor: String = "", values: Dictionary = {}, scope: String = "public") -> void:
	sequence = event_sequence
	type = event_type
	round_number = round_value
	phase = phase_id
	actor_id = actor
	visibility = scope
	data = values.duplicate(true)

func to_dict() -> Dictionary:
	return {"sequence": sequence, "type": type, "round": round_number, "phase": phase, "actor_id": actor_id, "visibility": visibility, "data": data.duplicate(true)}
