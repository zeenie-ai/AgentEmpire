extends GutTest
## RtsCamera's mouse and keyboard controls: wheel zoom toward the cursor, middle-drag grabbing
## the ground, Alt+middle-drag turning, and Ctrl+Left/Right turning in 45-degree steps. Events
## go straight to _unhandled_input and the frames are stepped by hand, so every result is exact.

const FRAME := 1.0 / 60.0

var cam: RtsCamera


func before_each() -> void:
	cam = RtsCamera.new()
	add_child_autofree(cam)
	cam.edge_scroll = false
	cam.set_view(Vector3(64, 0, 64), 30.0, 0.0)


## A point on screen, as a fraction of the view.
func _at(fx: float, fy: float) -> Vector2:
	return cam.get_viewport().get_visible_rect().size * Vector2(fx, fy)


func _ground(s: Vector2) -> Vector3:
	var g: Variant = cam.screen_to_ground(s)
	assert_not_null(g, "%s sees the ground" % s)
	return g if g != null else Vector3.ZERO


func _settle(seconds: float = 2.0) -> void:
	for i in int(seconds / FRAME):
		cam._process(FRAME)


func _wheel(up: bool, at: Vector2) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
	e.position = at
	e.pressed = true
	cam._unhandled_input(e)


func _middle(pressed: bool, at: Vector2, alt: bool = false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_MIDDLE
	e.position = at
	e.pressed = pressed
	e.alt_pressed = alt
	cam._unhandled_input(e)


func _motion(to: Vector2, relative: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = to
	e.relative = relative
	cam._unhandled_input(e)


func _key(code: Key, ctrl: bool = true) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.keycode = code
	e.ctrl_pressed = ctrl
	e.pressed = true
	cam._unhandled_input(e)


func _assert_near(a: Vector3, b: Vector3, tolerance: float, what: String) -> void:
	assert_lt(a.distance_to(b), tolerance, "%s: %s vs %s" % [what, a, b])


func test_wheel_zooms_toward_the_cursor() -> void:
	var s := _at(0.7, 0.35)
	var under := _ground(s)
	_wheel(true, s)
	assert_almost_eq(cam.target_distance, 30.0 / RtsCamera.ZOOM_STEP, 0.0001, "one notch in")
	assert_almost_eq(cam.distance, 30.0, 0.0001, "the zoom glides there")
	assert_true(cam.user_moved_since_frame)
	_settle()
	assert_almost_eq(cam.distance, cam.target_distance, 0.01)
	_assert_near(_ground(s), under, 0.05, "the ground under the cursor stays under it")
	_wheel(false, s)
	assert_almost_eq(cam.target_distance, 30.0, 0.0001, "one notch out")
	_settle()
	_assert_near(_ground(s), under, 0.05, "zooming out too")


func test_wheel_stays_within_the_zoom_range() -> void:
	var s := _at(0.5, 0.5)
	for i in 30:
		_wheel(true, s)
	assert_almost_eq(cam.target_distance, RtsCamera.ZOOM_MIN, 0.0001)
	for i in 40:
		_wheel(false, s)
	assert_almost_eq(cam.target_distance, RtsCamera.ZOOM_MAX, 0.0001)


func test_middle_drag_grabs_the_ground() -> void:
	var s0 := _at(0.5, 0.6)
	var grabbed := _ground(s0)
	_middle(true, s0)
	assert_true(cam.user_moved_since_frame)
	var s1 := _at(0.4, 0.5)
	_motion(s1, s1 - s0)
	_assert_near(_ground(s1), grabbed, 0.001, "the grabbed ground follows the cursor")
	var s2 := _at(0.62, 0.45)
	_motion(s2, s2 - s1)
	_assert_near(_ground(s2), grabbed, 0.001, "and keeps following it")
	assert_almost_eq(cam.distance, 30.0, 0.0001, "panning keeps the zoom")
	assert_almost_eq(cam.yaw, 0.0, 0.0001, "and the turn")
	_middle(false, s2)
	var pivot := cam.pivot
	var s3 := _at(0.3, 0.3)
	_motion(s3, s3 - s2)
	assert_eq(cam.pivot, pivot, "released: the mouse moves freely")


func test_a_drag_ends_the_zoom_anchor() -> void:
	var s := _at(0.7, 0.35)
	_wheel(true, s)
	_middle(true, s)
	var s1 := _at(0.6, 0.35)
	_motion(s1, s1 - s)
	_middle(false, s1)
	var pivot := cam.pivot
	cam._process(FRAME)
	assert_eq(cam.pivot, pivot, "the zoom no longer pulls the pivot toward the old cursor")


func test_alt_middle_drag_turns() -> void:
	var s0 := _at(0.5, 0.5)
	_middle(true, s0, true)
	assert_true(cam.user_moved_since_frame)
	_motion(s0 + Vector2(50, 0), Vector2(50, 0))
	assert_almost_eq(cam.target_yaw, -0.4, 0.00001, "50 px right turns 0.4 rad")
	assert_almost_eq(cam.yaw, -0.4, 0.00001, "at once")
	_motion(s0 + Vector2(25, 30), Vector2(-25, 30))
	assert_almost_eq(cam.yaw, -0.2, 0.00001, "only the horizontal movement turns")
	assert_eq(cam.pivot, Vector3(64, 0, 64), "turning keeps the pivot")
	_middle(false, s0 + Vector2(25, 30), true)
	_motion(s0, Vector2(-25, -30))
	assert_almost_eq(cam.yaw, -0.2, 0.00001, "released")


func test_ctrl_arrows_turn_in_steps() -> void:
	_key(KEY_LEFT)
	assert_almost_eq(cam.target_yaw, -RtsCamera.ROTATE_STEP, 0.00001)
	assert_true(cam.user_moved_since_frame)
	_key(KEY_RIGHT)
	_key(KEY_RIGHT)
	assert_almost_eq(cam.target_yaw, RtsCamera.ROTATE_STEP, 0.00001)
	assert_almost_eq(cam.yaw, 0.0, 0.00001, "the turn glides there")
	_settle()
	assert_almost_eq(cam.yaw, RtsCamera.ROTATE_STEP, 0.001)


func test_ctrl_arrows_snap_to_the_steps() -> void:
	cam.set_view(Vector3(64, 0, 64), 30.0, 0.3)
	_key(KEY_RIGHT)
	assert_almost_eq(cam.target_yaw, RtsCamera.ROTATE_STEP, 0.00001, "0.3 + 45 degrees snaps to 45")
	cam.set_view(Vector3(64, 0, 64), 30.0, 0.3)
	_key(KEY_LEFT)
	assert_almost_eq(cam.target_yaw, -RtsCamera.ROTATE_STEP, 0.00001, "0.3 - 45 degrees snaps to -45")


func test_arrows_without_ctrl_do_not_turn() -> void:
	_key(KEY_LEFT, false)
	assert_almost_eq(cam.target_yaw, 0.0, 0.00001)
	assert_false(cam.user_moved_since_frame)


func test_input_ends_a_glide() -> void:
	var s := _at(0.5, 0.5)
	var inputs: Array[Callable] = [_wheel.bind(true, s), _middle.bind(true, s), _middle.bind(true, s, true), _key.bind(KEY_LEFT)]
	for send in inputs:
		cam.frame_ring(Vector3(64, 0, 64), 24.0, 4.0)
		assert_true(cam.in_cinema())
		send.call()
		assert_false(cam.in_cinema())
		_middle(false, s)


func test_an_instant_zoom_keeps_the_ground_under_its_point() -> void:
	var s := _at(0.35, 0.4)
	var under := _ground(s)
	cam.zoom_at(s, 0.8, false)
	assert_almost_eq(cam.distance, 24.0, 0.0001, "at once")
	assert_almost_eq(cam.target_distance, 24.0, 0.0001)
	assert_true(cam.user_moved_since_frame)
	_assert_near(_ground(s), under, 0.001, "the ground under the fingers stays")
	cam._process(FRAME)
	_assert_near(_ground(s), under, 0.001, "and the next frame leaves it there")
	cam.zoom_at(s, 0.01, false)
	assert_almost_eq(cam.distance, RtsCamera.ZOOM_MIN, 0.0001, "within the zoom range")


func test_two_fingers_carry_the_ground_while_zooming_and_turning() -> void:
	var c0 := _at(0.5, 0.55)
	var grabbed := _ground(c0)
	cam.grab(c0)
	assert_true(cam.user_moved_since_frame)
	var c1 := _at(0.42, 0.5)
	cam.zoom_at(c1, 0.9, false)
	cam.rotate_by(0.3)
	cam.drag_to(c1)
	assert_almost_eq(cam.distance, 27.0, 0.0001)
	assert_almost_eq(cam.yaw, 0.3, 0.00001)
	_assert_near(_ground(c1), grabbed, 0.001, "the ground between the fingers follows them")
	var c2 := _at(0.55, 0.6)
	cam.zoom_at(c2, 1.2, false)
	cam.rotate_by(-0.5)
	cam.drag_to(c2)
	assert_almost_eq(cam.distance, 32.4, 0.0001)
	assert_almost_eq(cam.yaw, -0.2, 0.00001)
	_assert_near(_ground(c2), grabbed, 0.001, "every frame of the pinch")
	cam.release()
	var pivot := cam.pivot
	cam.drag_to(_at(0.3, 0.3))
	assert_eq(cam.pivot, pivot, "released")
	cam._process(FRAME)
	assert_almost_eq(cam.yaw, -0.2, 0.00001, "the twist stays")


func test_disabled_input_is_ignored() -> void:
	cam.input_enabled = false
	var s := _at(0.5, 0.5)
	_wheel(true, s)
	_middle(true, s)
	_motion(s + Vector2(80, 0), Vector2(80, 0))
	_key(KEY_LEFT)
	assert_almost_eq(cam.target_distance, 30.0, 0.0001)
	assert_eq(cam.pivot, Vector3(64, 0, 64))
	assert_almost_eq(cam.target_yaw, 0.0, 0.00001)
	assert_false(cam.user_moved_since_frame)
