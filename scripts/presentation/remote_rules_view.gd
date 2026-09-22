extends RefCounted
## A read-only presentation facade. It cannot simulate or restore a game.
const State = preload("res://scripts/domain/state/game_state.gd")
const Catalog = preload("res://scripts/domain/definitions/definition_catalog.gd")
var state: RefCounted
var definitions := Catalog.new()
var observation: Dictionary = {}

func _init(view: Dictionary) -> void:
	update(view)

func update(view: Dictionary) -> void:
	observation = view.duplicate(true)
	state = State.new(observation.get("state", {}))

func snapshot() -> Dictionary:
	return state.to_dict()

func checksum() -> String:
	return observation.get("view_checksum", "")

func current_actor() -> String:
	if state.data.get("phase", "") not in ["cycle_1", "cycle_2"]: return ""
	var order: Array = state.data.get("initiative_order", [])
	var index: int = int(state.data.get("current_actor_index", 0))
	return str(order[index]) if index >= 0 and index < order.size() else ""

func legal_actions(player_id: String) -> Dictionary:
	return observation.get("legal_actions", {}).duplicate(true) if player_id == observation.get("player_id", "") else {}

func victory_progress(player_id: String) -> Dictionary:
	return observation.get("victory_progress", {}).get(player_id, {}).duplicate(true)
