class_name RtsCamera
extends Node3D
## RTS camera.
## - Pan: arrow keys (cam_* actions), a 12 px screen edge, or middle-drag (grabs the ground).
## - Zoom: mouse wheel toward the cursor, 10 to 70 tiles from the pivot, tilting from 42 to 62
##   degrees as it zooms out.
## - Rotate: Ctrl+Left/Right in 45-degree steps, or Alt+middle-drag.
## - The pivot is clamped to the map.

const ZOOM_MIN := 10.0
const ZOOM_MAX := 70.0
const PITCH_MIN := 42.0
const PITCH_MAX := 62.0
const EDGE_PX := 12.0
const ROTATE_STEP := PI / 4.0
const ZOOM_STEP := 1.14
const FOV := 40.0

var camera: Camera3D
var pivot: Vector3 = Vector3(64, 0, 64)
var yaw: float = 0.0
var target_yaw: float = 0.0
var distance: float = 34.0
var target_distance: float = 34.0
var map_size: float = 128.0
var edge_scroll: bool = true
var pan_speed: float = 1.0
## Off for scripted captures.
var input_enabled: bool = true

var _drag_pan: bool = false
var _drag_rotate: bool = false
var _drag_anchor: Vector3 = Vector3.ZERO
var _zoom_anchor_screen: Vector2 = Vector2.ZERO
var _zoom_anchor_world: Vector3 = Vector3.ZERO
var _zooming: bool = false
var _focus_tween: Tween
## Edge scrolling waits for a real mouse movement over the window: before one, and after the
## pointer leaves or focus is lost, the reported position (often 0, 0) is not where it is.
var _mouse_in: bool = false


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = FOV
	camera.near = 0.3
	camera.far = 600.0
	add_child(camera)
	camera.current = true
	edge_scroll = bool(Settings.get_value("camera/edge_scroll", true))
	pan_speed = float(Settings.get_value("camera/pan_speed", 1.0))
	_apply()


func pitch_deg() -> float:
	return lerpf(PITCH_MIN, PITCH_MAX, clampf(inverse_lerp(ZOOM_MIN, ZOOM_MAX, distance), 0.0, 1.0))


## Horizontal unit vectors for panning relative to the view.
func screen_right() -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


func screen_forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func _apply() -> void:
	if camera == null:
		return
	var pitch := deg_to_rad(pitch_deg())
	var back := Vector3(sin(yaw), 0.0, cos(yaw))
	camera.global_position = pivot + back * cos(pitch) * distance + Vector3.UP * sin(pitch) * distance
	camera.look_at(pivot, Vector3.UP)


func _clamp_pivot() -> void:
	pivot.x = clampf(pivot.x, 0.0, map_size)
	pivot.z = clampf(pivot.z, 0.0, map_size)
	pivot.y = 0.0


