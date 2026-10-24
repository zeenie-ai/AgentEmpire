extends GutTest
## TouchGestures: touches and times in, tap / hold / drag / pinch intents out.

var g: TouchGestures


func before_each() -> void:
	g = TouchGestures.new()


func _kinds(intents: Array[Dictionary]) -> Array[String]:
	var out: Array[String] = []
	for it in intents:
		out.append(String(it["kind"]))
	return out


func _down(index: int, pos: Vector2, t_ms: int, double_tap: bool = false) -> Array[Dictionary]:
	return g.touch(index, pos, true, double_tap, false, t_ms)


func _up(index: int, pos: Vector2, t_ms: int, canceled: bool = false) -> Array[Dictionary]:
	return g.touch(index, pos, false, false, canceled, t_ms)


## A two-finger pinch started at a (index 0) and b (index 1).
func _pinch_at(a: Vector2, b: Vector2) -> void:
	_down(0, a, 0)
	assert_eq(_kinds(_down(1, b, 30)), ["pinch_begin"] as Array[String])


func test_a_tap_at_the_press_point() -> void:
	assert_eq(_down(0, Vector2(100, 100), 0), [] as Array[Dictionary])
	var out := _up(0, Vector2(103, 102), 120)
	assert_eq(_kinds(out), ["tap"] as Array[String])
	var p: Vector2 = out[0]["pos"]
	assert_eq(p, Vector2(100, 100))
	assert_false(bool(out[0]["double"]))


func test_a_double_tap_comes_from_the_engine() -> void:
	_down(0, Vector2(100, 100), 0)
	assert_false(bool(_up(0, Vector2(100, 100), 80)[0]["double"]))
	_down(0, Vector2(101, 100), 160, true)
	var out := _up(0, Vector2(101, 100), 230)
	assert_eq(_kinds(out), ["tap"] as Array[String])
	assert_true(bool(out[0]["double"]), "the second press was a double tap")


func test_small_moves_stay_a_tap() -> void:
	_down(0, Vector2(100, 100), 0)
	assert_eq(g.drag(0, Vector2(106, 104), 30), [] as Array[Dictionary], "7.2 dp is within the slop")
	assert_eq(_kinds(_up(0, Vector2(106, 104), 100)), ["tap"] as Array[String])


func test_moving_past_the_slop_drags() -> void:
	_down(0, Vector2(100, 100), 0)
	var out := g.drag(0, Vector2(109, 100), 30)
	assert_eq(_kinds(out), ["drag_begin", "drag"] as Array[String])
	var from: Vector2 = out[0]["pos"]
	var at: Vector2 = out[1]["pos"]
	assert_eq(from, Vector2(100, 100), "the drag begins where the finger went down")
	assert_eq(at, Vector2(109, 100))
	assert_eq(_kinds(g.drag(0, Vector2(150, 120), 60)), ["drag"] as Array[String])
	out = _up(0, Vector2(160, 125), 90)
	assert_eq(_kinds(out), ["drag_end"] as Array[String], "no tap after a drag")
	var end: Vector2 = out[0]["pos"]
	assert_eq(end, Vector2(160, 125))
	assert_false(bool(out[0]["canceled"]))


func test_the_slop_is_in_dp() -> void:
	g = TouchGestures.new(2.0)
	_down(0, Vector2(100, 100), 0)
	assert_eq(g.drag(0, Vector2(115, 100), 30), [] as Array[Dictionary], "15 px is 7.5 dp")
	assert_eq(_kinds(g.drag(0, Vector2(117, 100), 40)), ["drag_begin", "drag"] as Array[String])


