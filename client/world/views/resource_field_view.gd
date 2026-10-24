class_name ResourceFieldView
extends Node3D
## Trees, berry bushes, stumps and rocks drawn with MultiMesh: one per kind (and per art variant)
## in each GrassField.CHUNK x CHUNK tile chunk, like the grass. That is a draw call per kind and
## chunk, and the renderer culls the chunks out of view, in the main pass and in the shadow maps.
## Every node owns a slot in its chunk's live MultiMesh and one in its depleted MultiMesh (stump
## or bare bush); depletion and regrowth just swap which one is visible. A band of backdrop trees
## outside the map keeps the edge from ending abruptly.

## A hidden instance: shrunk to a speck under the ground. hidden_at() moves it below its node's
## own spot, so it stays inside the bounds of the node's chunk.
const HIDDEN := Transform3D(Vector3(0.0001, 0, 0), Vector3(0, 0.0001, 0), Vector3(0, 0, 0.0001), Vector3(0, -1, 0))
const BACKDROP_BAND := 18
const BACKDROP_DENSITY := 0.5

var world: SimWorld

## node id -> [live MultiMesh, live index, depleted MultiMesh, depleted index]
var _slots: Dictionary = {}
var _transforms: Dictionary = {}


func build(w: SimWorld) -> void:
	world = w
	for c in get_children():
		c.queue_free()
	_slots.clear()
	_transforms.clear()
	var groups := {"conifer": [], "broadleaf": [], "bush": []}
	for n: SimResourceNode in w.nodes.values():
		if n.kind == "tree":
			(groups["conifer" if (n.variant & 1) == 0 else "broadleaf"] as Array).append(n)
		elif n.kind == "berry_bush":
			(groups["bush"] as Array).append(n)
	var conifers: Array = groups["conifer"]
	var broadleafs: Array = groups["broadleaf"]
	var bushes: Array = groups["bush"]
	var stumps := _layer("Stump", "node/stump", 0, _cells(conifers + broadleafs), false)
	_assign_all(conifers, _layer("Conifer", "node/tree_conifer", 0, _cells(conifers), true), stumps.slice(0, conifers.size()))
	_assign_all(broadleafs, _layer("Broadleaf", "node/tree_broadleaf", 0, _cells(broadleafs), true), stumps.slice(conifers.size()))
	_assign_all(bushes, _layer("Bush", "node/berry_bush", 0, _cells(bushes), true), _layer("Bare", "node/bush_bare", 0, _cells(bushes), false))
	_build_rocks(w)
	_build_backdrop(w)


## The chunk `cell` is drawn in.
static func chunk_of(cell: Vector2i) -> Vector2i:
	return Vector2i(floori(float(cell.x) / GrassField.CHUNK), floori(float(cell.y) / GrassField.CHUNK))


## One MultiMesh of `mesh_key` for each chunk the `cells` fall in, with an instance per cell.
## Returns each cell's slot, in order: [MultiMesh, instance index].
func _layer(layer_name: String, mesh_key: String, variant: int, cells: Array, shadows: bool) -> Array:
	var counts := {}
	var slots := []
	for cell: Vector2i in cells:
		var c := chunk_of(cell)
		var i := int(counts.get(c, 0))
		counts[c] = i + 1
		slots.append([c, i])
	var meshes := {}
	for c: Vector2i in counts:
		meshes[c] = _make("%s_%d_%d" % [layer_name, c.x, c.y], mesh_key, variant, int(counts[c]), shadows)
	for s: Array in slots:
		s[0] = meshes[s[0]]
	return slots


func _make(node_name: String, mesh_key: String, variant: int, count: int, shadows: bool) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = ModelLibrary.mesh(mesh_key, variant)
	mm.instance_count = count
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mm


static func _cells(nodes: Array) -> Array:
	var out := []
	for n: SimResourceNode in nodes:
		out.append(n.cell)
	return out


## Gives each of `nodes` its live slot and its depleted slot (both [MultiMesh, index]).
func _assign_all(nodes: Array, live: Array, dead: Array) -> void:
	for i in nodes.size():
		_assign(nodes[i], live[i], dead[i])


func _assign(n: SimResourceNode, live: Array, dead: Array) -> void:
	_slots[n.id] = [live[0], live[1], dead[0], dead[1]]
	var tree := n.kind == "tree"
	_transforms[n.id] = _xform(n.center(), n.variant, 0.85 if tree else 0.9, 1.25 if tree else 1.15)
	(live[0] as MultiMesh).set_instance_color(int(live[1]), _tint(n.variant, tree))
	(dead[0] as MultiMesh).set_instance_color(int(dead[1]), Color.WHITE)
	refresh(n.id)


## Shows the live or depleted look of node `id` (hides both if it is gone).
func refresh(id: int) -> void:
	if not _slots.has(id):
		return
	var s: Array = _slots[id]
	var n: SimResourceNode = world.nodes.get(id) if world != null else null
	var shown := shown_transforms(n, _transforms[id])
	(s[0] as MultiMesh).set_instance_transform(int(s[1]), shown[0])
	(s[2] as MultiMesh).set_instance_transform(int(s[3]), shown[1])


## The transforms of a node's live and depleted instances, [live, depleted]: the one for its
## state at `t` and the other hidden under it, or both hidden once the node is gone (null).
static func shown_transforms(n: SimResourceNode, t: Transform3D) -> Array[Transform3D]:
	var hidden := hidden_at(t)
	if n == null:
		return [hidden, hidden]
	if n.depleted:
		return [hidden, t]
	return [t, hidden]


## HIDDEN under the spot of `t`.
static func hidden_at(t: Transform3D) -> Transform3D:
	return HIDDEN.translated(Vector3(t.origin.x, 0.0, t.origin.z))


## Rocks spread over the art's rock variants (one MultiMesh each per chunk).
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
		var cells := []
		for r: Array in list:
			cells.append(r[0])
		var slots := _layer("Rock%d" % v, "decor/rock", v, cells, true)
		for r in list.size():
			var c: Vector2i = list[r][0]
			var h: int = list[r][1]
			var mm: MultiMesh = slots[r][0]
			var i: int = slots[r][1]
			mm.set_instance_transform(i, _xform(Vector2(c.x + 0.5, c.y + 0.5), h & 0xffff, 0.8, 1.3))
			mm.set_instance_color(i, Color(1, 1, 1).darkened(float((h >> 4) & 7) * 0.025))


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
	# kind -> [cells, transforms, tints]
	var sets := {"conifer": [[], [], []], "broadleaf": [[], [], []]}
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
			(sets[kind][0] as Array).append(Vector2i(x, y))
			(sets[kind][1] as Array).append(_xform(Vector2(x + 0.5, y + 0.5), v, 0.95, 1.45))
			(sets[kind][2] as Array).append(_tint(v, true).darkened(0.06))
	for kind: String in sets:
		var cells: Array = sets[kind][0]
		var xforms: Array = sets[kind][1]
		var tints: Array = sets[kind][2]
		var slots := _layer("Backdrop" + kind.to_pascal_case(), "node/tree_" + kind, 0, cells, true)
		for i in cells.size():
			var mm: MultiMesh = slots[i][0]
			var at: int = slots[i][1]
			mm.set_instance_transform(at, xforms[i])
			mm.set_instance_color(at, tints[i])
