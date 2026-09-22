extends RefCounted
## Typed accessors around the portable dictionary backing a hero.
var data: Dictionary

func _init(values: Dictionary = {}) -> void:
	data = values

func id() -> String:
	return str(data.get("id", ""))

func health() -> int:
	return int(data.get("hp", 0))

func position() -> String:
	return str(data.get("hex", ""))

func to_dict() -> Dictionary:
	return data.duplicate(true)
