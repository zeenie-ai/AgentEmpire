extends GutTest
## RtsCamera sees the world through the area the HUD leaves free: focus() lands targets in its
## middle and frame() fits points inside it, whatever that area is.

## A 1600x900 view with a 46 px bar on top and a 214 px panel below.
const SAFE := Rect2(0, 46, 1600, 640)

var cam: RtsCamera


func before_each() -> void:
	cam = RtsCamera.new()
	add_child_autofree(cam)
	cam.safe_rect_provider = func() -> Rect2: return _safe()
	cam.set_view(Vector3(64, 0, 64), 30.0, 0.0)


## The safe area scaled to the actual view size (the test window may differ from 1600x900).
func _safe() -> Rect2:
	var size := cam.get_viewport().get_visible_rect().size
	var k := size / Vector2(1600, 900)
	return Rect2(SAFE.position * k, SAFE.size * k)


func _screen(p: Vector3) -> Vector2:
	var s: Variant = cam.project(cam.camera.global_transform, p)
	assert_not_null(s, "%s is in front of the camera" % p)
	return s if s != null else Vector2.ZERO


func test_projection_matches_the_engine() -> void:
	var p := Vector3(70, 1.5, 60)
	var ours := _screen(p)
	var engine := cam.camera.unproject_position(p)
	assert_almost_eq(ours.x, engine.x, 1.0)
	assert_almost_eq(ours.y, engine.y, 1.0)


func test_focus_lands_in_the_middle_of_the_free_area() -> void:
	for p: Vector3 in [Vector3(40, 0, 50), Vector3(64, 0, 64), Vector3(90, 0, 80)]:
		cam.focus(p, true)
		var s := _screen(p)
		var mid := _safe().get_center()
		assert_almost_eq(s.x, mid.x, 2.0, "x of %s" % p)
		assert_almost_eq(s.y, mid.y, 2.0, "y of %s, not the screen's middle" % p)


func test_focus_keeps_the_zoom_and_turn() -> void:
	cam.set_view(Vector3(64, 0, 64), 22.0, deg_to_rad(45.0))
	cam.focus(Vector3(50, 0, 70), true)
	assert_almost_eq(cam.distance, 22.0, 0.001)
	assert_almost_eq(cam.yaw, deg_to_rad(45.0), 0.001)
	var s := _screen(Vector3(50, 0, 70))
	assert_almost_eq(s.y, _safe().get_center().y, 2.0)


func test_frame_fits_everything_inside() -> void:
	var pts := PackedVector3Array([Vector3(60, 0, 60), Vector3(68, 0, 60), Vector3(64, 7.6, 64),
		Vector3(60, 0, 72), Vector3(69, 1.1, 71)])
	var plan := cam.frame(pts, 30.0, 0.06)
	var inner := _safe().grow(-_safe().size.y * 0.06 + 1.0)
	for p in pts:
		assert_true(inner.has_point(_screen(p)), "%s is inside the free area" % p)
	assert_almost_eq(float(plan["distance"]), 30.0, 0.01, "they fit at the preferred zoom")


func test_frame_pulls_back_when_needed() -> void:
	var pts := PackedVector3Array()
	for i in 16:
		var a := TAU * float(i) / 16.0
		pts.append(Vector3(64 + cos(a) * 22.0, 0, 64 + sin(a) * 22.0))
	var plan := cam.frame(pts, 30.0, 0.04, true, 150.0)
	assert_gt(float(plan["distance"]), 30.0)
	for p in pts:
		assert_true(_safe().has_point(_screen(p)), "%s fits" % p)


func test_ring_glide_goes_out_and_comes_back() -> void:
	cam.set_view(Vector3(70, 0, 66), 30.0, 0.0)
	var before := cam.pivot
	cam.frame_ring(Vector3(64, 0, 64), 24.0, 2.0)
	assert_true(cam.in_cinema())
	cam.end_cinema(true)
	assert_false(cam.in_cinema())
	# Gliding back: the tween heads for where the player was looking.
	await wait_seconds(RtsCamera.CINEMA_OUT_S + 0.3)
	assert_almost_eq(cam.pivot.distance_to(before), 0.0, 0.05)


func test_player_input_ends_a_glide_where_it_is() -> void:
	cam.frame_ring(Vector3(64, 0, 64), 24.0, 4.0)
	cam._player_moved()
	assert_false(cam.in_cinema())
	assert_lte(cam.target_distance, RtsCamera.ZOOM_MAX)
