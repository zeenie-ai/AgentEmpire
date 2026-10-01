class_name SurveyStakes
extends Node3D
## Survey stakes along the town walls that do not stand yet (SimWorld.walls), so every reserved
## line reads from the start:
## - the next ring, which bounds the build zone, is staked out closely, with gold-flagged stakes
##   where its towers and gatehouses will stand and a faint golden line along the wall's course
##   (it breaks where the gates will be);
## - the rings beyond it carry sparse plain stakes.
## When a ring rises the stakes move out to the next one (WorldView rebuilds them after the
## rise). A sandbox map without walls gets plain circles at the ring radii instead.

const SPACING := 2.1
const FAR_SPACING := 3.8
const LINE_HALF := 0.08
const LINE_LIFT := 0.025
## Circles for maps without walls.
const CIRCLE_SPACING := 2.4

var _stakes: MultiMeshInstance3D
var _flags: MultiMeshInstance3D
var _line: MeshInstance3D


func build(w: SimWorld) -> void:
	for c in get_children():
		c.queue_free()
	if w.walls == null:
		_build_circles(w)
		return
	var plain: Array[Transform3D] = []
	var flagged: Array[Transform3D] = []
	var f := MeshFactory.new()
	var any_line := false
	for k in range(w.walls_up, w.walls.ring_count()):
		var next := k == w.walls_up
		var spacing := SPACING if next else FAR_SPACING
		var n := 0
		for line: PackedVector2Array in w.walls.ring_lines[k]:
			if next:
				for i in line.size():
					_add(w, line[i], flagged, n)
					n += 1
				_line_strip(f, line)
				any_line = true
			_along(w, line, spacing, plain, n, next)
			n += line.size() * 7
	_stakes = _multimesh("Stakes", "decor/stake", plain)
	_flags = _multimesh("ZoneStakes", "decor/stake_flag", flagged)
	if any_line:
		_line = MeshInstance3D.new()
		_line.name = "ZoneLine"
		_line.mesh = f.commit(ArtMaterials.survey_line())
		_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_line)


## Stakes every `spacing` tiles along a polyline; on its corners too unless they carry flags.
func _along(w: SimWorld, line: PackedVector2Array, spacing: float, out: Array[Transform3D], seed_n: int, flagged_corners: bool) -> void:
	var n := seed_n
	for i in range(line.size() - 1):
		var a := line[i]
		var b := line[i + 1]
		var count := maxi(1, int(round(a.distance_to(b) / spacing)))
		for j in range(1, count):
			_add(w, a.lerp(b, float(j) / float(count)), out, n)
			n += 1
	if not flagged_corners:
		for p in line:
			_add(w, p, out, n)
			n += 1


func _add(w: SimWorld, p: Vector2, out: Array[Transform3D], n: int) -> void:
	var c := Pathing.cell_of(p)
	if w.grid.is_solid(c) or w.building_at(c) != null:
		return
	var rel := p - w.map_center()
	var yaw := -atan2(rel.y, rel.x) + 0.35 * sin(float(n) * 7.13)
	out.append(Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, 0.0, p.y)))


## A flat golden line on the ground along the wall's course.
func _line_strip(f: MeshFactory, line: PackedVector2Array) -> void:
	for i in range(line.size() - 1):
		var a := line[i]
		var b := line[i + 1]
		var d := (b - a).normalized()
		var side := Vector2(-d.y, d.x) * LINE_HALF
		var below := Vector3((a.x + b.x) * 0.5, LINE_LIFT - 1.0, (a.y + b.y) * 0.5)
		f.quad(Vector3(a.x - side.x, LINE_LIFT, a.y - side.y), Vector3(b.x - side.x, LINE_LIFT, b.y - side.y),
			Vector3(b.x + side.x, LINE_LIFT, b.y + side.y), Vector3(a.x + side.x, LINE_LIFT, a.y + side.y),
			Color.WHITE, below)


func _build_circles(w: SimWorld) -> void:
	var centre := w.map_center()
	var zone := w.build_radius()
	var plain: Array[Transform3D] = []
	var flagged: Array[Transform3D] = []
	for r in w.econ.ring_radii():
		var count := maxi(12, int(round(TAU * float(r) / CIRCLE_SPACING)))
		for i in count:
			var a := TAU * float(i) / float(count)
			var p := centre + Vector2(cos(a), sin(a)) * float(r)
			if w.grid.is_solid(Vector2i(floori(p.x), floori(p.y))):
				continue
			var t := Transform3D(Basis(Vector3.UP, -a), Vector3(p.x, 0.0, p.y))
			if r == zone:
				flagged.append(t)
			else:
				plain.append(t)
	_stakes = _multimesh("Stakes", "decor/stake", plain)
	_flags = _multimesh("ZoneStakes", "decor/stake_flag", flagged)
	var f := MeshFactory.new()
	f.ring_flat(Vector3(centre.x, 0.02, centre.y), float(zone) - 0.09, float(zone) + 0.09, 192, Color.WHITE)
	_line = MeshInstance3D.new()
	_line.name = "ZoneLine"
	_line.mesh = f.commit(ArtMaterials.survey_line())
	_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_line)


func _multimesh(node_name: String, mesh_key: String, xforms: Array[Transform3D]) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = ModelLibrary.mesh(mesh_key)
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	add_child(mmi)
	return mmi
