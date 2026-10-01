class_name ResearchView
extends Node3D
## An age being researched, shown in the world (Realm.age.research from the Town Hall:
## {target, started_at, duration_ms}):
## - over the Keep, the construction progress bar fills toward the next age under a plate naming
##   it with the time left, and a golden light pulses at the Summoning Font (which spins faster);
## - blue banners stand around the Keep's plaza;
## - at every gate of the ring that will rise, a masons' yard (scaffolding over the road, stone
##   and timber beside it) waits for the wall.
## Everything goes when the research ends (the yards in a puff of dust, as the wall rises).

const BAR_WIDTH := 3.0
const BANNER_RADIUS := 4.7
const BANNER_SCALE := 2.3
const POP_S := 0.6
const LIGHT_COLOR := Color(1.0, 0.82, 0.45)
const FONT_SPIN := 3.5

var world: SimWorld
## The research shown now ({} when none).
var research: Dictionary = {}

var _bar: ProgressBar3D
var _plate: NamePlate
var _light: OmniLight3D
var _parts: Array[Node3D] = []
var _target: int = 0
var _started_unix: float = 0.0
var _duration_s: float = 1.0
var _shown_for: float = 0.0
var _keep_view: BuildingView
var _plate_root: Control


func bind(w: SimWorld, keep_view: BuildingView, plate_root: Control) -> void:
	clear()
	world = w
	_keep_view = keep_view
	_plate_root = plate_root


## Shows `r` (an age research, or {} for none) as of now.
func show_research(r: Dictionary) -> void:
	var target := J.gi(r, "target", 0) if not r.is_empty() else 0
	if world == null or target <= world.age or target > world.econ.ages().size():
		if not research.is_empty():
			_dismiss(true)
		return
	if target != _target or research.is_empty():
		clear()
		_build(target)
	research = r
	_started_unix = iso_unix(J.gs(r, "started_at"))
	_duration_s = maxf(float(J.gi(r, "duration_ms", 1000)) / 1000.0, 0.001)


## Unix seconds (with milliseconds) of an ISO-8601 time like 2026-10-01T12:00:00.250Z, or 0.
static func iso_unix(iso: String) -> float:
	if iso.length() < 19:
		return 0.0
	var t := float(Time.get_unix_time_from_datetime_string(iso.substr(0, 19)))
	if iso.length() > 20 and iso[19] == ".":
		var frac := iso.substr(20).trim_suffix("Z")
		var digits := ""
		for ch in frac:
			if ch < "0" or ch > "9":
				break
			digits += ch
		if digits != "":
			t += float(digits) / pow(10.0, float(digits.length()))
	return t


## How far the research has come (0..1).
func progress(now_unix: float) -> float:
	if research.is_empty():
		return 0.0
	return clampf((now_unix - _started_unix) / _duration_s, 0.0, 1.0)


func clear() -> void:
	for p in _parts:
		if is_instance_valid(p):
			p.queue_free()
	_parts.clear()
	if _plate != null and is_instance_valid(_plate):
		_plate.queue_free()
	_plate = null
	_bar = null
	_light = null
	research = {}
	_target = 0
	_shown_for = 0.0
	if _keep_view != null and is_instance_valid(_keep_view):
		_keep_view.font_speed = 1.0


func update_visual(now_unix: float, delta: float, time: float) -> void:
	if research.is_empty() or world == null:
		return
	_shown_for += delta
	var p := progress(now_unix)
	if _bar != null:
		_bar.set_value(p)
	if _light != null:
		_light.light_energy = 1.6 + 0.8 * sin(time * 3.1) + p * 0.8
	var pop := BuildingView.ease_out_cubic(_shown_for / POP_S)
	for i in _parts.size():
		var part := _parts[i]
		if is_instance_valid(part) and part.has_meta("scale"):
			var k := BuildingView.ease_out_cubic((_shown_for - 0.08 * float(i % 9)) / POP_S)
			part.scale = (part.get_meta("scale") as Vector3) * maxf(k, 0.001)
	_place_plate(now_unix, pop)


