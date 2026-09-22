extends RefCounted
const Hex = preload("res://scripts/domain/hex/hex.gd")
const Rng = preload("res://scripts/services/deterministic_rng.gd")
const Movement = preload("res://scripts/domain/resolvers/movement.gd")
const Generator = preload("res://scripts/domain/generation/map_generator.gd")
var errors: Array[String] = []

func run() -> Array[String]:
	errors.clear()
	_test_hex()
	_test_rng()
	_test_movement()
	_test_generation()
	return errors

func _expect(condition: bool, description: String) -> void:
	if not condition:
		errors.append(description)

func _test_hex() -> void:
	_expect(Hex.neighbors("0,0").size() == 6, "Six axial neighbors")
	for center in Hex.range_keys("0,0", 4):
		_expect(Hex.from_cube(Hex.to_cube(center)) == center, "Axial/cube round trip: " + center)
		_expect(Hex.from_world(Hex.to_world(center, 1.37), 1.37) == center, "Axial/world round trip: " + center)
		_expect(Hex.from_world(Hex.to_world(center) + Vector3(0.12, 9, -0.1)) == center, "Projection ignores height and rounds within hex")
		for neighbor in Hex.neighbors(center):
			_expect(Hex.distance(center, neighbor) == 1, "Neighbor distance one")
			_expect(Hex.neighbors(neighbor).has(center), "Symmetric adjacency")
			_expect(Hex.distance("2,-3", neighbor) == Hex.distance(neighbor, "2,-3"), "Symmetric distance")
	for radius in range(6):
		_expect(Hex.range_keys("2,-1", radius).size() == 1 + 3 * radius * (radius + 1), "Range formula")
		_expect(Hex.ring("2,-1", radius).size() == (1 if radius == 0 else 6 * radius), "Ring formula")
	_expect(not Hex.in_bounds("5,0"), "Radius bounds")

func _test_rng() -> void:
	var a = Rng.new(321)
	var b = Rng.new(321)
	for index in range(100):
		a.draw("map", 0, 100)
		_expect(a.draw("initiative", 1, 3) == b.draw("initiative", 1, 3), "RNG named streams are independent")
	var snapshot: Dictionary = JSON.parse_string(JSON.stringify(a.snapshot()))
	var restored = Rng.new()
	restored.restore(snapshot)
	for index in range(20):
		_expect(a.draw("combat", 1, 6) == restored.draw("combat", 1, 6), "JSON-restored RNG continues identically")
		_expect(a.draw("map", -100, 100) == restored.draw("map", -100, 100), "Used RNG stream restores state")
	var changed = Rng.new(322)
	_expect(changed.snapshot().streams.map.state != b.snapshot().streams.map.state, "Different seeds vary streams")

func _line_map() -> Dictionary:
	var map := {"hexes": {}, "roads": []}
	for q in range(6):
		var value := Hex.key(q, 0)
		map.hexes[value] = {"id": value, "terrain": "plains"}
	return map

func _test_movement() -> void:
	var map := _line_map()
	var heroes := {"p1": {"hex": "0,0", "move": 3, "class_id": "warlord"}}
	var reached := Movement.reachable(map, heroes, "p1")
	_expect(reached.has("3,0") and not reached.has("4,0") and not reached.has("0,0"), "Normal Move budget three and excludes current hex")
	map.hexes["1,0"].terrain = "forest"
	reached = Movement.reachable(map, heroes, "p1")
	_expect(reached["2,0"].cost == 3 and not reached.has("3,0"), "Forest costs two")
	heroes.p1.class_id = "ranger"
	_expect(Movement.reachable(map, heroes, "p1").has("3,0"), "Ranger forest costs one")
	heroes.p1.class_id = "warlord"
	map.hexes["1,0"].terrain = "mountain"
	_expect(Movement.reachable(map, heroes, "p1").is_empty(), "Mountain blocks movement and traversal")
	map.hexes["1,0"].terrain = "water"
	_expect(Movement.reachable(map, heroes, "p1").is_empty(), "Water blocks movement")
	map.hexes["1,0"].terrain = "plains"
	heroes.p2 = {"hex": "1,0"}
	_expect(Movement.reachable(map, heroes, "p1").is_empty(), "Occupied hex blocks both entry and traversal")
	heroes.erase("p2")
	for q in range(5):
		map.roads.append([Hex.key(q, 0), Hex.key(q + 1, 0)])
	reached = Movement.reachable(map, heroes, "p1")
	_expect(reached.has("4,0") and reached["4,0"].road_only and not reached.has("5,0"), "An entire road Move gains four MP")
	map.roads.erase(["3,0", "4,0"])
	_expect(not Movement.reachable(map, heroes, "p1").has("4,0"), "Leaving a road restores three MP budget")
	map.hexes["1,0"].terrain = "swamp"
	reached = Movement.reachable(map, heroes, "p1")
	_expect(reached.has("1,0") and reached["1,0"].cost == 4 and not reached.has("2,0"), "Swamp consumes entire road budget and stops movement")
	map.roads.clear()
	reached = Movement.reachable(map, heroes, "p1")
	_expect(reached["1,0"].cost == 3 and not reached.has("2,0"), "Swamp consumes normal remaining movement")
	heroes.p1.hex = "1,0"
	_expect(Movement.reachable(map, heroes, "p1").has("4,0"), "A later Move may leave a swamp")
	_expect(Movement.travel_costs(map, "0,0")["2,0"] == 4, "Validation travel prices swamp as three")
	# A forest detour costs more than the all-plains route; verify the path itself.
	map = {"hexes": {}, "roads": []}
	for value in ["0,0", "1,0", "1,-1", "2,-1"]:
		map.hexes[value] = {"terrain": "forest" if value == "1,0" else "plains"}
	heroes.p1.hex = "0,0"
	reached = Movement.reachable(map, heroes, "p1")
	_expect(reached["2,-1"].cost == 2 and reached["2,-1"].path == ["0,0", "1,-1", "2,-1"], "Dijkstra returns cheapest approved path")

func _test_generation() -> void:
	var first := Generator.generate(1)
	_expect(JSON.stringify(first) == JSON.stringify(Generator.generate(1)), "Same seed reproduces full map and report")
	_expect(JSON.stringify(first.hexes) != JSON.stringify(Generator.generate(2).hexes), "Different seeds vary terrain/regions")
	var attempts := 0
	var repaired := 0
	for seed_value in range(100):
		var map := Generator.generate(seed_value)
		var report := Generator.validate(map)
		_expect(report.valid, "Seed %d fails map validation: %s" % [seed_value, str(report.errors)])
		_expect(map.report.attempts <= Generator.MAX_ATTEMPTS, "Generation attempts are capped")
		attempts += int(map.report.attempts)
		repaired += int(map.report.repairs)
	print("Map validation: 100 seeds, %d total attempts, %d final repairs" % [attempts, repaired])
	var broken := first.duplicate(true)
	broken.hexes["0,0"].terrain = "water"
	_expect(not Generator.validate(broken).valid, "Validator rejects unreachable Worldspire")
	broken = first.duplicate(true)
	broken.sanctuaries[1] = broken.sanctuaries[0]
	_expect(not Generator.validate(broken).valid, "Validator rejects overlapping sanctuaries")
	broken = first.duplicate(true)
	broken.locations.erase("minor_1")
	_expect(not Generator.validate(broken).valid, "Validator rejects wrong location counts")
