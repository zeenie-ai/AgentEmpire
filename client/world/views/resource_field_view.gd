class_name ResourceFieldView
extends Node3D
## Trees, berry bushes, stumps and rocks drawn with MultiMesh: one draw call per kind (and per
## art variant) no matter how many there are. Every node owns a slot in its live MultiMesh and
## one in its depleted MultiMesh (stump or bare bush); depletion and regrowth just swap which
## one is visible. A band of backdrop trees outside the map keeps the edge from ending abruptly.

const HIDDEN := Transform3D(Vector3(0.0001, 0, 0), Vector3(0, 0.0001, 0), Vector3(0, 0, 0.0001), Vector3(0, -50, 0))
const BACKDROP_BAND := 18
const BACKDROP_DENSITY := 0.5

var world: SimWorld

var _mm: Dictionary = {}
## node id -> [live multimesh name, live index, depleted multimesh name, depleted index]
var _slots: Dictionary = {}
var _transforms: Dictionary = {}


func build(w: SimWorld) -> void:
	world = w
	for c in get_children():
		c.queue_free()
	_mm.clear()
	_slots.clear()
	_transforms.clear()
	var groups := {"conifer": [], "broadleaf": [], "bush": []}
	for n: SimResourceNode in w.nodes.values():
		if n.kind == "tree":
			(groups["conifer" if (n.variant & 1) == 0 else "broadleaf"] as Array).append(n)
		elif n.kind == "berry_bush":
			(groups["bush"] as Array).append(n)
	var trees: Array = groups["conifer"] + groups["broadleaf"]
	_make("conifer", "node/tree_conifer", 0, (groups["conifer"] as Array).size(), true)
	_make("broadleaf", "node/tree_broadleaf", 0, (groups["broadleaf"] as Array).size(), true)
	_make("stump", "node/stump", 0, trees.size(), false)
	_make("bush", "node/berry_bush", 0, (groups["bush"] as Array).size(), true)
	_make("bare", "node/bush_bare", 0, (groups["bush"] as Array).size(), false)
	var i := 0
	for n: SimResourceNode in groups["conifer"]:
		_assign(n, "conifer", i, "stump", i)
		i += 1
	var j := 0
	for n: SimResourceNode in groups["broadleaf"]:
		_assign(n, "broadleaf", j, "stump", i + j)
		j += 1
	var k := 0
	for n: SimResourceNode in groups["bush"]:
		_assign(n, "bush", k, "bare", k)
		k += 1
	_build_rocks(w)
	_build_backdrop(w)


func _make(key: String, mesh_key: String, variant: int, count: int, shadows: bool) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = ModelLibrary.mesh(mesh_key, variant)
	mm.instance_count = count
	for i in count:
		mm.set_instance_transform(i, HIDDEN)
		mm.set_instance_color(i, Color.WHITE)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = key.to_pascal_case()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	_mm[key] = mm
	return mm


func _assign(n: SimResourceNode, live: String, li: int, dead: String, di: int) -> void:
	_slots[n.id] = [live, li, dead, di]
	var tree := n.kind == "tree"
	var t := _xform(n.center(), n.variant, 0.85 if tree else 0.9, 1.25 if tree else 1.15)
	_transforms[n.id] = t
	var tint := _tint(n.variant, tree)
	(_mm[live] as MultiMesh).set_instance_color(li, tint)
	(_mm[dead] as MultiMesh).set_instance_color(di, Color.WHITE)
	refresh(n.id)


## Shows the live or depleted look of node `id` (hides both if it is gone).
func refresh(id: int) -> void:
	if not _slots.has(id):
		return
	var s: Array = _slots[id]
	var live: MultiMesh = _mm[s[0]]
	var dead: MultiMesh = _mm[s[2]]
	var n: SimResourceNode = world.nodes.get(id) if world != null else null
	if n == null:
		live.set_instance_transform(int(s[1]), HIDDEN)
		dead.set_instance_transform(int(s[3]), HIDDEN)
		return
	var t: Transform3D = _transforms[id]
	if n.depleted:
		live.set_instance_transform(int(s[1]), HIDDEN)
		dead.set_instance_transform(int(s[3]), t)
	else:
		live.set_instance_transform(int(s[1]), t)
		dead.set_instance_transform(int(s[3]), HIDDEN)