func _build(target: int) -> void:
	_target = target
	var k := world.keep()
	if k == null:
		return
	var c := k.center()
	var top := ModelLibrary.building_height("keep")
	var root := Node3D.new()
	root.name = "Research"
	add_child(root)
	_parts.append(root)
	_bar = ProgressBar3D.new(BAR_WIDTH)
	_bar.position = Vector3(c.x, top * 0.62 + 0.6, c.y)
	root.add_child(_bar)
	_light = OmniLight3D.new()
	_light.light_color = LIGHT_COLOR
	_light.omni_range = 7.0
	_light.shadow_enabled = false
	_light.position = Vector3(c.x, top + 0.9, c.y)
	root.add_child(_light)
	if _keep_view != null and is_instance_valid(_keep_view):
		_keep_view.font_speed = FONT_SPIN
	for i in 4:
		var a := PI * 0.25 + PI * 0.5 * float(i)
		var flag := ModelLibrary.instance("decor/flag_blue", i)
		flag.position = Vector3(c.x + cos(a) * BANNER_RADIUS, 0.0, c.y + sin(a) * BANNER_RADIUS)
		flag.rotation.y = -a + PI * 0.5
		_pop(flag, Vector3.ONE * BANNER_SCALE)
	if world.walls != null and target - 1 < world.walls.ring_count():
		for g in world.walls.pieces_of(target - 1, WallLayout.GATE):
			_yard(g)
	if _plate_root != null:
		_plate = NamePlate.new()
		_plate.name = "ResearchPlate"
		_plate_root.add_child(_plate)
		_plate.visible = false


## A masons' yard at a future gate: scaffolding over the road, stone and timber at its sides.
func _yard(g: WallLayout.Piece) -> void:
	var t := Vector2(-g.outward.y, g.outward.x)
	var yaw := atan2(g.outward.x, g.outward.y)
	var at := g.center
	var scaffold := ModelLibrary.stage("stage/scaffolding")
	if scaffold != null:
		scaffold.position = Vector3(at.x, 0.0, at.y)
		scaffold.rotation.y = yaw
		_pop(scaffold, Vector3(3.0, 2.2, 2.0))
	var spots := [
		["decor/stone_pile", at + t * 2.7 - g.outward * 1.3, 1.25],
		["decor/wood_pile", at - t * 2.6 - g.outward * 1.4, 1.2],
		["decor/crates", at - t * 2.4 + g.outward * 1.6, 1.0],
		["decor/stone_pile", at + t * 2.5 + g.outward * 1.5, 1.0],
	]
	for s: Array in spots:
		var node := ModelLibrary.instance(String(s[0]), _parts.size())
		var p: Vector2 = s[1]
		node.position = Vector3(p.x, 0.0, p.y)
		node.rotation.y = yaw + 0.4 * float(_parts.size() % 3)
		_pop(node, Vector3.ONE * float(s[2]))


func _pop(node: Node3D, final_scale: Vector3) -> void:
	node.set_meta("scale", final_scale)
	node.scale = Vector3.ONE * 0.001
	add_child(node)
	_parts.append(node)


## The plate over the bar: the age being researched and the time left.
func _place_plate(now_unix: float, pop: float) -> void:
	if _plate == null or _bar == null:
		return
	var cam := get_viewport().get_camera_3d()
	var at := _bar.global_position + Vector3(0, 0.25, 0)
	if cam == null or cam.is_position_behind(at) or pop < 0.5:
		_plate.visible = false
		return
	var left := maxf(_duration_s - (now_unix - _started_unix), 0.0)
	var title := "%s Age" % world.econ.age_name(_target)
	_plate.set_text(title, "RESEARCH  %d:%02d" % [int(left) / 60, int(left) % 60], UiTokens.GOLD_BRIGHT, UiTokens.HUD_SUBTLE)
	var right := cam.global_transform.basis.x.normalized() * 1.8
	var span := cam.unproject_position(at - right).distance_to(cam.unproject_position(at + right))
	var s := cam.unproject_position(at)
	_plate.visible = get_viewport().get_visible_rect().grow(120.0).has_point(s)
	_plate.place(s, span)


## The research ended: everything goes (with dust at the yards when the age arrived).
func _dismiss(with_dust: bool) -> void:
	if with_dust:
		for part in _parts:
			if not is_instance_valid(part) or part.name == "Research":
				continue
			var dust := Fx.dust_burst(Vector2(2.4, 2.4))
			dust.position = part.global_position
			add_child(dust)
			(dust as Node).set("emitting", true)
			Fx.free_after(dust, 3.0)
	clear()
