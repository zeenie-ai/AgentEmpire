class_name ProgressBar3D
extends Node3D
## A small camera-facing progress bar drawn on top of the scene (construction sites).

var width: float = 1.4
var value: float = -1.0

var _fill_mesh: QuadMesh


func _init(bar_width: float = 1.4) -> void:
	width = bar_width
	var bg := MeshInstance3D.new()
	var bm := QuadMesh.new()
	bm.size = Vector2(width + 0.1, 0.22)
	bg.mesh = bm
	bg.material_override = ArtMaterials.bar(false)
	bg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(bg)
	var fill := MeshInstance3D.new()
	_fill_mesh = QuadMesh.new()
	fill.mesh = _fill_mesh
	fill.material_override = ArtMaterials.bar(true)
	fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(fill)
	set_value(0.0)


func set_value(v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	if absf(v - value) < 0.004:
		return
	value = v
	var w := maxf(width * v, 0.001)
	_fill_mesh.size = Vector2(w, 0.12)
	_fill_mesh.center_offset = Vector3(-width * 0.5 + w * 0.5, 0.0, 0.01)
