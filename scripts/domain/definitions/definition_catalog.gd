extends RefCounted
## Immutable definition loading is shared by validation, rules, and debug exports.

var classes: Dictionary = {}
var tower_traits: Dictionary = {}
var rules: Dictionary = {}
var errors: Array[String] = []

func _init() -> void:
	classes = _load_table("res://data/classes.json")
	tower_traits = _load_table("res://data/tower_traits.json")
	rules = _load_table("res://data/rules.json")
	for class_id: String in classes:
		var definition: Dictionary = classes[class_id]
		for field: String in ["hp", "attack", "defence", "speed", "move"]:
			if not definition.has(field) or not (definition[field] is float or definition[field] is int) or int(definition[field]) < 1:
				errors.append("Invalid class %s field %s" % [class_id, field])
		if definition.get("id", "") != class_id:
			errors.append("Class ID mismatch: %s" % class_id)
	for required: String in ["ranger", "warlord", "merchant", "cultist"]:
		if not classes.has(required):
			errors.append("Missing required class: %s" % required)
	for trait_id: String in ["watchtower", "fortress"]:
		if not tower_traits.has(trait_id):
			errors.append("Missing required tower trait: %s" % trait_id)

func _load_table(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		errors.append("Missing definition file: " + path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		errors.append("Invalid JSON definition: " + path)
		return {}
	return parsed

func export_table() -> Dictionary:
	return {"classes": classes.duplicate(true), "tower_traits": tower_traits.duplicate(true), "rules": rules.duplicate(true), "errors": errors.duplicate()}
