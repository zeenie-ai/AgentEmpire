class_name PlacementGhost
extends Node3D
## Translucent preview of a building being placed: green where it can go, red where it cannot.

var type: String = ""
var ok: bool = true

var _model: Node3D
var _footprint: MeshInstance3D


func show_type(building_type: String, footprint: Vector2i) -> void:
	if building_type == type and _model != null:
		visible = true
		return
	clear()
	type = building_type
	_model = ModelLibrary.instance("building/" + building_type)
	add_child(_model)
	var font := _model.get_node_or_null("Font")
	if font != null:
		font.visible = false
	_footprint = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(footprint.x, footprint.y)
	_footprint.mesh = pm
	_footprint.position.y = 0.04
	_footprint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_footprint)
	_apply_material()
	visible = true


## `cell` is the footprint's top-left cell.
func place_at(cell: Vector2i, footprint: Vector2i, valid: bool) -> void:
	position = Vector3(cell.x + footprint.x * 0.5, 0.0, cell.y + footprint.y * 0.5)
	if valid != ok:
		ok = valid
		_apply_material()


func clear() -> void:
	for c in get_children():
		c.queue_free()
	_model = null
	_footprint = null
	type = ""
	visible = false


func _apply_material() -> void:
	var mat := ArtMaterials.ghost(ok)
	if _footprint != null:
		_footprint.material_override = mat
	if _model != null:
		for mi in _model.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).material_override = mat
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
