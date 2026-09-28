class_name BuildingView
extends Node3D
## A building or construction site. Sites show bare earth, scaffolding and a progress bar, and
## the building rises out of the ground as work progresses, eased with the handoff's wall-rise
## curve 1 - (1 - t)^3 (city-scene.js). The Keep's golden Font spins.

var building_id: int = 0
var model: Node3D
var height: float = 2.0
var complete: bool = false

var _plot: MeshInstance3D
var _scaffold: MeshInstance3D
var _bar: ProgressBar3D
var _font: Node3D
var _settle: float = 0.0


## The handoff's easeOutCubic.
static func ease_out_cubic(t: float) -> float:
	var u := 1.0 - clampf(t, 0.0, 1.0)
	return 1.0 - u * u * u


func setup(b: SimBuilding) -> void:
	building_id = b.id
	position = Vector3(b.center().x, 0.0, b.center().y)
	model = ModelLibrary.instance("building/" + b.type)
	add_child(model)
	height = float(model.get_meta("height", ModelLibrary.building_height(b.type)))
	_font = model.get_node_or_null("Font")
	_plot = MeshInstance3D.new()
	_plot.mesh = ModelLibrary.mesh("plot/%d/%d" % [b.size.x, b.size.y])
	_plot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_plot)
	_scaffold = MeshInstance3D.new()
	_scaffold.mesh = ModelLibrary.mesh("scaffold/%d/%d/%d" % [b.size.x, b.size.y, int(round(height * 100.0))])
	add_child(_scaffold)
	_bar = ProgressBar3D.new(minf(float(b.size.x) * 0.75, 2.4))
	_bar.position = Vector3(0, maxf(height * 0.65, 1.0) + 0.5, 0)
	add_child(_bar)
	complete = b.complete
	_apply_state(b)


func refresh(b: SimBuilding) -> void:
	if b.complete and not complete:
		_settle = 1.0
	complete = b.complete
	_apply_state(b)


func _apply_state(b: SimBuilding) -> void:
	_plot.visible = not b.complete
	_scaffold.visible = not b.complete
	_bar.visible = not b.complete
	if b.complete:
		model.position.y = 0.0


func update_visual(b: SimBuilding, time: float, delta: float) -> void:
	if not b.complete:
		var e := ease_out_cubic(b.progress())
		model.position.y = -(1.0 - e) * (height + 0.05)
		_bar.set_value(b.progress())
	elif _settle > 0.0:
		_settle = maxf(_settle - delta * 2.5, 0.0)
		var s := 1.0 + sin(_settle * PI) * 0.04
		model.scale = Vector3(s, 1.0 / s, s)
	if _font != null:
		_font.rotation = Vector3(time * 0.8, time * 0.5, 0.0)