func test_resting_400_ms_is_a_hold() -> void:
	_down(0, Vector2(100, 100), 1000)
	assert_eq(g.tick(1399), [] as Array[Dictionary])
	var out := g.tick(1400)
	assert_eq(_kinds(out), ["hold"] as Array[String])
	var p: Vector2 = out[0]["pos"]
	assert_eq(p, Vector2(100, 100))
	assert_eq(g.tick(1500), [] as Array[Dictionary], "once")
	assert_eq(g.drag(0, Vector2(200, 100), 1600), [] as Array[Dictionary], "then the finger does nothing")
	assert_eq(_up(0, Vector2(200, 100), 1700), [] as Array[Dictionary], "and lifting taps nothing")
	assert_eq(_kinds(_down(0, Vector2(50, 50), 2000)), [] as Array[String])
	assert_eq(_kinds(_up(0, Vector2(50, 50), 2050)), ["tap"] as Array[String], "the next press starts over")


func test_a_late_lift_is_still_a_hold() -> void:
	# No tick came in between (a slow frame): the lift notices the hold first.
	_down(0, Vector2(100, 100), 0)
	assert_eq(_kinds(_up(0, Vector2(100, 100), 450)), ["hold"] as Array[String])


func test_a_late_move_is_still_a_hold() -> void:
	_down(0, Vector2(100, 100), 0)
	assert_eq(_kinds(g.drag(0, Vector2(140, 100), 450)), ["hold"] as Array[String], "not a drag")


func test_a_second_finger_pinches() -> void:
	_down(0, Vector2(100, 100), 0)
	var out := _down(1, Vector2(300, 100), 40)
	assert_eq(_kinds(out), ["pinch_begin"] as Array[String])
	var c: Vector2 = out[0]["centre"]
	assert_eq(c, Vector2(200, 100))
	assert_eq(g.tick(600), [] as Array[Dictionary], "a pinch is never a hold")


func test_a_second_finger_ends_a_drag_first() -> void:
	_down(0, Vector2(100, 100), 0)
	g.drag(0, Vector2(140, 100), 30)
	var out := _down(1, Vector2(300, 100), 60)
	assert_eq(_kinds(out), ["drag_end", "pinch_begin"] as Array[String])
	assert_true(bool(out[0]["canceled"]), "the drag is canceled, not finished")
	var end: Vector2 = out[0]["pos"]
	assert_eq(end, Vector2(140, 100))
	var c: Vector2 = out[1]["centre"]
	assert_eq(c, Vector2(220, 100))


func test_moving_both_fingers_pans() -> void:
	_pinch_at(Vector2(100, 100), Vector2(300, 100))
	g.drag(0, Vector2(110, 105), 60)
	var out := g.drag(1, Vector2(310, 105), 60)
	assert_eq(_kinds(out), ["pinch"] as Array[String])
	var c: Vector2 = out[0]["centre"]
	assert_eq(c, Vector2(210, 105))
	assert_eq(float(out[0]["zoom"]), 1.0)
	assert_eq(float(out[0]["twist"]), 0.0)


func test_zoom_starts_after_16_dp() -> void:
	_pinch_at(Vector2(0, 0), Vector2(100, 0))
	var out := g.drag(1, Vector2(110, 0), 50)
	assert_eq(float(out[0]["zoom"]), 1.0, "10 dp: not yet")
	out = g.drag(1, Vector2(120, 0), 60)
	assert_eq(float(out[0]["zoom"]), 1.0, "20 dp: zoom starts here, without a jump")
	out = g.drag(1, Vector2(150, 0), 70)
	assert_almost_eq(float(out[0]["zoom"]), 120.0 / 150.0, 0.00001, "spreading: the camera comes closer")
	out = g.drag(1, Vector2(100, 0), 80)
	assert_almost_eq(float(out[0]["zoom"]), 150.0 / 100.0, 0.00001, "pinching in: it backs away")


func test_twist_starts_after_an_8_dp_arc() -> void:
	_pinch_at(Vector2(0, 0), Vector2(100, 0))
	var out := g.drag(1, Vector2.from_angle(0.1) * 100.0, 50)
	assert_eq(float(out[0]["twist"]), 0.0, "an arc of 5 dp: not yet")
	assert_eq(float(out[0]["zoom"]), 1.0, "turning keeps the span")
	out = g.drag(1, Vector2.from_angle(0.2) * 100.0, 60)
	assert_eq(float(out[0]["twist"]), 0.0, "10 dp: twist starts here, without a jump")
	out = g.drag(1, Vector2.from_angle(0.35) * 100.0, 70)
	assert_almost_eq(float(out[0]["twist"]), 0.15, 0.00001, "clockwise on screen is positive")
	out = g.drag(1, Vector2.from_angle(0.25) * 100.0, 80)
	assert_almost_eq(float(out[0]["twist"]), -0.1, 0.00001)


