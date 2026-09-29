class_name GrassField
extends Node3D
## Grass tufts and small flowers scattered over the meadow (grass.gdshader), in CHUNK x CHUNK
## tile MultiMeshes so off-screen chunks are culled. Density follows a noise field (clumps and
## thin patches); nothing grows on trees, bushes or rocks, and the shader shrinks tufts away on
## worn dirt and paving, so new buildings and footpaths clear the grass by themselves.
## set_density() thins every chunk evenly (the instance order is shuffled), for quality presets.

const CHUNK := 16
const TUFT_MIN := 0.2
const TUFT_MAX := 3.4
const FLOWER_COLORS: Array[Color] = [Color("#fff6e8"), Color("#ffe07a"), Color("#f4a6c6"), Color("#c9b3f2"),
	Color("#a8d4ff"), Color("#fff6e8"), Color("#ffd27a")]

static var _tuft_mesh: ArrayMesh
static var _flower_mesh: ArrayMesh

var material: ShaderMaterial
var density: float = 1.0

var _chunks: Array[MultiMeshInstance3D] = []
var _counts: Array[int] = []


func build(w: SimWorld, mask: TerrainMask, mat: ShaderMaterial, dens: float) -> void:
	for c in get_children():
		c.queue_free()
	_chunks.clear()
	_counts.clear()
	material = mat
	density = dens
	var n := w.grid.size
	var clump := FastNoiseLite.new()
	clump.seed = w.map_seed + 101
	clump.frequency = 0.07
	clump.fractal_octaves = 3
	var bloom := FastNoiseLite.new()
	bloom.seed = w.map_seed + 202
	bloom.frequency = 0.11
	var rng := RandomNumberGenerator.new()
	rng.seed = w.map_seed * 7 + 3
	var blocked := {}
	for node: SimResourceNode in w.nodes.values():
		blocked[node.cell] = true
	for r in w.rocks:
		blocked[r] = true
	for cy in range(0, n, CHUNK):
		for cx in range(0, n, CHUNK):
			var tufts := PackedFloat32Array()
			var flowers := PackedFloat32Array()
			for y in range(cy, mini(cy + CHUNK, n)):
				for x in range(cx, mini(cx + CHUNK, n)):
					var cell := Vector2i(x, y)
					if blocked.has(cell):
						continue
					var v := clump.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
					var count := int(floor(lerpf(TUFT_MIN, TUFT_MAX, v * v) + rng.randf()))
					for i in count:
						_append(tufts, Vector3(x + rng.randf(), 0.0, y + rng.randf()), rng.randf() * TAU,
							rng.randf_range(0.75, 1.35), Color(0, 0, 0, 0), false)
					var b := bloom.get_noise_2d(float(x), float(y))
					if b > 0.28 and rng.randf() < (b - 0.2) * 0.9:
						var col := FLOWER_COLORS[rng.randi() % FLOWER_COLORS.size()]
						var petals := 1 + int(rng.randf() < 0.4)
						for i in petals:
							_append(flowers, Vector3(x + rng.randf(), 0.0, y + rng.randf()), rng.randf() * TAU,
								rng.randf_range(0.8, 1.2), col.srgb_to_linear(), true)
			_add_chunk(tufts, tuft_mesh(), false, rng)
			_add_chunk(flowers, flower_mesh(), true, rng)
	set_density(dens)


## 0..1 of the scattered grass is drawn.
func set_density(d: float) -> void:
	density = clampf(d, 0.0, 1.0)
	for i in _chunks.size():
		_chunks[i].multimesh.visible_instance_count = int(round(float(_counts[i]) * density))
		_chunks[i].visible = density > 0.0


