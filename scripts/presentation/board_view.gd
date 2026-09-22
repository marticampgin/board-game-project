extends Node3D
## Render-only board. Coordinates and legal paths come from the domain.

signal hex_selected(hex: String)
signal hex_hovered(hex: String)

const Hex = preload("res://scripts/domain/hex/hex.gd")
const TEAM: Array[Color] = [Color("6bcab2"), Color("e18d6e"), Color("e1bd70"), Color("ac99d6")]
const TERRAIN: Dictionary = {"plains": Color("4f6b5c"), "forest": Color("304e43"), "swamp": Color("495d68"), "mountain": Color("606c77"), "water": Color("2a6076")}

var camera: Camera3D
var tiles: Node3D
var features: Node3D
var markers: Node3D
var routes: Node3D
var world_overlays: Node3D
var heroes: Dictionary = {}
var map_data: Dictionary = {}
var focus_point: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var zoom: float = 12.8
var selected: String = ""
var hovered: String = ""
var reachable: Dictionary = {}
var target_color: Color = Color("82bf8d")
var motion: bool = true:
	set(value):
		motion = value
		if not motion: _finish_movements()
var movement_tweens: Dictionary = {}
var hero_destinations: Dictionary = {}
var material_cache: Dictionary = {}
var mesh_cache: Dictionary = {}
var feature_signature: String = ""
var route_signature: String = ""
var world_signature: String = ""
var ritual_markers: Array[Node3D] = []
var cosmetic_time: float = 0.0
var last_sync_us: int = 0

func _ready() -> void:
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("14232c")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("a7c5ce")
	settings.ambient_light_energy = 0.40
	environment.environment = settings
	add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_color = Color("ffe8c6")
	light.light_energy = 0.88
	light.shadow_enabled = true
	add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-35, 140, 0)
	fill.light_color = Color("84bacb")
	fill.light_energy = 0.24
	add_child(fill)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.current = true
	add_child(camera)
	tiles = Node3D.new()
	features = Node3D.new()
	markers = Node3D.new()
	routes = Node3D.new()
	world_overlays = Node3D.new()
	add_child(tiles)
	add_child(features)
	add_child(markers)
	add_child(routes)
	add_child(world_overlays)
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
	zoom = 12.8
	_update_camera()

func _material(color: Color, glow: bool = false) -> StandardMaterial3D:
	var cache_key := color.to_html(true) + (":glow" if glow else "")
	if material_cache.has(cache_key): return material_cache[cache_key]
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.roughness = 0.85
	if glow:
		result.emission_enabled = true
		result.emission = color
		result.emission_energy_multiplier = 0.25
	material_cache[cache_key] = result
	return result

