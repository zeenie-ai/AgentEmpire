class_name PlacementGhost
extends Node3D
## Translucent preview of a building being placed: green where it can go, red where it cannot.
## For an agent's home it also shows the whole plot (HomeLayout) around the home.

var type: String = ""
var ok: bool = true
## True while previewing an agent's home with its plot.
var plot_mode: bool = false

var _model: Node3D
var _footprint: MeshInstance3D
var _plot: MeshInstance3D
var _plot_mat: StandardMaterial3D


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


## Previews an agent's home of `home_type` inside its plot.
func show_plot(home_type: String) -> void:
	show_type(home_type, Vector2i(HomeLayout.HOME, HomeLayout.HOME))
	plot_mode = true
	if _plot == null:
		_plot = MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(HomeLayout.PLOT, HomeLayout.PLOT)
		_plot.mesh = pm
		_plot.position.y = 0.025
		_plot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_plot)
	_apply_material()


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
	_plot = null
	plot_mode = false
	type = ""
	visible = false


func _apply_material() -> void:
	var mat := ArtMaterials.ghost(ok)
	if _footprint != null:
		_footprint.material_override = mat
	if _plot != null:
		_plot_mat = mat.duplicate() as StandardMaterial3D
		_plot_mat.albedo_color.a *= 0.45
		_plot.material_override = _plot_mat
	if _model != null:
		for mi in _model.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).material_override = mat
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
