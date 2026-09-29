class_name Scenery
extends Node3D
## Scenery past the map edge, so the world fades into hills, mountains and haze instead of
## ending: two rows of mountains beyond the backdrop forest (the art kit's mountain_N models
## when present, procedural ones otherwise) and a few clouds drifting over the outskirts.

## [first gap past the map edge, last gap, smallest scale, largest scale, spacing] per row.
const ROWS := [[26.0, 36.0, 1.0, 1.7, 15.0], [44.0, 66.0, 1.7, 2.8, 22.0]]
const CLOUDS := 10
const CLOUD_SPEED := 0.6

var _clouds: Array[Node3D] = []


func build(w: SimWorld) -> void:
	for c in get_children():
		c.queue_free()
	_clouds.clear()
	var n := float(w.grid.size)
	var centre := Vector2(n, n) * 0.5
	var meshes: Array[Mesh] = []
	if ModelLibrary.has_art("decor/mountain"):
		meshes = ModelLibrary.meshes("decor/mountain")
	else:
		for i in 3:
			meshes.append(ModelLibrary.mesh("decor/mountain/%d" % i))
	var buckets: Array = []
	for i in meshes.size():
		buckets.append([])
	var rng := RandomNumberGenerator.new()
	rng.seed = w.map_seed * 13 + 5
	for row: Array in ROWS:
		var mid := (float(row[0]) + float(row[1])) * 0.5
		var lo := -mid
		var hi := n + mid
		var side := hi - lo
		var count := int(side * 4.0 / float(row[4]))
		for i in count:
			var p := _perimeter(float(i) / float(count) * 4.0, lo, hi)
			var out := (p - centre).normalized()
			p += out * rng.randf_range(float(row[0]) - mid, float(row[1]) - mid)
			p += Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) * float(row[4]) * 0.3
			var s := rng.randf_range(float(row[2]), float(row[3]))
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.85, 1.25), s))
			(buckets[rng.randi() % meshes.size()] as Array).append(Transform3D(basis, Vector3(p.x, -0.3, p.y)))
	for i in meshes.size():
		var xforms: Array = buckets[i]
		if xforms.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[i]
		mm.instance_count = xforms.size()
		for j in xforms.size():
			mm.set_instance_transform(j, xforms[j])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Mountains%d" % i
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
	_build_clouds(w, rng)


## A point on the square [lo, hi]^2 perimeter; t runs 0..4 around it.
static func _perimeter(t: float, lo: float, hi: float) -> Vector2:
	var side := hi - lo
	var k := fposmod(t, 4.0)
	var f := k - floorf(k)
	match int(floorf(k)):
		0:
			return Vector2(lo + f * side, lo)
		1:
			return Vector2(hi, lo + f * side)
		2:
			return Vector2(hi - f * side, hi)
	return Vector2(lo, hi - f * side)


func _build_clouds(w: SimWorld, rng: RandomNumberGenerator) -> void:
	var n := float(w.grid.size)
	var art := ModelLibrary.has_art("decor/cloud")
	for i in CLOUDS:
		var c: Node3D
		if art:
			c = ModelLibrary.instance("decor/cloud", i)
		else:
			c = _procedural_cloud(rng)
		c.name = "Cloud%d" % i
		# Clouds keep to the outskirts: each drifts slowly around the map along its own ring.
		var gap := rng.randf_range(22.0, 58.0)
		c.set_meta("t", rng.randf() * 4.0)
		c.set_meta("lo", -gap)
		c.set_meta("hi", n + gap)
		var p := _perimeter(float(c.get_meta("t")), -gap, n + gap)
		c.position = Vector3(p.x, rng.randf_range(15.0, 24.0), p.y)
		var s := rng.randf_range(2.2, 3.6) if art else rng.randf_range(0.8, 1.4)
		c.scale = Vector3.ONE * s
		c.rotation.y = rng.randf() * TAU
		for mi in c.find_children("*", "GeometryInstance3D", true, false):
			(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(c)
		_clouds.append(c)


## A soft white cloud from a few flattened low-poly spheres.
static func _procedural_cloud(rng: RandomNumberGenerator) -> Node3D:
	var f := MeshFactory.new()
	var col := Color("#fbf7f0")
	var parts := rng.randi_range(4, 6)
	for i in parts:
		var p := Vector3(rng.randf_range(-2.2, 2.2), rng.randf_range(0.0, 0.8), rng.randf_range(-1.1, 1.1))
		var r := rng.randf_range(1.0, 1.7)
		f.sphere(p, r, 4, 8, col, Vector3(1.0, 0.62, 0.9))
	var mi := MeshInstance3D.new()
	mi.mesh = f.commit(KitMaterials.vertex_colored({"wrap": 0.6}))
	var root := Node3D.new()
	root.add_child(mi)
	return root


func _process(delta: float) -> void:
	for c in _clouds:
		var lo := float(c.get_meta("lo"))
		var hi := float(c.get_meta("hi"))
		var t := fposmod(float(c.get_meta("t")) + CLOUD_SPEED * delta / (hi - lo), 4.0)
		c.set_meta("t", t)
		var p := _perimeter(t, lo, hi)
		c.position.x = p.x
		c.position.z = p.y
