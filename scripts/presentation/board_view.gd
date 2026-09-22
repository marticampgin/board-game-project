extends Node3D
## Render-only board. Coordinates and legal paths come from the domain.

signal hex_selected(hex: String)
signal hex_hovered(hex: String)

const Hex = preload("res://scripts/domain/hex/hex.gd")
const TEAM: Array[Color] = [Color("6bcab2"), Color("e18d6e"), Color("e1bd70"), Color("ac99d6")]
const TERRAIN: Dictionary = {"plains": Color("547765"), "forest": Color("345949"), "swamp": Color("536774"), "mountain": Color("67727e"), "water": Color("2c647d")}

var camera: Camera3D
var tiles: Node3D
var features: Node3D
var markers: Node3D
var heroes: Dictionary = {}
var map_data: Dictionary = {}
var focus_point: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var zoom: float = 15.2
var selected: String = ""
var hovered: String = ""
var reachable: Dictionary = {}
var motion: bool = true
var movement_tweens: Dictionary = {}

func _ready() -> void:
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("14232c")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("a7c5ce")
	settings.ambient_light_energy = 0.65
	environment.environment = settings
	add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_color = Color("ffe8c6")
	light.light_energy = 1.2
	light.shadow_enabled = true
	add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-35, 140, 0)
	fill.light_color = Color("84bacb")
	fill.light_energy = 0.35
	add_child(fill)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.current = true
	add_child(camera)
	tiles = Node3D.new()
	features = Node3D.new()
	markers = Node3D.new()
	add_child(tiles)
	add_child(features)
	add_child(markers)
	_update_camera()

func _update_camera() -> void:
	focus_point.x = clampf(focus_point.x, -5.5, 5.5)
	focus_point.z = clampf(focus_point.z, -5.5, 5.5)
	camera.size = zoom
	camera.position = focus_point + Vector3(sin(yaw) * 13.0, 17.0, cos(yaw) * 13.0)
	camera.look_at(focus_point)

func pan(delta: Vector2) -> void:
	focus_point += Vector3(delta.x, 0, delta.y).rotated(Vector3.UP, yaw)
	_update_camera()

func rotate_board(amount: float) -> void:
	yaw += amount
	_update_camera()

func zoom_by(amount: float) -> void:
	zoom = clampf(zoom + amount, 9.0, 23.0)
	_update_camera()

func focus_hex(hex: String) -> void:
	focus_point = Hex.to_world(hex) * 0.48
	_update_camera()

func reset_camera() -> void:
	focus_point = Vector3.ZERO
	yaw = 0.0
	zoom = 15.2
	_update_camera()

func _material(color: Color, glow: bool = false) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.roughness = 0.85
	if glow:
		result.emission_enabled = true
		result.emission = color
		result.emission_energy_multiplier = 0.25
	return result

