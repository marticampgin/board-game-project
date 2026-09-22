extends RefCounted
## Park-Miller streams keep all serialized state below 2^31 (JSON-safe).
## The multiplication stays below 2^47, safe for both 64-bit Godot and JSON.

const MODULUS: int = 2147483647
const MULTIPLIER: int = 48271
var master_seed: int = 1
var streams: Dictionary = {}

func _init(seed_value: int = 1) -> void:
	master_seed = seed_value
	for stream in ["map", "initiative", "combat"]:
		_ensure_stream(stream)

func _ensure_stream(stream: String) -> void:
	if streams.has(stream):
		return
	var state_value: int = posmod(master_seed, MODULUS - 1) + 1
	for character in stream.to_utf8_buffer():
		state_value = (state_value * 131 + int(character) + 1) % (MODULUS - 1) + 1
	streams[stream] = {"state": state_value, "draw_index": 0}

func draw(stream: String, minimum: int, maximum: int) -> Dictionary:
	assert(minimum <= maximum, "RNG minimum must not exceed maximum")
	assert(maximum - minimum + 1 <= MODULUS - 1, "RNG range exceeds generator capacity")
	_ensure_stream(stream)
	var item: Dictionary = streams[stream]
	var before := int(item.draw_index)
	var width := maximum - minimum + 1
	# Rejection sampling avoids bias when the requested range does not divide the period.
	var limit := (MODULUS - 1) - ((MODULUS - 1) % width)
	var sample := limit
	while sample >= limit:
		item.state = (int(item.state) * MULTIPLIER) % MODULUS
		sample = int(item.state) - 1
	item.draw_index = before + 1
	streams[stream] = item
	return {
		"stream": stream, "draw_index": before, "draw_index_after": before + 1,
		"minimum": minimum, "maximum": maximum, "result": minimum + (sample % width),
	}

func snapshot() -> Dictionary:
	return {"algorithm": "park_miller_48271_v1", "master_seed": master_seed, "streams": streams.duplicate(true)}

func restore(data: Dictionary) -> void:
	master_seed = int(data.get("master_seed", 1))
	streams = data.get("streams", {}).duplicate(true)
	for stream in streams:
		streams[stream].state = int(streams[stream].state)
		streams[stream].draw_index = int(streams[stream].draw_index)
	for stream in ["map", "initiative", "combat"]:
		_ensure_stream(stream)