func test_twist_wraps_around() -> void:
	_pinch_at(Vector2(0, 0), Vector2(-100, 1))
	g.drag(1, Vector2(-100, 30), 50)
	var out := g.drag(1, Vector2(-100, -30), 60)
	assert_almost_eq(float(out[0]["twist"]), 2.0 * atan(30.0 / 100.0), 0.0001, "across the -x axis: no 2 pi jump")


func test_after_a_pinch_the_other_finger_waits() -> void:
	_pinch_at(Vector2(100, 100), Vector2(300, 100))
	assert_eq(_kinds(_up(1, Vector2(300, 100), 100)), ["pinch_end"] as Array[String])
	assert_eq(g.drag(0, Vector2(200, 200), 120), [] as Array[Dictionary], "no pan")
	assert_eq(g.tick(900), [] as Array[Dictionary], "no hold")
	assert_eq(_down(1, Vector2(300, 300), 950), [] as Array[Dictionary], "no new pinch")
	assert_eq(_up(1, Vector2(300, 300), 1000), [] as Array[Dictionary])
	assert_eq(_up(0, Vector2(200, 200), 1050), [] as Array[Dictionary], "no tap")
	assert_true(g.idle())
	_down(0, Vector2(10, 10), 1100)
	assert_eq(_kinds(_up(0, Vector2(10, 10), 1150)), ["tap"] as Array[String], "all lifted: it starts over")


func test_at_most_two_fingers() -> void:
	_pinch_at(Vector2(100, 100), Vector2(300, 100))
	assert_eq(_down(2, Vector2(200, 300), 50), [] as Array[Dictionary])
	assert_eq(g.drag(2, Vector2(250, 300), 60), [] as Array[Dictionary], "a third finger is ignored")
	assert_eq(_up(2, Vector2(250, 300), 70), [] as Array[Dictionary])
	assert_eq(_kinds(g.drag(0, Vector2(90, 100), 80)), ["pinch"] as Array[String], "the pinch goes on")


func test_a_canceled_touch_closes_what_is_open() -> void:
	_down(0, Vector2(100, 100), 0)
	assert_eq(_up(0, Vector2(100, 100), 50, true), [] as Array[Dictionary], "a canceled press taps nothing")
	_down(0, Vector2(100, 100), 100)
	g.drag(0, Vector2(150, 100), 130)
	var out := _up(0, Vector2(150, 100), 160, true)
	assert_eq(_kinds(out), ["drag_end"] as Array[String])
	assert_true(bool(out[0]["canceled"]))
	_pinch_at(Vector2(100, 100), Vector2(300, 100))
	assert_eq(_kinds(_up(0, Vector2(100, 100), 90, true)), ["pinch_end"] as Array[String])
	assert_eq(_up(1, Vector2(300, 100), 90, true), [] as Array[Dictionary])
	assert_true(g.idle())


func test_cancel_closes_what_is_open_and_forgets_the_fingers() -> void:
	_down(0, Vector2(100, 100), 0)
	g.drag(0, Vector2(150, 100), 30)
	var out := g.cancel()
	assert_eq(_kinds(out), ["drag_end"] as Array[String])
	assert_true(bool(out[0]["canceled"]))
	assert_true(g.idle())
	assert_eq(g.drag(0, Vector2(200, 100), 60), [] as Array[Dictionary], "the finger no longer counts")
	assert_eq(_up(0, Vector2(200, 100), 90), [] as Array[Dictionary])
	_pinch_at(Vector2(100, 100), Vector2(300, 100))
	assert_eq(_kinds(g.cancel()), ["pinch_end"] as Array[String])
	assert_eq(g.cancel(), [] as Array[Dictionary], "nothing left to close")