func _mesh(parent: Node3D, mesh: Mesh, pos: Vector3, color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(color)
	instance.position = pos
	parent.add_child(instance)
	return instance

func _cylinder(parent: Node3D, pos: Vector3, radius: float, height: float, color: Color, sides: int = 8, top: float = -1.0) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius if top < 0 else top
	mesh.height = height
	mesh.radial_segments = sides
	return _mesh(parent, mesh, pos, color)

func _box(parent: Node3D, pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _mesh(parent, mesh, pos, color)

func _label(parent: Node3D, text_value: String, pos: Vector3, color: Color = Color("ede5d3")) -> Label3D:
	var label := Label3D.new()
	label.text = text_value
	label.position = pos
	label.font_size = 34
	label.outline_size = 7
	label.pixel_size = 0.010
	label.modulate = color
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	parent.add_child(label)
	return label

func _clear(parent: Node3D) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()

func build(map: Dictionary) -> void:
	map_data = map
	_clear(tiles)
	_clear(features)
	_clear(markers)
	for old in heroes.values():
		old.queue_free()
	heroes.clear()
	for tween in movement_tweens.values():
		tween.kill()
	movement_tweens.clear()
	for key: String in map.hexes:
		var tile: Dictionary = map.hexes[key]
		var pos: Vector3 = Hex.to_world(key)
		var color: Color = TERRAIN.get(tile.terrain, TERRAIN.plains)
		_cylinder(tiles, pos + Vector3(0, -0.19, 0), 0.97, 0.38, color, 6)
		if tile.terrain == "forest":
			for index in 3:
				var offset := Vector3((index - 1) * 0.38, 0, -0.05 if index == 1 else 0.23)
				_cylinder(tiles, pos + offset + Vector3(0, 0.20, 0), 0.055, 0.4, Color("574a36"))
				_cylinder(tiles, pos + offset + Vector3(0, 0.48, 0), 0.26, 0.64, Color("203e35"), 6, 0)
		elif tile.terrain == "mountain":
			_cylinder(tiles, pos + Vector3(-0.12, 0.52, 0), 0.7, 1.12, Color("839197"), 5, 0)
			_cylinder(tiles, pos + Vector3(-0.12, 1.0, 0), 0.16, 0.24, Color("c4d0ce"), 5, 0)
		elif tile.terrain == "swamp":
			_cylinder(tiles, pos + Vector3(0, 0.013, 0), 0.55, 0.02, Color("3e5864"), 8)
			for index in 3:
				_box(tiles, pos + Vector3(index * 0.2 - 0.3, 0.16, 0.24), Vector3(0.025, 0.32, 0.025), Color("9a9866"))
	for road: Array in map.roads:
		_segment(tiles, Hex.to_world(road[0]) + Vector3(0, 0.025, 0), Hex.to_world(road[1]) + Vector3(0, 0.025, 0), Color("aa9e77"), 0.13)
	for index in map.sanctuaries.size():
		var pos: Vector3 = Hex.to_world(map.sanctuaries[index])
		_ring(tiles, pos + Vector3(0, 0.05, 0), TEAM[index], 0.7)
		_label(tiles, "S%d" % (index + 1), pos + Vector3(0, 0.16, 0.67), TEAM[index])
	reset_camera()

func sync(state: Dictionary, viewer: String, events: Array = []) -> void:
	map_data = state.map
	_clear(features)
	for location: Dictionary in state.map.locations.values():
		var major: bool = location.kind in ["worldspire", "ancient_tower"]
		var known: bool = major or viewer in location.get("discovered_by", [])
		var pos: Vector3 = Hex.to_world(location.hex)
		if not known:
			_cylinder(features, pos + Vector3(0, 0.10, 0), 0.20, 0.20, Color("758276"), 5)
			_label(features, "?", pos + Vector3(0, 0.5, 0), Color("9db3af"))
			continue
		var owner: String = location.get("owner_id", "")
		var color: Color = TEAM[int(owner.substr(1)) - 1] if not owner.is_empty() else Color("c8bd9d")
		match location.kind:
			"minor_tower", "ancient_tower", "worldspire":
				var height: float = 1.35 if major else 0.65
				_cylinder(features, pos + Vector3(0, 0.10, 0), 0.5, 0.2, Color("747e77"), 6)
				_cylinder(features, pos + Vector3(0, height / 2.0, 0), 0.28 if major else 0.23, height, Color("b5b69e"), 6)
				_cylinder(features, pos + Vector3(0, height + 0.08, 0), 0.34, 0.25, color, 6)
				if location.kind == "worldspire":
					_cylinder(features, pos + Vector3(0, height + 0.45, 0), 0.22, 0.5, Color("81d3d0"), 4, 0)
				_label(features, "SPIRE" if location.kind == "worldspire" else ("A" if major else "T"), pos + Vector3(0, height + 0.8, 0), color)
			"settlement":
				for index in 2:
					var at: Vector3 = pos + Vector3(index * 0.47 - 0.2, 0.22, 0)
					_box(features, at, Vector3(0.35, 0.4, 0.44), Color("c5b99c"))
					_cylinder(features, at + Vector3(0, 0.31, 0), 0.33, 0.26, Color("975e4a"), 4, 0)
				_label(features, "MARKET", pos + Vector3(0, 0.95, 0), color)
			"ruin":
				for index in 3:
					_cylinder(features, pos + Vector3(index * 0.3 - 0.3, 0.2 + index * 0.08, 0), 0.1, 0.4 + index * 0.16, Color("9ea696"), 6)
				_label(features, "RUIN", pos + Vector3(0, 0.9, 0), color)
			"monster_camp":
				_cylinder(features, pos + Vector3(0, 0.3, 0), 0.37, 0.6, Color("8e6758"), 4, 0)
				_label(features, "CAMP", pos + Vector3(0, 0.9, 0), Color("e5ac8f"))
		if not owner.is_empty():
			_label(features, owner.to_upper(), pos + Vector3(0.45, 0.4, 0.28), color)
	for id: String in state.heroes:
		var hero: Dictionary = state.heroes[id]
		var target: Vector3 = Hex.to_world(hero.hex) + Vector3(0.27, 0.05, 0.28)
		if not heroes.has(id):
			heroes[id] = _make_hero(hero)
			heroes[id].position = target
		else:
			var pawn: Node3D = heroes[id]
			if pawn.position.distance_to(target) > 0.01:
				if movement_tweens.has(id):
					movement_tweens[id].kill()
				var path: Array = []
				for event: Dictionary in events:
					if event.type == "HeroMoved" and event.actor_id == id:
						path = event.data.get("path", [])
				if motion:
					var tween := create_tween()
					movement_tweens[id] = tween
					for hex: String in path:
						tween.tween_property(pawn, "position", Hex.to_world(hex) + Vector3(0.27, 0.05, 0.28), 0.10)
					tween.tween_property(pawn, "position", target, 0.10)
				else:
					pawn.position = target
	redraw_markers()

func _make_hero(hero: Dictionary) -> Node3D:
	var pawn := Node3D.new()
	var index: int = int(String(hero.id).substr(1)) - 1
	var color: Color = TEAM[index]
	add_child(pawn)
	_cylinder(pawn, Vector3(0, 0.09, 0), 0.31, 0.18, color, 12)
	_cylinder(pawn, Vector3(0, 0.38, 0), 0.22, 0.5, color, 6, 0.12)
	var head := SphereMesh.new()
	head.radius = 0.13
	head.height = 0.26
	_mesh(pawn, head, Vector3(0, 0.75, 0), Color("ecdbc1"))
	match hero.class_id:
		"ranger":
			_cylinder(pawn, Vector3(0, 0.92, 0), 0.23, 0.23, color.darkened(0.3), 5, 0)
			_box(pawn, Vector3(0.24, 0.50, 0), Vector3(0.05, 0.65, 0.08), Color("a78b5a"))
		"warlord":
			_box(pawn, Vector3(-0.24, 0.48, 0.06), Vector3(0.12, 0.44, 0.32), Color("909b9f"))
			_box(pawn, Vector3(0.25, 0.54, 0), Vector3(0.07, 0.72, 0.08), Color("dce1dd"))
		"merchant":
			_cylinder(pawn, Vector3(0, 0.91, 0), 0.24, 0.08, color, 8)
			_box(pawn, Vector3(0.23, 0.38, 0), Vector3(0.2, 0.28, 0.22), Color("866143"))
		"cultist":
			_cylinder(pawn, Vector3(0, 0.87, 0), 0.18, 0.25, color.darkened(0.2), 5, 0)
			_box(pawn, Vector3(0.28, 0.56, 0), Vector3(0.05, 1.05, 0.05), Color("c1a479"))
	_label(pawn, String(hero.id).to_upper(), Vector3(0, 1.23, 0), color)
	return pawn

func _segment(parent: Node3D, a: Vector3, b: Vector3, color: Color, width: float) -> void:
	var segment := _box(parent, (a + b) / 2.0, Vector3(width, 0.025, a.distance_to(b)), color)
	if a.distance_to(b) > 0.01:
		segment.look_at(b, Vector3.UP)

func _ring(parent: Node3D, pos: Vector3, color: Color, radius: float = 0.88) -> void:
	for side in 6:
		var a: float = deg_to_rad(side * 60.0 - 30.0)
		var b: float = deg_to_rad((side + 1) * 60.0 - 30.0)
		_segment(parent, pos + Vector3(cos(a), 0, sin(a)) * radius, pos + Vector3(cos(b), 0, sin(b)) * radius, color, 0.045)

func set_targets(targets: Dictionary) -> void:
	reachable = targets
	redraw_markers()

func redraw_markers() -> void:
	_clear(markers)
	for hex: String in reachable:
		_ring(markers, Hex.to_world(hex) + Vector3(0, 0.06, 0), Color("82bf8d"))
	if not selected.is_empty() and map_data.get("hexes", {}).has(selected):
		_ring(markers, Hex.to_world(selected) + Vector3(0, 0.08, 0), Color("f1d28e"), 0.94)
	if reachable.has(hovered):
		var path: Array = reachable[hovered].path
		for index in range(1, path.size()):
			_segment(markers, Hex.to_world(path[index - 1]) + Vector3(0, 0.10, 0), Hex.to_world(path[index]) + Vector3(0, 0.10, 0), Color("f4e8b9"), 0.085)

func screen_to_hex(pos: Vector2) -> String:
	var origin: Vector3 = camera.project_ray_origin(pos)
	var direction: Vector3 = camera.project_ray_normal(pos)
	var point: Variant = Plane(Vector3.UP, 0).intersects_ray(origin, direction)
	if point == null:
		return ""
	var hex: String = Hex.from_world(point)
	return hex if map_data.get("hexes", {}).has(hex) else ""

func input_event(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			rotate_board(-event.relative.x * 0.008)
		var hex: String = screen_to_hex(event.position)
		if hex != hovered:
			hovered = hex
			redraw_markers()
			hex_hovered.emit(hex)
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP: zoom_by(-0.7)
			MOUSE_BUTTON_WHEEL_DOWN: zoom_by(0.7)
			MOUSE_BUTTON_LEFT:
				var hex: String = screen_to_hex(event.position)
				if not hex.is_empty():
					selected = hex
					redraw_markers()
					hex_selected.emit(hex)

func projected_hexes() -> Dictionary:
	var result: Dictionary = {}
	for hex: String in map_data.get("hexes", {}):
		var point: Vector2 = camera.unproject_position(Hex.to_world(hex))
		result[hex] = {"x": point.x, "y": point.y}
	return result
