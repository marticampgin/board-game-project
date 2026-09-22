extends SceneTree
## Native GPU profile of the actual application, driven only through shared
## legal commands. Run with tools/profile_render.ps1; never use --headless.
const Main = preload("res://scenes/app/main.tscn")
const Bot = preload("res://scripts/domain/bots/simple_bot.gd")
var app: Control
var samples: Array[float] = []
var draw_calls: Array[float] = []
var command_ms: Array[float] = []
var elapsed := 0.0
var since_command := 0.0
var frames := 0
var commands := 0
var failed := false
var sampling_started := false
var render_available := false
var started_us := 0
var previous_frame_us := 0

func _initialize() -> void:
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1920, 1080)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	app = Main.instantiate()
	root.add_child.call_deferred(app)
	call_deferred("_start")

func _start() -> void:
	app.started = true
	app.welcome.hide()
	app.local_mode = "sandbox"
	app.board.motion = true
	app.board.set_meta("animation_speed", 1.0)
	app._refresh()
	started_us = Time.get_ticks_usec()
	previous_frame_us = started_us
	print("Native render profile: 2 s warm-up + 10 s sampled, 1920x1080; legal bot command every 0.20 s.")

func _process(_delta: float) -> bool:
	if app == null or not app.is_node_ready() or started_us == 0: return false
	var now_us := Time.get_ticks_usec()
	var frame_seconds := (now_us - previous_frame_us) / 1000000.0
	previous_frame_us = now_us
	elapsed = (now_us - started_us) / 1000000.0
	since_command += frame_seconds
	if elapsed > 2.0:
		sampling_started = true
		samples.append(frame_seconds * 1000.0)
		draw_calls.append(float(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
		frames += 1
		render_available = render_available or draw_calls[-1] > 0.0
	if since_command >= 0.20 and app.rules.state.data.phase != "victory":
		since_command = 0.0
		var command: Dictionary = Bot.choose(app.rules)
		if not command.is_empty():
			var start := Time.get_ticks_usec()
			var result: Dictionary = app.rules.execute(command)
			if not result.is_valid:
				push_error("Profile bot command rejected: " + JSON.stringify(result))
				failed = true
				_finish()
				return true
			app._refresh(result.get("events", []))
			if sampling_started: command_ms.append((Time.get_ticks_usec() - start) / 1000.0)
			commands += 1
	if elapsed >= 12.0:
		_finish()
		return true
	return false

func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty(): return 0.0
	var ordered: Array[float] = values.duplicate()
	ordered.sort()
	return ordered[mini(ordered.size() - 1, int(floor(fraction * ordered.size()))) ]

func _finish() -> void:
	var elapsed_sample := 0.0
	for duration: float in samples: elapsed_sample += duration / 1000.0
	var report := {
		"engine": Engine.get_version_info().string,
		"adapter": RenderingServer.get_video_adapter_name(),
		"vendor": RenderingServer.get_video_adapter_vendor(),
		"graphics_api": RenderingServer.get_video_adapter_api_version(),
		"display_server": DisplayServer.get_name(),
		"resolution": {"width": 1920, "height": 1080},
		"vsync": "disabled", "warmup_seconds": 2, "sample_seconds": elapsed_sample,
		"frames": frames, "average_fps": frames / maxf(elapsed_sample, 0.001),
		"median_frame_ms": _percentile(samples, 0.50), "p95_frame_ms": _percentile(samples, 0.95),
		"median_draw_calls": _percentile(draw_calls, 0.50), "max_draw_calls": _percentile(draw_calls, 1.0),
		"median_command_and_ui_ms": _percentile(command_ms, 0.50), "p95_command_and_ui_ms": _percentile(command_ms, 0.95),
		"commands": commands, "round": app.rules.state.data.round_number,
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"board": app.board.debug_metrics(), "render_available": render_available,
		"success": not failed and render_available,
		"scope": "Actual Main scene with legal bot commands; native GPU, offscreen window, uncapped framerate. No browser or SwiftShader."
	}
	DirAccess.make_dir_recursive_absolute("res://artifacts")
	var file := FileAccess.open("res://artifacts/presentation_profile.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	if render_available: root.get_texture().get_image().save_png("res://artifacts/presentation_profile.png")
	print(JSON.stringify(report))
	quit(0 if report.success else 1)