func _mesh(parent: Node3D, mesh: Mesh, pos: Vector3, color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(color)
	instance.position = pos
	parent.add_child(instance)
	return instance

func _cylinder(parent: Node3D, pos: Vector3, radius: float, height: float, color: Color, sides: int = 8, top: float = -1.0) -> MeshInstance3D:
	var cache_key := "cylinder:%.4f:%.4f:%d:%.4f" % [radius, height, sides, top]
	if not mesh_cache.has(cache_key):
		var mesh := CylinderMesh.new()
		mesh.bottom_radius = radius
		mesh.top_radius = radius if top < 0 else top
		mesh.height = height
		mesh.radial_segments = sides
		mesh_cache[cache_key] = mesh
	return _mesh(parent, mesh_cache[cache_key], pos, color)

func _box(parent: Node3D, pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	if not mesh_cache.has("unit_box"):
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE
		mesh_cache.unit_box = mesh
	var instance := _mesh(parent, mesh_cache.unit_box, pos, color)
	instance.scale = size
	return instance

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
	_clear(routes)
	_clear(world_overlays)
	feature_signature = ""
	route_signature = ""
	world_signature = ""
	ritual_markers.clear()
	selected = ""
	hovered = ""
	reachable = {}
	for old in heroes.values():
		old.queue_free()
	heroes.clear()
	hero_destinations.clear()
	for tween in movement_tweens.values():
		tween.kill()
	movement_tweens.clear()
	var rim := _cylinder(tiles, Vector3(0, -0.46, 0), 8.05, 0.22, Color("31413f"), 6)
	rim.rotation_degrees.y = 30
	var trim := _cylinder(tiles, Vector3(0, -0.355, 0), 7.99, 0.045, Color("9a8764"), 6)
	trim.rotation_degrees.y = 30
	for key: String in map.hexes:
		var tile: Dictionary = map.hexes[key]
		var pos: Vector3 = Hex.to_world(key)
		var color: Color = TERRAIN.get(tile.terrain, TERRAIN.plains)
		# Coordinate-derived color variation is presentation only; no RNG draws.
		var shade := posmod(int(tile.q) * 17 + int(tile.r) * 11, 4)
		color = color.lightened(shade * 0.012)
		_cylinder(tiles, pos + Vector3(0, -0.18, 0), 0.97, 0.34, color.darkened(0.22), 6)
		_cylinder(tiles, pos + Vector3(0, -0.006, 0), 0.957, 0.025, color, 6)
		if tile.terrain == "forest":
			for index in (3 if str(tile.location_id).is_empty() else 1):
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
		elif tile.terrain == "water":
			_cylinder(tiles, pos + Vector3(0, 0.012, 0), 0.88, 0.018, Color("377687"), 6)
			_segment(tiles, pos + Vector3(-0.4, 0.031, -0.1), pos + Vector3(0.22, 0.031, -0.1), Color("76a6ac"), 0.035)
			_segment(tiles, pos + Vector3(-0.1, 0.031, 0.2), pos + Vector3(0.45, 0.031, 0.2), Color("76a6ac"), 0.028)
	for index in map.sanctuaries.size():
		var pos: Vector3 = Hex.to_world(map.sanctuaries[index])
		_cylinder(tiles, pos + Vector3(0, 0.025, 0), 0.77, 0.045, Color("9aab97"), 6)
		_ring(tiles, pos + Vector3(0, 0.05, 0), TEAM[index], 0.7)
		_label(tiles, "S%d" % (index + 1), pos + Vector3(0, 0.2, 0.67), TEAM[index])
	_sync_routes(map)
	reset_camera()

func _edge_key(edge: Array) -> String:
	return str(edge[0]) + "|" + str(edge[1]) if str(edge[0]) < str(edge[1]) else str(edge[1]) + "|" + str(edge[0])

func _sync_routes(map: Dictionary) -> void:
	var signature := JSON.stringify([map.roads, map.get("bridge_edges", []), map.get("blocked_edges", [])])
	if signature == route_signature: return
	route_signature = signature
	_clear(routes)
	var bridges: Dictionary = {}
	var blocked: Dictionary = {}
	for edge: Array in map.get("bridge_edges", []): bridges[_edge_key(edge)] = edge
	for edge: Array in map.get("blocked_edges", []): blocked[_edge_key(edge)] = true
	for edge: Array in map.roads:
		if bridges.has(_edge_key(edge)): continue
		_segment(routes, Hex.to_world(edge[0]) + Vector3(0, 0.033, 0), Hex.to_world(edge[1]) + Vector3(0, 0.033, 0), Color("b8a67e"), 0.13)
	for edge: Array in bridges.values():
		var start := Hex.to_world(edge[0])
		var finish := Hex.to_world(edge[1])
		var crossing := Node3D.new()
		routes.add_child(crossing)
		crossing.position = (start + finish) * 0.5 + Vector3(0, 0.05, 0)
		crossing.look_at(finish + Vector3(0, 0.05, 0), Vector3.UP)
		var closed: bool = blocked.has(_edge_key(edge))
		var length := start.distance_to(finish)
		for plank in range(9):
			if closed and plank in [3, 4, 5]: continue
			_box(crossing, Vector3(0, 0, (plank - 4) * length / 9.0), Vector3(0.32, 0.065, length / 11.0), Color("987655"))
		for side in [-1, 1]:
			for end in [-1, 1]:
				_box(crossing, Vector3(side * 0.19, 0.12, end * length * 0.34), Vector3(0.045, 0.25, 0.045), Color("d2bd8c"))
		if closed:
			_segment(crossing, Vector3(-0.24, 0.12, -0.24), Vector3(0.24, 0.12, 0.24), Color("ed8e74"), 0.08)
			_segment(crossing, Vector3(-0.24, 0.12, 0.24), Vector3(0.24, 0.12, -0.24), Color("ed8e74"), 0.08)
			_label(routes, "CLOSED", crossing.position + Vector3(0, 0.45, 0), Color("efb19a")).font_size = 25

func _sync_world(state: Dictionary) -> void:
	var signature := JSON.stringify([state.get("world_effects", []), state.get("market_hex", ""), state.get("ground_loot", {})])
	if signature == world_signature: return
	world_signature = signature
	_clear(world_overlays)
	for effect: Dictionary in state.get("world_effects", []):
		if effect.event_id == "cursed_ground":
			for hex: String in effect.get("hexes", []):
				var at := Hex.to_world(hex)
				_ring(world_overlays, at + Vector3(0, 0.035, 0), Color("a58daf"), 0.81)
				for side in range(3):
					var angle := TAU * side / 3.0
					var center := at + Vector3(cos(angle) * 0.63, 0.047, sin(angle) * 0.63)
					_segment(world_overlays, center - Vector3(0.07, 0, 0.08), center + Vector3(0.07, 0, 0.08), Color("c0a0cf"), 0.045)
		elif effect.event_id == "unstable_leyline":
			var location: Dictionary = state.map.locations.get(effect.get("location_id", ""), {})
			if not location.is_empty():
				var at := Hex.to_world(location.hex)
				_ring(world_overlays, at + Vector3(0, 0.075, 0), Color("8fdbc4"), 0.64)
				_label(world_overlays, "LEYLINE", at + Vector3(0, 0.23, 0.6), Color("a5e2c7")).font_size = 24
	var market: String = state.get("market_hex", "")
	if not market.is_empty():
		var at := Hex.to_world(market)
		for side in [-1, 1]:
			_box(world_overlays, at + Vector3(side * 0.32, 0.34, 0), Vector3(0.045, 0.65, 0.045), Color("d5b780"))
		_box(world_overlays, at + Vector3(0, 0.2, 0), Vector3(0.65, 0.14, 0.4), Color("8e6e4a"))
		for stripe in range(4):
			_box(world_overlays, at + Vector3((stripe - 1.5) * 0.2, 0.67, 0), Vector3(0.2, 0.05, 0.56), Color("d9bc7c") if stripe % 2 == 0 else Color("819e98"))
		_ring(world_overlays, at + Vector3(0, 0.04, 0), Color("e0bf7c"), 0.75)
		_label(world_overlays, "TRAVELLING MARKET", at + Vector3(0, 1.05, 0), Color("edce92")).font_size = 25
	for hex: String in state.get("ground_loot", {}):
		var loot: Dictionary = state.ground_loot[hex]
		var at := Hex.to_world(hex) + Vector3(-0.4, 0.16, 0.3)
		if not loot.get("relics", []).is_empty():
			_cylinder(world_overlays, at + Vector3(0, 0.12, 0), 0.14, 0.45, Color("efd185"), 4, 0)
		elif int(loot.get("gold", 0)) > 0:
			_cylinder(world_overlays, at, 0.19, 0.16, Color("cba45c"), 8)
		_label(world_overlays, "LOOT", at + Vector3(0, 0.48, 0), Color("f0d496")).font_size = 24

func _banner(pos: Vector3, owner: String, color: Color) -> void:
	var at := pos + Vector3(-0.52, 0, 0.35)
	_cylinder(features, at + Vector3(0, 0.03, 0), 0.13, 0.06, Color("707966"), 6)
	_box(features, at + Vector3(0, 0.47, 0), Vector3(0.035, 0.9, 0.035), Color("d8c698"))
	_box(features, at + Vector3(0.13, 0.72, 0), Vector3(0.26, 0.28, 0.035), color)
	_label(features, owner.to_upper(), at + Vector3(0.13, 0.93, 0), color).font_size = 25
	_ring(features, pos + Vector3(0, 0.045, 0), color, 0.78)

func sync(state: Dictionary, viewer: String, events: Array = []) -> void:
	var started := Time.get_ticks_usec()
	map_data = state.map
	_sync_routes(state.map)
	_sync_world(state)
	var signature := JSON.stringify([state.map.locations, state.get("monsters", {}), state.get("traps", {}), state.get("commitments", {}), viewer])
	if signature != feature_signature:
		feature_signature = signature
		_rebuild_features(state, viewer)
	_sync_heroes(state, events)
	redraw_markers()
	last_sync_us = Time.get_ticks_usec() - started

func _rebuild_features(state: Dictionary, viewer: String) -> void:
	_clear(features)
	ritual_markers.clear()
	for location: Dictionary in state.map.locations.values():
		var major: bool = location.kind in ["worldspire", "ancient_tower"]
		var discovered: bool = viewer in location.get("discovered_by", [])
		var owner: String = location.get("owner_id", "")
		var known: bool = major or discovered or not owner.is_empty()
		var pos: Vector3 = Hex.to_world(location.hex)
		if not known:
			_cylinder(features, pos + Vector3(0, 0.10, 0), 0.20, 0.20, Color("758276"), 5)
			_label(features, "?", pos + Vector3(0, 0.5, 0), Color("9db3af"))
			continue
		var color: Color = TEAM[int(owner.substr(1)) - 1] if not owner.is_empty() else Color("c8bd9d")
		var trait_id: String = location.get("trait", "") if discovered else ""
		match location.kind:
			"minor_tower", "ancient_tower", "worldspire":
				var height: float = 1.35 if major else 0.65
				_cylinder(features, pos + Vector3(0, 0.07, 0), 0.56, 0.14, Color("5c6d67"), 6)
				_cylinder(features, pos + Vector3(0, 0.17, 0), 0.43, 0.10, Color("9ba393"), 6)
				_cylinder(features, pos + Vector3(0, height / 2.0, 0), 0.28 if major else 0.23, height, Color("b5b69e"), 6)
				_cylinder(features, pos + Vector3(0, height + 0.08, 0), 0.34, 0.25, color, 6)
				for level in range(1, int(location.level)):
					_cylinder(features, pos + Vector3(0, height * 0.27 + level * 0.2, 0), 0.30 if major else 0.25, 0.06, Color("d4bd83"), 6)
				if trait_id == "fortress":
					for side in range(4):
						var angle := side * PI * 0.5
						_box(features, pos + Vector3(cos(angle) * 0.3, height + 0.25, sin(angle) * 0.3), Vector3(0.13, 0.16, 0.13), color)
				elif trait_id == "watchtower":
					_cylinder(features, pos + Vector3(0, height + 0.3, 0), 0.42, 0.22, color.darkened(0.12), 6, 0)
				if location.kind == "worldspire":
					var crystal := _cylinder(features, pos + Vector3(0, height + 0.54, 0), 0.23, 0.72, Color("81d3d0"), 4, 0)
					crystal.material_override = _material(Color("81d3d0"), true)
					_ring(features, pos + Vector3(0, 0.03, 0), Color("b5d8c1"), 0.72)
				_label(features, "SPIRE" if location.kind == "worldspire" else ("A" if major else "T"), pos + Vector3(0, height + 0.8, 0), color)
			"settlement":
				for index in 2:
					var at: Vector3 = pos + Vector3(index * 0.47 - 0.2, 0.22, 0)
					_box(features, at, Vector3(0.35, 0.4, 0.44), Color("c5b99c"))
					_cylinder(features, at + Vector3(0, 0.31, 0), 0.33, 0.26, Color("975e4a"), 4, 0)
				_label(features, "MARKET", pos + Vector3(0, 0.95, 0), color)
			"ruin":
				var exhausted: bool = location.get("exhausted", false)
				for index in 3:
					_cylinder(features, pos + Vector3(index * 0.3 - 0.3, 0.2 + index * 0.08, 0), 0.1, 0.4 + index * 0.16, Color("697c70") if exhausted else Color("aab09c"), 6)
				if not exhausted: _cylinder(features, pos + Vector3(0, 0.22, 0.25), 0.12, 0.35, Color("e7c779"), 4, 0)
				_label(features, "EMPTY RUIN" if exhausted else "RUIN", pos + Vector3(0, 0.9, 0), Color("8da89a") if exhausted else color)
			"monster_camp":
				var monster: Dictionary = {}
				for candidate: Dictionary in state.get("monsters", {}).values():
					if candidate.hex == location.hex: monster = candidate
				var cleared: bool = not monster.is_empty() and monster.hp <= 0
				if cleared:
					_ring(features, pos + Vector3(0, 0.03, 0), Color("708e79"), 0.36)
				elif monster.get("definition_id", "") == "relic_wraith":
					_cylinder(features, pos + Vector3(0, 0.37, 0), 0.31, 0.74, Color("86779c"), 5, 0.07)
					_cylinder(features, pos + Vector3(0, 0.85, 0), 0.13, 0.27, Color("d9c083"), 4, 0)
				elif monster.get("definition_id", "") == "stone_guardian":
					_box(features, pos + Vector3(0, 0.35, 0), Vector3(0.48, 0.70, 0.40), Color("899b98"))
					_cylinder(features, pos + Vector3(0, 0.8, 0), 0.23, 0.25, Color("b7c4af"), 5)
				else:
					_cylinder(features, pos + Vector3(-0.17, 0.22, 0), 0.26, 0.44, Color("947c62"), 4, 0)
					_cylinder(features, pos + Vector3(0.21, 0.18, 0.2), 0.20, 0.36, Color("b09a74"), 4, 0)
				_label(features, "CLEARED" if cleared else "CAMP", pos + Vector3(0, 1.02, 0), Color("a4c1aa") if cleared else Color("e5ac8f"))
		if not owner.is_empty():
			_banner(pos, owner, color)
	for warning: Dictionary in state.get("traps", {}).values():
		var at: Vector3 = Hex.to_world(warning.hex)
		_ring(features, at + Vector3(0, 0.095, 0), Color("e6b87a"), 0.61)
		_label(features, "!", at + Vector3(0, 0.55, 0), Color("ffd090"))
	for id: String in state.get("commitments", {}):
		var commitment: Dictionary = state.commitments[id]
		var at := Hex.to_world(state.heroes[id].hex)
		if commitment.get("kind", "") == "ritual":
			var marker := Node3D.new()
			features.add_child(marker)
			marker.position = at + Vector3(0, 0.05, 0)
			_ring(marker, Vector3.ZERO, Color("e5c679"), 0.91)
			_ring(marker, Vector3(0, 0.025, 0), Color("83d6cd"), 0.70)
			for side in range(3):
				var angle := side * TAU / 3.0
				_cylinder(marker, Vector3(cos(angle) * 0.79, 0.38, sin(angle) * 0.79), 0.09, 0.6, Color("e7d48e"), 4, 0)
			ritual_markers.append(marker)
			_label(features, "RITUAL " + id.to_upper(), at + Vector3(0, 2.6, 0), Color("ffe0a2"))
		else:
			_ring(features, at + Vector3(0, 0.07, 0), TEAM[int(id.substr(1)) - 1], 0.88)
			_label(features, "CAPTURING " + id.to_upper(), at + Vector3(0, 2.2, 0), Color("f0cd81"))

func _sync_heroes(state: Dictionary, events: Array) -> void:
	for id: String in state.heroes:
		var hero: Dictionary = state.heroes[id]
		var target: Vector3 = Hex.to_world(hero.hex) + Vector3(0.27, 0.05, 0.28)
		if not heroes.has(id):
			heroes[id] = _make_hero(hero)
			heroes[id].position = target
			hero_destinations[id] = target
		else:
			var pawn: Node3D = heroes[id]
			if hero_destinations.get(id, pawn.position) != target:
				if movement_tweens.has(id):
					movement_tweens[id].kill()
				var path: Array = []
				for event: Dictionary in events:
					if event.type == "HeroMoved" and event.actor_id == id:
						path = event.data.get("path", [])
					elif event.type == "HeroDisplaced" and event.actor_id == id:
						path = [event.data.from, event.data.to]
				hero_destinations[id] = target
				if motion and not path.is_empty():
					pawn.position = Hex.to_world(path[0]) + Vector3(0.27, 0.05, 0.28)
					var tween := create_tween()
					movement_tweens[id] = tween
					var duration := 0.11 / clampf(float(get_meta("animation_speed", 1.0)), 0.25, 4.0)
					for hex: String in path.slice(1):
						tween.tween_property(pawn, "position", Hex.to_world(hex) + Vector3(0.27, 0.05, 0.28), duration).set_trans(Tween.TRANS_SINE)
				else:
					pawn.position = target
		var status: Label3D = heroes[id].get_node("Status")
		status.text = "RECOVERING" if hero.statuses.has("recovering") else ""
		var relic_marker: Label3D = heroes[id].get_node("Relics")
		relic_marker.text = "RELICS %d" % hero.relics.size() if not hero.relics.is_empty() else ""

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
	var relics := _label(pawn, "", Vector3(0, 1.53, 0), Color("edd092"))
	relics.name = "Relics"
	relics.font_size = 25
	var status := _label(pawn, "", Vector3(0, 1.83, 0), Color("a1d8e0"))
	status.name = "Status"
	status.font_size = 26
	return pawn

func _segment(parent: Node3D, a: Vector3, b: Vector3, color: Color, width: float) -> void:
	var segment := _box(parent, (a + b) / 2.0, Vector3(width, 0.025, a.distance_to(b)), color)
	if a.distance_to(b) > 0.01:
		segment.look_at(b, Vector3.UP)

func _ring(parent: Node3D, pos: Vector3, color: Color, radius: float = 0.88) -> void:
	var key := "ring:%.3f" % radius
	if not mesh_cache.has(key):
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var indices := PackedInt32Array()
		for side in range(6):
			var angle := deg_to_rad(side * 60.0 - 30.0)
			var direction := Vector3(cos(angle), 0, sin(angle))
			vertices.append(direction * (radius - 0.025))
			vertices.append(direction * (radius + 0.025))
			normals.append(Vector3.UP)
			normals.append(Vector3.UP)
		for side in range(6):
			var a := side * 2
			var b := ((side + 1) % 6) * 2
			indices.append_array(PackedInt32Array([a, a + 1, b, b, a + 1, b + 1]))
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_INDEX] = indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh_cache[key] = mesh
	_mesh(parent, mesh_cache[key], pos, color)

func _finish_movements() -> void:
	for tween in movement_tweens.values(): tween.kill()
	movement_tweens.clear()
	for id: String in hero_destinations:
		if heroes.has(id): heroes[id].position = hero_destinations[id]

func _process(delta: float) -> void:
	cosmetic_time += delta * clampf(float(get_meta("animation_speed", 1.0)), 0.25, 4.0)
	for marker: Node3D in ritual_markers:
		var pulse := 1.0 + sin(cosmetic_time * 2.2) * 0.025 if motion else 1.0
		marker.scale = Vector3(pulse, 1.0, pulse)

func debug_metrics() -> Dictionary:
	return {"sync_us": last_sync_us, "cached_materials": material_cache.size(), "cached_meshes": mesh_cache.size(), "feature_nodes": features.get_child_count(), "route_nodes": routes.get_child_count(), "world_nodes": world_overlays.get_child_count()}

func set_targets(targets: Dictionary, color: Color = Color("82bf8d")) -> void:
	reachable = targets
	target_color = color
	redraw_markers()

func redraw_markers() -> void:
	_clear(markers)
	for hex: String in reachable:
		_ring(markers, Hex.to_world(hex) + Vector3(0, 0.06, 0), target_color)
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