## 12 transform floats (+4 custom colour floats for flowers) per instance, as MultiMesh.buffer
## expects them: basis rows with the origin in the fourth column.
func _append(buf: PackedFloat32Array, p: Vector3, rot: float, s: float, col: Color, custom: bool) -> void:
	var c := cos(rot) * s
	var sn := sin(rot) * s
	buf.append_array([c, 0.0, sn, p.x, 0.0, s, 0.0, p.y, -sn, 0.0, c, p.z])
	if custom:
		buf.append_array([col.r, col.g, col.b, col.a])


func _add_chunk(buf: PackedFloat32Array, mesh: Mesh, custom: bool, rng: RandomNumberGenerator) -> void:
	var stride := 16 if custom else 12
	var count := buf.size() / stride
	if count == 0:
		return
	# Shuffle instances so that thinning by visible_instance_count stays spread out.
	for i in range(count - 1, 0, -1):
		var j := rng.randi_range(0, i)
		if i == j:
			continue
		for k in stride:
			var t := buf[i * stride + k]
			buf[i * stride + k] = buf[j * stride + k]
			buf[j * stride + k] = t
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = custom
	mm.mesh = mesh
	mm.instance_count = count
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	_chunks.append(mmi)
	_counts.append(count)


## Seven blades leaning out from a small base. UV.y is the height factor for the sway and the
## root-to-tip shading; vertex alpha 0 marks grass (the shader colours it from the ground).
static func tuft_mesh() -> ArrayMesh:
	if _tuft_mesh != null:
		return _tuft_mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 7:
		var a := TAU * float(i) / 7.0 + rng.randf_range(-0.35, 0.35)
		var dir := Vector3(cos(a), 0.0, sin(a))
		var base := dir * rng.randf_range(0.0, 0.07)
		var tip := base + dir * rng.randf_range(0.05, 0.13) + Vector3(0, rng.randf_range(0.16, 0.3), 0)
		var side := Vector3(-dir.z, 0.0, dir.x) * rng.randf_range(0.024, 0.034)
		var tint := Color(rng.randf_range(0.92, 1.08), rng.randf_range(0.95, 1.08), rng.randf_range(0.9, 1.05), 0.0)
		_vert(st, base - side, tint, 0.0)
		_vert(st, base + side, tint, 0.0)
		_vert(st, tip, tint, 1.0)
	_tuft_mesh = st.commit()
	return _tuft_mesh


## A stem and a five-petal head (vertex alpha 1: coloured by the instance's custom data).
static func flower_mesh() -> ArrayMesh:
	if _flower_mesh != null:
		return _flower_mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stem := Color(1, 1, 1, 0)
	var top := Vector3(0.015, 0.2, 0.0)
	_vert(st, Vector3(-0.012, 0, 0), stem, 0.0)
	_vert(st, Vector3(0.012, 0, 0), stem, 0.0)
	_vert(st, top, stem, 1.0)
	var petal := Color(1, 1, 1, 1)
	var centre := Color(1.0, 0.85, 0.35, 1.0)
	for i in 5:
		var a0 := TAU * float(i) / 5.0
		var a1 := a0 + TAU / 10.0
		var a2 := a0 + TAU / 5.0
		var p0 := top + Vector3(cos(a0), 0.0, sin(a0)) * 0.025
		var p1 := top + Vector3(cos(a1), 0.12, sin(a1)) * 0.065
		var p2 := top + Vector3(cos(a2), 0.0, sin(a2)) * 0.025
		_vert(st, top + Vector3(0, 0.006, 0), centre, 1.0)
		_vert(st, p0, petal, 1.0)
		_vert(st, p1, petal, 1.0)
		_vert(st, top + Vector3(0, 0.006, 0), centre, 1.0)
		_vert(st, p1, petal, 1.0)
		_vert(st, p2, petal, 1.0)
	_flower_mesh = st.commit()
	return _flower_mesh


static func _vert(st: SurfaceTool, p: Vector3, col: Color, h: float) -> void:
	st.set_color(col)
	st.set_uv(Vector2(0.5, h))
	st.set_normal(Vector3.UP)
	st.add_vertex(p)