## Centres the view on `point` (smoothly unless `instant`).
func focus(point: Vector3, instant: bool = false) -> void:
	var target := Vector3(clampf(point.x, 0.0, map_size), 0.0, clampf(point.z, 0.0, map_size))
	if _focus_tween != null:
		_focus_tween.kill()
	if instant:
		pivot = target
		_apply()
		return
	_focus_tween = create_tween()
	_focus_tween.tween_property(self, "pivot", target, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func set_view(new_pivot: Vector3, new_distance: float, new_yaw: float) -> void:
	pivot = new_pivot
	distance = clampf(new_distance, ZOOM_MIN, ZOOM_MAX)
	target_distance = distance
	yaw = new_yaw
	target_yaw = new_yaw
	_clamp_pivot()
	_apply()


## Where the ray through a screen point meets the ground (y = 0), or null.
func screen_to_ground(p: Vector2) -> Variant:
	if camera == null:
		return null
	var from := camera.project_ray_origin(p)
	var dir := camera.project_ray_normal(p)
	if absf(dir.y) < 0.0001:
		return null
	var t := -from.y / dir.y
	if t < 0.0:
		return null
	return from + dir * t


## Ground points under the four screen corners (for the minimap view box).
func ground_corners() -> PackedVector3Array:
	var out := PackedVector3Array()
	var size := get_viewport().get_visible_rect().size
	for p: Vector2 in [Vector2(0, 0), Vector2(size.x, 0), Vector2(size.x, size.y), Vector2(0, size.y)]:
		var g: Variant = screen_to_ground(p)
		var gv: Vector3
		if g == null:
			var from := camera.project_ray_origin(p)
			var dir := camera.project_ray_normal(p)
			gv = from + Vector3(dir.x, 0.0, dir.z).normalized() * 400.0
			gv.y = 0.0
		else:
			gv = g
		out.append(gv)
	return out


func _process(delta: float) -> void:
	if input_enabled:
		_pan_from_keys_and_edges(delta)
	yaw = lerp_angle(yaw, target_yaw, clampf(1.0 - exp(-10.0 * delta), 0.0, 1.0))
	distance = lerpf(distance, target_distance, clampf(1.0 - exp(-12.0 * delta), 0.0, 1.0))
	_apply()
	if _zooming:
		var g: Variant = screen_to_ground(_zoom_anchor_screen)
		if g != null:
			pivot += _zoom_anchor_world - (g as Vector3)
			_clamp_pivot()
			_apply()
		if absf(distance - target_distance) < 0.01:
			_zooming = false


func _pan_from_keys_and_edges(delta: float) -> void:
	var v := Vector2.ZERO
	if not Input.is_key_pressed(KEY_CTRL):
		v.x = Input.get_action_strength("cam_right") - Input.get_action_strength("cam_left")
		v.y = Input.get_action_strength("cam_down") - Input.get_action_strength("cam_up")
	if edge_scroll and _mouse_in and not _drag_pan and not _drag_rotate and DisplayServer.window_is_focused():
		var vp := get_viewport()
		var mp := vp.get_mouse_position()
		var size := vp.get_visible_rect().size
		if mp.x >= 0.0 and mp.y >= 0.0 and mp.x <= size.x and mp.y <= size.y:
			if mp.x <= EDGE_PX:
				v.x -= 1.0
			elif mp.x >= size.x - EDGE_PX:
				v.x += 1.0
			if mp.y <= EDGE_PX:
				v.y -= 1.0
			elif mp.y >= size.y - EDGE_PX:
				v.y += 1.0
	if v == Vector2.ZERO:
		return
	v = v.limit_length(1.0)
	var speed := (8.0 + distance * 0.9) * pan_speed
	pivot += (screen_right() * v.x - screen_forward() * v.y) * speed * delta
	_clamp_pivot()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_in = true


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_MOUSE_EXIT, NOTIFICATION_WM_WINDOW_FOCUS_OUT, NOTIFICATION_APPLICATION_FOCUS_OUT:
			_mouse_in = false


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	var mb := event as InputEventMouseButton
	if mb != null:
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					var factor := 1.0 / ZOOM_STEP if mb.button_index == MOUSE_BUTTON_WHEEL_UP else ZOOM_STEP
					target_distance = clampf(target_distance * factor, ZOOM_MIN, ZOOM_MAX)
					var g: Variant = screen_to_ground(mb.position)
					if g != null:
						_zoom_anchor_screen = mb.position
						_zoom_anchor_world = g
						_zooming = true
					get_viewport().set_input_as_handled()
			MOUSE_BUTTON_MIDDLE:
				if mb.pressed:
					if mb.alt_pressed:
						_drag_rotate = true
					else:
						var g: Variant = screen_to_ground(mb.position)
						if g != null:
							_drag_pan = true
							_drag_anchor = g
				else:
					_drag_pan = false
					_drag_rotate = false
				get_viewport().set_input_as_handled()
		return
	var mm := event as InputEventMouseMotion
	if mm != null:
		if _drag_rotate:
			target_yaw -= mm.relative.x * 0.008
			yaw = target_yaw
			get_viewport().set_input_as_handled()
		elif _drag_pan:
			_zooming = false
			var g: Variant = screen_to_ground(mm.position)
			if g != null:
				pivot += _drag_anchor - (g as Vector3)
				_clamp_pivot()
				_apply()
			get_viewport().set_input_as_handled()
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.ctrl_pressed:
		if event.is_action("cam_left"):
			target_yaw = snappedf(target_yaw - ROTATE_STEP, ROTATE_STEP)
			get_viewport().set_input_as_handled()
		elif event.is_action("cam_right"):
			target_yaw = snappedf(target_yaw + ROTATE_STEP, ROTATE_STEP)
			get_viewport().set_input_as_handled()
