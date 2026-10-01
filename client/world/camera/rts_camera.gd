class_name RtsCamera
extends Node3D
## RTS camera.
## - Pan: arrow keys (cam_* actions), a 12 px screen edge, or middle-drag (grabs the ground).
## - Zoom: mouse wheel toward the cursor, 10 to 70 tiles from the pivot, tilting from 42 to 62
##   degrees as it zooms out.
## - Rotate: Ctrl+Left/Right in 45-degree steps, or Alt+middle-drag.
## - The pivot is clamped to the map.
## The world is seen through the part of the screen the HUD leaves free (safe_rect(), between
## the top bar and the bottom panel): focus() lands its target in the middle of that area, and
## frame() fits a set of points inside it at any window size. frame_ring() glides out to show a
## whole wall ring while it rises, then glides back; any camera input ends a glide at once.

## The player moved the camera (pan, zoom, rotate) since the last frame() or focus().
signal user_moved()

const ZOOM_MIN := 10.0
const ZOOM_MAX := 70.0
const PITCH_MIN := 42.0
const PITCH_MAX := 62.0
const EDGE_PX := 12.0
const ROTATE_STEP := PI / 4.0
const ZOOM_STEP := 1.14
const FOV := 40.0
## The opening view and focus jumps prefer this distance.
const DEFAULT_DISTANCE := 30.0
## A wall-rise glide may pull back this far to show a whole ring.
const CINEMA_MAX := 150.0
const CINEMA_IN_S := 1.2
const CINEMA_OUT_S := 1.5
## Edge scrolling waits this long after the window gains the mouse or focus, so a window that
## opens under a resting cursor does not drift.
const EDGE_GRACE_S := 0.6

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
## Returns the screen area (Rect2, viewport coordinates) the world is seen through; the whole
## viewport when unset or empty. The main scene points it at the space between the HUD's bars.
var safe_rect_provider: Callable = Callable()
## True while the player has moved the camera since the last frame() or focus().
var user_moved_since_frame: bool = false

var _drag_pan: bool = false
var _drag_rotate: bool = false
var _drag_anchor: Vector3 = Vector3.ZERO
var _zoom_anchor_screen: Vector2 = Vector2.ZERO
var _zoom_anchor_world: Vector3 = Vector3.ZERO
var _zooming: bool = false
var _focus_tween: Tween
var _cinema: Tween
## Where the camera was before a wall-rise glide: {"pivot", "distance", "yaw"}.
var _cinema_from: Dictionary = {}
## Edge scrolling waits for a real mouse movement over the window: before one, and after the
## pointer leaves or focus is lost, the reported position (often 0, 0) is not where it is.
var _mouse_in: bool = false
var _edge_wait: float = EDGE_GRACE_S


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
	return _pitch_for(distance)


static func _pitch_for(dist: float) -> float:
	return lerpf(PITCH_MIN, PITCH_MAX, clampf(inverse_lerp(ZOOM_MIN, ZOOM_MAX, dist), 0.0, 1.0))


## Horizontal unit vectors for panning relative to the view.
func screen_right() -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


func screen_forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func _apply() -> void:
	if camera == null:
		return
	camera.global_transform = _rig(pivot, distance, yaw)


## The camera's transform for a pivot, distance and yaw.
static func _rig(at: Vector3, dist: float, yaw_angle: float) -> Transform3D:
	var pitch := deg_to_rad(_pitch_for(dist))
	var back := Vector3(sin(yaw_angle), 0.0, cos(yaw_angle))
	var eye := at + back * cos(pitch) * dist + Vector3.UP * sin(pitch) * dist
	return Transform3D(Basis.looking_at(at - eye, Vector3.UP), eye)


func _clamp_pivot() -> void:
	pivot = _clamped(pivot)


func _clamped(p: Vector3) -> Vector3:
	return Vector3(clampf(p.x, 0.0, map_size), 0.0, clampf(p.z, 0.0, map_size))


# --- the visible area ---------------------------------------------------------------------------

## The screen area the world is seen through (viewport coordinates).
func safe_rect() -> Rect2:
	var full := get_viewport().get_visible_rect() if is_inside_tree() else Rect2(0, 0, 1600, 900)
	if safe_rect_provider.is_valid():
		var r: Variant = safe_rect_provider.call()
		if r is Rect2:
			var clipped := (r as Rect2).intersection(full)
			if clipped.size.x > 64.0 and clipped.size.y > 64.0:
				return clipped
	return full