## Rocks spread over the art's rock variants (one MultiMesh each).
func _build_rocks(w: SimWorld) -> void:
	var variants := ModelLibrary.variant_count("decor/rock")
	var buckets: Array = []
	for v in variants:
		buckets.append([])
	for c in w.rocks:
		var h := (c.x * 73856093) ^ (c.y * 19349663)
		(buckets[posmod(h >> 7, variants)] as Array).append([c, h])
	for v in variants:
		var list: Array = buckets[v]
		if list.is_empty():
			continue
		var mm := _make("rock%d" % v, "decor/rock", v, list.size(), true)
		for r in list.size():
			var c: Vector2i = list[r][0]
			var h: int = list[r][1]
			mm.set_instance_transform(r, _xform(Vector2(c.x + 0.5, c.y + 0.5), h & 0xffff, 0.8, 1.3))
			mm.set_instance_color(r, Color(1, 1, 1).darkened(float((h >> 4) & 7) * 0.025))


func _xform(center: Vector2, variant: int, s_min: float, s_max: float) -> Transform3D:
	var rot := float(variant & 0xff) / 255.0 * TAU
	var s := s_min + float((variant >> 8) & 0xff) / 255.0 * (s_max - s_min)
	var tall := 0.92 + float((variant >> 4) & 0xf) / 15.0 * 0.16
	var jitter := Vector2(float((variant >> 3) & 7) / 7.0 - 0.5, float((variant >> 6) & 7) / 7.0 - 0.5) * 0.22
	var basis := Basis(Vector3.UP, rot).scaled(Vector3(s, s * tall, s))
	return Transform3D(basis, Vector3(center.x + jitter.x, 0.0, center.y + jitter.y))


## Per-instance tint: warm and cool variations so a forest never looks copy-pasted.
func _tint(variant: int, tree: bool) -> Color:
	var t := float((variant >> 2) & 0xf) / 15.0
	var u := float((variant >> 9) & 0x7) / 7.0
	if tree:
		var c := Color(0.9, 0.96, 0.8).lerp(Color(1.12, 1.05, 0.72), t)
		return c.lerp(Color(1.0, 0.98, 0.9), u * 0.3)
	return Color(0.92, 0.96, 0.9).lerp(Color(1.06, 1.04, 0.96), t)


## Decorative trees just outside the playable map (no simulation behind them), both kinds.
func _build_backdrop(w: SimWorld) -> void:
	var size := w.grid.size
	var rng := RandomNumberGenerator.new()
	rng.seed = w.map_seed * 31 + 7
	var sets := {"conifer": [[], []], "broadleaf": [[], []]}
	for y in range(-BACKDROP_BAND, size + BACKDROP_BAND):
		for x in range(-BACKDROP_BAND, size + BACKDROP_BAND):
			if x >= 0 and y >= 0 and x < size and y < size:
				continue
			var edge := maxi(maxi(-x, -y), maxi(x - size + 1, y - size + 1))
			var density := BACKDROP_DENSITY * (1.0 - float(edge) / float(BACKDROP_BAND + 6))
			if rng.randf() > density:
				continue
			var v := rng.randi() & 0xffff
			var kind := "conifer" if rng.randf() < 0.62 else "broadleaf"
			(sets[kind][0] as Array).append(_xform(Vector2(x + 0.5, y + 0.5), v, 0.95, 1.45))
			(sets[kind][1] as Array).append(_tint(v, true).darkened(0.06))
	for kind: String in sets:
		var xforms: Array = sets[kind][0]
		var tints: Array = sets[kind][1]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = ModelLibrary.mesh("node/tree_" + kind)
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
			mm.set_instance_color(i, tints[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Backdrop" + kind.to_pascal_case()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(mmi)
