class_name SurveyStakes
extends Node3D
## Survey stakes along the four wall rings (economy.json map.ring_radii). The ring that bounds
## the current build zone carries gold flags and a faint rope line on the ground. Phase 5
## raises the actual walls here with the handoff's staggered easeOutCubic animation.

const SPACING := 2.4

var _stakes: MultiMeshInstance3D
var _flags: MultiMeshInstance3D
var _line: MeshInstance3D


func build(w: SimWorld) -> void:
	for c in get_children():
		c.queue_free()
	var centre := w.map_center()
	var zone := w.build_radius()
	var plain: Array[Transform3D] = []
	var flagged: Array[Transform3D] = []
	for r in w.econ.ring_radii():
		var count := maxi(12, int(round(TAU * float(r) / SPACING)))
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