func _view_size() -> Vector2:
	return get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(1600, 900)


## Screen point (viewport coordinates) of `p` seen from camera transform `xf`, or null when `p`
## is behind the camera.
func project(xf: Transform3D, p: Vector3) -> Variant:
	var size := _view_size()
	var local := xf.affine_inverse() * p
	if local.z > -0.01:
		return null
	var t := tan(deg_to_rad(camera.fov if camera != null else FOV) * 0.5)
	var nx := (local.x / -local.z) / (t * size.x / size.y)
	var ny := (local.y / -local.z) / t
	return Vector2((nx + 1.0) * 0.5 * size.x, (1.0 - ny) * 0.5 * size.y)


## Where the ray through screen point `s` meets the plane y = `h`, seen from transform `xf`.
func ground_hit(xf: Transform3D, s: Vector2, h: float = 0.0) -> Vector3:
	var size := _view_size()
	var t := tan(deg_to_rad(camera.fov if camera != null else FOV) * 0.5)
	var nx := s.x / size.x * 2.0 - 1.0
	var ny := 1.0 - s.y / size.y * 2.0
	var dir := xf.basis * Vector3(nx * t * size.x / size.y, ny * t, -1.0)
	if absf(dir.y) < 0.00001:
		return xf.origin
	return xf.origin + dir * ((h - xf.origin.y) / dir.y)


## The pivot that shows `point` in the middle of the safe area at `dist` and `yaw_angle`.
func pivot_for(point: Vector3, dist: float, yaw_angle: float) -> Vector3:
	var hit := ground_hit(_rig(Vector3.ZERO, dist, yaw_angle), safe_rect().get_center(), point.y)
	return _clamped(Vector3(point.x - hit.x, 0.0, point.z - hit.z))


