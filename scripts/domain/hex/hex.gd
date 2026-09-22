extends RefCounted
## Pointy-top axial coordinates. Every iteration order is deterministic.

const DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]

static func key(q: int, r: int) -> String:
	return "%d,%d" % [q, r]

static func parse(value: String) -> Vector2i:
	var parts := value.split(",")
	return Vector2i(int(parts[0]), int(parts[1]))

static func neighbors(value: String) -> Array[String]:
	var point := parse(value)
	var result: Array[String] = []
	for direction in DIRECTIONS:
		result.append(key(point.x + direction.x, point.y + direction.y))
	return result

static func to_cube(value: String) -> Vector3i:
	var point := parse(value)
	return Vector3i(point.x, -point.x - point.y, point.y)

static func from_cube(cube: Vector3i) -> String:
	return key(cube.x, cube.z)

static func distance(a: String, b: String) -> int:
	var delta := to_cube(a) - to_cube(b)
	return maxi(abs(delta.x), maxi(abs(delta.y), abs(delta.z)))

static func range_keys(center: String, radius: int) -> Array[String]:
	var result: Array[String] = []
	var origin := parse(center)
	for q in range(-radius, radius + 1):
		for r in range(maxi(-radius, -q - radius), mini(radius, -q + radius) + 1):
			result.append(key(origin.x + q, origin.y + r))
	return result

static func ring(center: String, radius: int) -> Array[String]:
	var result: Array[String] = []
	for value in range_keys(center, radius):
		if distance(center, value) == radius:
			result.append(value)
	return result

static func to_world(value: String, size: float = 1.0) -> Vector3:
	var point := parse(value)
	return Vector3(sqrt(3.0) * size * (point.x + point.y * 0.5), 0.0, size * 1.5 * point.y)

static func from_world(point: Vector3, size: float = 1.0) -> String:
	var q := (sqrt(3.0) / 3.0 * point.x - point.z / 3.0) / size
	var r := (2.0 / 3.0 * point.z) / size
	var cube := Vector3(q, -q - r, r)
	var rounded := Vector3i(roundi(cube.x), roundi(cube.y), roundi(cube.z))
	var difference := Vector3(rounded).distance_squared_to(cube) # Keeps projection independent of board height.
	if difference > 0.0:
		var error := (Vector3(rounded) - cube).abs()
		if error.x > error.y and error.x > error.z:
			rounded.x = -rounded.y - rounded.z
		elif error.y > error.z:
			rounded.y = -rounded.x - rounded.z
		else:
			rounded.z = -rounded.x - rounded.y
	return from_cube(rounded)

static func in_bounds(value: String, radius: int = 4) -> bool:
	return distance("0,0", value) <= radius

static func sort_keys(values: Array) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(str(value))
	result.sort_custom(func(a: String, b: String) -> bool:
		var aa := parse(a)
		var bb := parse(b)
		return aa.x < bb.x or (aa.x == bb.x and aa.y < bb.y)
	)
	return result
