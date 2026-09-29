class_name BuildingView
extends Node3D
## A building or construction site.
## - Sites use the art's construction stages, scaled to the footprint: stage_a (foundations),
##   then stage_b and stage_c (framing) as work progresses, inside the scaffolding; each change
##   pops in with a puff of dust. Without the stage art, bare earth and procedural scaffolding
##   show while the building rises out of the ground with the handoff's easeOutCubic wall-rise
##   (city-scene.js). Fields (farms) grow in place instead.
## - When work completes the finished building is revealed with a dust burst and a small
##   squash-and-settle.
## - Cottages and the Keep smoke from their chimneys; at night a warm light glows at the door.
## The Keep's golden Font spins.

const STAGES := ["stage/a", "stage/b", "stage/c"]
## Progress at which each stage takes over (stage_a from the start).
const STAGE_AT := [0.0, 0.34, 0.67]
const SMOKE_TYPES := ["cottage", "keep"]
const DOOR_LIGHT_COLOR := Color(1.0, 0.68, 0.34)

var building_id: int = 0
var type: String = ""
var model: Node3D
var height: float = 2.0
var complete: bool = false

var _size: Vector2i = Vector2i.ONE
var _scaffold: MeshInstance3D
var _stage_nodes: Array[Node3D] = []
var _scaffolding: Node3D
var _stage: int = -1
var _stage_pop: float = 0.0
var _bar: ProgressBar3D
var _font: Node3D
var _settle: float = 0.0
var _smoke: GeometryInstance3D
var _light: OmniLight3D
var _field: bool = false


## The handoff's easeOutCubic.
static func ease_out_cubic(t: float) -> float:
	var u := 1.0 - clampf(t, 0.0, 1.0)
	return 1.0 - u * u * u


## Which construction stage (0..2) shows at `progress`.
static func stage_for(progress: float) -> int:
	var s := 0
	for i in STAGE_AT.size():
		if progress >= float(STAGE_AT[i]):
			s = i
	return s


func setup(b: SimBuilding) -> void:
	building_id = b.id
	type = b.type
	_size = b.size
	_field = b.walkable
	position = Vector3(b.center().x, 0.0, b.center().y)
	model = ModelLibrary.instance("building/" + b.type, b.id)
	add_child(model)
	height = float(model.get_meta("height", ModelLibrary.building_height(b.type)))
	_font = model.get_node_or_null("Font")
	if not _field and not b.complete:
		_build_stages()
	if _stage_nodes.is_empty() and not _field:
		_scaffold = MeshInstance3D.new()
		_scaffold.mesh = ModelLibrary.mesh("scaffold/%d/%d/%d" % [b.size.x, b.size.y, int(round(height * 100.0))])
		add_child(_scaffold)
	_bar = ProgressBar3D.new(minf(float(b.size.x) * 0.75, 2.4))
	_bar.position = Vector3(0, maxf(height * 0.65, 1.0) + 0.5, 0)
	if not _stage_nodes.is_empty():
		_bar.position.y = maxf(float(b.size.x) * 0.55, 1.2) + 0.4
	add_child(_bar)
	complete = b.complete
	_apply_state(b)
	if complete:
		_add_life()


## The art's stage models, scaled uniformly to the footprint (none when the art is missing).
func _build_stages() -> void:
	var s := float(mini(_size.x, _size.y))
	for key: String in STAGES:
		var n := ModelLibrary.stage(key)
		if n == null:
			for old in _stage_nodes:
				old.queue_free()
			_stage_nodes.clear()
			return
		n.scale = Vector3.ONE * s
		n.visible = false
		add_child(n)
		_stage_nodes.append(n)
	_scaffolding = ModelLibrary.stage("stage/scaffolding")
	if _scaffolding != null:
		_scaffolding.scale = Vector3(float(_size.x), s, float(_size.y)) * 1.04
		_scaffolding.visible = false
		add_child(_scaffolding)


func refresh(b: SimBuilding) -> void:
	if b.complete and not complete:
		_settle = 1.0
		complete = true
		_apply_state(b)
		_reveal()
		return
	complete = b.complete
	_apply_state(b)


func _apply_state(b: SimBuilding) -> void:
	var site := not b.complete
	_bar.visible = site
	if _scaffold != null:
		_scaffold.visible = site
	if not _stage_nodes.is_empty():
		model.visible = not site
		if not site:
			for n in _stage_nodes:
				n.visible = false
			if _scaffolding != null:
				_scaffolding.visible = false
	if b.complete:
		model.position.y = 0.0
		model.scale = Vector3.ONE


## Construction finished: dust, a settle bounce, smoke and lights from now on.
func _reveal() -> void:
	var dust := Fx.dust_burst(Vector2(_size) * 0.9)
	add_child(dust)
	(dust as Node).set("emitting", true)
	Fx.free_after(dust, 3.0)
	for n in _stage_nodes:
		n.queue_free()
	_stage_nodes.clear()
	if _scaffolding != null:
		_scaffolding.queue_free()
		_scaffolding = null
	_add_life()


func _add_life() -> void:
	if type in SMOKE_TYPES and model.has_meta("chimney") and _smoke == null:
		_smoke = Fx.chimney_smoke()
		_smoke.position = model.get_meta("chimney")
		add_child(_smoke)
	if _light == null and not _field:
		_light = OmniLight3D.new()
		_light.light_color = DOOR_LIGHT_COLOR
		_light.omni_range = clampf(float(_size.x) * 1.4, 2.4, 5.0)
		_light.omni_attenuation = 1.6
		_light.shadow_enabled = false
		_light.light_energy = 0.0
		_light.visible = false
		var door: Vector3 = model.get_meta("door", Vector3(0, 0.3, float(_size.y) * 0.5))
		_light.position = door + Vector3(0, 0.55, 0.45)
		add_child(_light)


func update_visual(b: SimBuilding, time: float, delta: float) -> void:
	if not b.complete:
		var p := b.progress()
		if _field:
			var g := ease_out_cubic(p)
			model.scale = Vector3(1.0, maxf(g, 0.02), 1.0)
		elif not _stage_nodes.is_empty():
			_update_stages(p, delta)
		else:
			var e := ease_out_cubic(p)
			model.position.y = -(1.0 - e) * (height + 0.05)
		_bar.set_value(p)
	elif _settle > 0.0:
		_settle = maxf(_settle - delta * 2.2, 0.0)
		var s := 1.0 + sin(_settle * PI) * 0.06
		model.scale = Vector3(s, 1.0 / s, s)
	if _font != null:
		_font.rotation = Vector3(time * 0.8, time * 0.5, 0.0)
	if _light != null:
		var n := ArtMaterials.night_amount()
		_light.visible = n > 0.02
		_light.light_energy = n * 1.8 * (0.92 + 0.08 * sin(time * 7.3 + float(building_id)))


func _update_stages(p: float, delta: float) -> void:
	var s := stage_for(p)
	if s != _stage:
		_stage = s
		for i in _stage_nodes.size():
			_stage_nodes[i].visible = i == s
		if _scaffolding != null:
			_scaffolding.visible = s >= 1
		_stage_pop = 1.0
		if s > 0:
			var dust := Fx.dust_burst(Vector2(_size) * 0.6)
			add_child(dust)
			(dust as Node).set("emitting", true)
			Fx.free_after(dust, 3.0)
	if _stage_pop > 0.0:
		_stage_pop = maxf(_stage_pop - delta * 3.0, 0.0)
		var k := 1.0 + sin(_stage_pop * PI) * 0.05
		var base := float(mini(_size.x, _size.y))
		_stage_nodes[_stage].scale = Vector3(base * k, base / k, base * k)