## Centres the view on `point` (smoothly unless `instant`): it lands in the middle of the area
## the HUD leaves free.
func focus(point: Vector3, instant: bool = false) -> void:
	end_cinema(false)
	user_moved_since_frame = false
	var target := pivot_for(point, target_distance, target_yaw)
	if _focus_tween != null:
		_focus_tween.kill()
	if instant:
		pivot = target
		_apply()
		return
	_focus_tween = create_tween()
	_focus_tween.tween_property(self, "pivot", target, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## Fits `points` inside the safe area with `margin` (a fraction of its height) around them: at
## `prefer` distance when they fit, further out (up to `max_dist`) when they do not. Returns
## {"pivot", "distance"}; applies it at once unless `apply` is false.
func frame(points: PackedVector3Array, prefer: float = DEFAULT_DISTANCE, margin: float = 0.07,
		apply: bool = true, max_dist: float = ZOOM_MAX, yaw_angle: float = NAN) -> Dictionary:
	var yw := target_yaw if is_nan(yaw_angle) else yaw_angle
	var safe := safe_rect()
	var pad := safe.size.y * margin
	var inner := safe.grow(-pad)
	var dist := clampf(prefer, ZOOM_MIN, max_dist)
	var at := _fit(points, dist, yw, safe)
	while dist < max_dist and not _fits(points, at, dist, yw, inner):
		dist = minf(dist * 1.07, max_dist)
		at = _fit(points, dist, yw, safe)
	if apply:
		end_cinema(false)
		if _focus_tween != null:
			_focus_tween.kill()
		set_view(at, dist, yw)
		user_moved_since_frame = false
	return {"pivot": at, "distance": dist}


## The pivot that centres the screen bounds of `points` in `safe` (iterated: the projection is
## not linear).
func _fit(points: PackedVector3Array, dist: float, yaw_angle: float, safe: Rect2) -> Vector3:
	var centre := Vector3.ZERO
	for p in points:
		centre += p
	centre /= maxf(float(points.size()), 1.0)
	var at := pivot_for(Vector3(centre.x, 0.0, centre.z), dist, yaw_angle)
	for i in 4:
		var box := _screen_box(points, _rig(at, dist, yaw_angle))
		if box.size == Vector2.ZERO:
			break
		var xf := _rig(at, dist, yaw_angle)
		var from := ground_hit(xf, box.get_center())
		var to := ground_hit(xf, safe.get_center())
		at = _clamped(at + (from - to))
	return at


func _fits(points: PackedVector3Array, at: Vector3, dist: float, yaw_angle: float, inner: Rect2) -> bool:
	var xf := _rig(at, dist, yaw_angle)
	for p in points:
		var s: Variant = project(xf, p)
		if s == null or not inner.has_point(s):
			return false
	return true


func _screen_box(points: PackedVector3Array, xf: Transform3D) -> Rect2:
	var box := Rect2()
	var first := true
	for p in points:
		var s: Variant = project(xf, p)
		if s == null:
			continue
		if first:
			box = Rect2(s, Vector2.ZERO)
			first = false
		else:
			box = box.expand(s)
	return box


func set_view(new_pivot: Vector3, new_distance: float, new_yaw: float) -> void:
	pivot = new_pivot
	distance = clampf(new_distance, ZOOM_MIN, CINEMA_MAX)
	target_distance = distance
	yaw = new_yaw
	target_yaw = new_yaw
	_clamp_pivot()
	_apply()


# --- wall-rise glide ----------------------------------------------------------------------------

## Glides out to show the whole ring (`center`, `radius` on the ground, walls `height` tall), holds
## for `seconds`, then glides back to where the player was looking.
func frame_ring(center: Vector3, radius: float, seconds: float, height: float = 4.0) -> void:
	var points := PackedVector3Array()
	for i in 24:
		var a := TAU * float(i) / 24.0
		var p := center + Vector3(cos(a), 0.0, sin(a)) * radius
		points.append(p)
		points.append(p + Vector3.UP * height)
	var plan := frame(points, maxf(target_distance, DEFAULT_DISTANCE), 0.04, false, CINEMA_MAX)
	end_cinema(false)
	if _focus_tween != null:
		_focus_tween.kill()
	_cinema_from = {"pivot": pivot, "distance": target_distance, "yaw": target_yaw}
	_zooming = false
	_cinema = create_tween()
	_cinema.set_parallel(true)
	_cinema.tween_property(self, "pivot", plan["pivot"], CINEMA_IN_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_cinema.tween_property(self, "target_distance", plan["distance"], CINEMA_IN_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_cinema.chain().tween_interval(maxf(seconds - CINEMA_IN_S, 0.4))
	_cinema.chain().tween_callback(end_cinema.bind(true))


## Ends a wall-rise glide: `back` glides to where the player was looking before it; otherwise the
## camera stays where it is (the player took over).
func end_cinema(back: bool) -> void:
	if _cinema != null:
		_cinema.kill()
		_cinema = null
	if _cinema_from.is_empty():
		return
	var from := _cinema_from
	_cinema_from = {}
	if not back:
		target_distance = clampf(target_distance, ZOOM_MIN, ZOOM_MAX)
		return
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "pivot", from["pivot"], CINEMA_OUT_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(self, "target_distance", from["distance"], CINEMA_OUT_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_focus_tween = tw


func in_cinema() -> bool:
	return not _cinema_from.is_empty()


## The player moved the camera: any glide ends where it is.
func _player_moved() -> void:
	user_moved_since_frame = true
	if in_cinema():
		end_cinema(false)
	user_moved.emit()


# --- per frame and input -----------------------------------------------------------------------------

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
	_edge_wait = maxf(_edge_wait - delta, 0.0)
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
	if edge_scroll and _mouse_in and _edge_wait <= 0.0 and not _drag_pan and not _drag_rotate and DisplayServer.window_is_focused():
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
	_player_moved()
	if _focus_tween != null and _focus_tween.is_running():
		_focus_tween.kill()
	v = v.limit_length(1.0)
	var speed := (8.0 + distance * 0.9) * pan_speed
	pivot += (screen_right() * v.x - screen_forward() * v.y) * speed * delta
	_clamp_pivot()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if not _mouse_in:
			_edge_wait = EDGE_GRACE_S
		_mouse_in = true


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_MOUSE_EXIT, NOTIFICATION_WM_WINDOW_FOCUS_OUT, NOTIFICATION_APPLICATION_FOCUS_OUT:
			_mouse_in = false
		NOTIFICATION_WM_WINDOW_FOCUS_IN, NOTIFICATION_APPLICATION_FOCUS_IN:
			_edge_wait = EDGE_GRACE_S


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	var mb := event as InputEventMouseButton
	if mb != null:
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_player_moved()
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
					_player_moved()
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
			_player_moved()
			target_yaw = snappedf(target_yaw - ROTATE_STEP, ROTATE_STEP)
			get_viewport().set_input_as_handled()
		elif event.is_action("cam_right"):
			_player_moved()
			target_yaw = snappedf(target_yaw + ROTATE_STEP, ROTATE_STEP)
			get_viewport().set_input_as_handled()
