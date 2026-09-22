extends RefCounted
## Immutable definition loading is shared by validation, rules, and debug exports.

var classes: Dictionary = {}
var tower_traits: Dictionary = {}
var rules: Dictionary = {}
var monsters: Dictionary = {}
var stances: Dictionary = {}
var upgrades: Dictionary = {}
var world_events: Dictionary = {}
var rewards: Dictionary = {}
var victory: Dictionary = {}
var errors: Array[String] = []

func _init() -> void:
	classes = _load_table("res://data/classes.json")
	tower_traits = _load_table("res://data/tower_traits.json")
	rules = _load_table("res://data/rules.json")
	monsters = _load_table("res://data/monsters.json")
	stances = _load_table("res://data/stances.json")
	upgrades = _load_table("res://data/upgrades.json")
	world_events = _load_table("res://data/world_events.json")
	rewards = _load_table("res://data/rewards.json")
	victory = _load_table("res://data/victory.json")
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
	return {"classes": classes.duplicate(true), "tower_traits": tower_traits.duplicate(true), "monsters": monsters.duplicate(true), "stances": stances.duplicate(true), "upgrades": upgrades.duplicate(true), "world_events": world_events.duplicate(true), "rewards": rewards.duplicate(true), "victory": victory.duplicate(true), "rules": rules.duplicate(true), "errors": errors.duplicate()}
