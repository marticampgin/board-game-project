extends Node
## Presentation-only preferences and generated audio. Never touches game RNG.
const PATH := "user://settings.cfg"
var values: Dictionary = {"master": 0.8, "music": 0.5, "sfx": 0.65, "ui": 0.45, "reduced_motion": false, "animation_speed": 1.0, "ui_scale": 1.0, "hints": true}
var ui_player: AudioStreamPlayer
var effect_player: AudioStreamPlayer

func _ready() -> void:
	for name_value: String in ["Music", "SFX", "UI"]:
		if AudioServer.get_bus_index(name_value) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, name_value)
			AudioServer.set_bus_send(AudioServer.bus_count - 1, "Master")
	var config := ConfigFile.new()
	if config.load(PATH) == OK:
		for key: String in values:
			var stored: Variant = config.get_value("presentation", key, values[key])
			if typeof(stored) == typeof(values[key]): values[key] = stored
	for channel: String in ["master", "music", "sfx", "ui"]: _volume(channel)
	ui_player = AudioStreamPlayer.new()
	ui_player.bus = "UI"
	ui_player.stream = _tone(510.0, 0.045)
	add_child(ui_player)
	effect_player = AudioStreamPlayer.new()
	effect_player.bus = "SFX"
	effect_player.stream = _tone(290.0, 0.18)
	add_child(effect_player)

func set_value(key: String, value: Variant) -> void:
	if not values.has(key): return
	values[key] = value
	if key in ["master", "music", "sfx", "ui"]: _volume(key)
	var config := ConfigFile.new()
	for item: String in values: config.set_value("presentation", item, values[item])
	config.save(PATH)
	if OS.has_feature("web"): JavaScriptBridge.force_fs_sync()

func _volume(channel: String) -> void:
	var bus: String = {"master": "Master", "music": "Music", "sfx": "SFX", "ui": "UI"}[channel]
	var index: int = AudioServer.get_bus_index(bus)
	var volume: float = clampf(float(values[channel]), 0.0, 1.0)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(volume, 0.0001)))
	AudioServer.set_bus_mute(index, volume <= 0.001)

func click() -> void:
	if ui_player != null: ui_player.play()

func cue() -> void:
	if effect_player != null: effect_player.play()

static func _tone(frequency: float, duration: float) -> AudioStreamWAV:
	var sample_rate: int = 22050
	var count: int = int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(count * 2)
	for sample: int in count:
		var t: float = float(sample) / sample_rate
		var envelope: float = sin(PI * float(sample) / count)
		var value: int = int(sin(TAU * frequency * t) * envelope * 3500)
		data.encode_s16(sample * 2, value)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream
