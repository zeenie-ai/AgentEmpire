class_name TouchGestures
extends RefCounted
## Turns raw touches into gestures: tap, hold, one-finger drag, and the two-finger pinch (zoom,
## twist, pan). Pure logic, events and times in and intents out, so it can be tested without a
## window. TouchControls feeds it and acts on the intents.
##
## Each intent is a Dictionary with a "kind" and its fields:
##   tap {pos, double}, hold {pos}, drag_begin {pos}, drag {pos}, drag_end {pos, canceled},
##   pinch_begin {centre}, pinch {centre, zoom, twist}, pinch_end {}.
## Positions are viewport coordinates; thresholds are in dp, times in milliseconds.
##
## - A press that lifts within Platform.TOUCH_SLOP_DP of where it went down, before
##   Platform.LONG_PRESS_MS, is a tap at the press point; `double` is the engine's double_tap on
##   that press. One held that long without moving is a hold.
## - Moving further starts a drag: drag_begin at the press point, then drag at each move.
## - A second finger starts a pinch (closing a drag first, as canceled). Its centre is the
##   fingers' midpoint; `zoom` is the camera distance factor since the last pinch (below 1 when
##   they spread apart) and `twist` the turn since the last one, in radians (positive when they
##   turn clockwise on screen). Zoom waits until the span has changed by SPAN_SLOP_DP, twist
##   until the fingers have turned through an arc of Platform.TOUCH_SLOP_DP, so a pinch can pan
##   without zooming or turning.
## - At most two fingers count. After a hold or a pinch, the fingers left do nothing until all
##   of them have lifted. A canceled touch closes what is open and taps nothing.

enum State { IDLE, PRESS, DRAG, PINCH, DONE }

## A pinch zooms once its span has changed by this much: twice the touch slop, as Android's
## ScaleGestureDetector does.
const SPAN_SLOP_DP := Platform.TOUCH_SLOP_DP * 2.0

## Logical pixels per dp (Platform.px_per_dp), for the dp thresholds.
var px_per_dp: float = 1.0

var _state: State = State.IDLE
## The fingers that count (index -> position), at most two, in the order they went down.
var _down: Dictionary = {}
## The first finger's press.
var _press_pos: Vector2 = Vector2.ZERO
var _press_ms: int = 0
var _press_double: bool = false
## The pinch: where its span and angle started, the last ones reported, and whether zoom and
## twist have started.
var _span0: float = 0.0
var _angle0: float = 0.0
var _span: float = 0.0
var _angle: float = 0.0
var _zooming: bool = false
var _twisting: bool = false


func _init(pixels_per_dp: float = 1.0) -> void:
	px_per_dp = pixels_per_dp


## A finger went down or up (or the system canceled it). Returns the intents this completes.
func touch(index: int, pos: Vector2, pressed: bool, double_tap: bool, canceled: bool, t_ms: int) -> Array[Dictionary]:
	var out := _held(t_ms)
	if pressed:
		_press(index, pos, double_tap, t_ms, out)
	else:
		_lift(index, pos, canceled, out)
	return out


## A finger moved. Returns the intents this completes.
func drag(index: int, pos: Vector2, t_ms: int) -> Array[Dictionary]:
	var out := _held(t_ms)
	if not _down.has(index):
		return out
	_down[index] = pos
	match _state:
		State.PRESS:
			if pos.distance_to(_press_pos) > Platform.TOUCH_SLOP_DP * px_per_dp:
				_state = State.DRAG
				out.append({"kind": "drag_begin", "pos": _press_pos})
				out.append({"kind": "drag", "pos": pos})
		State.DRAG:
			out.append({"kind": "drag", "pos": pos})
		State.PINCH:
			out.append(_pinch())
	return out


## Time passed: a press held long enough becomes a hold.
func tick(t_ms: int) -> Array[Dictionary]:
	return _held(t_ms)


## Input was taken away (a window opened): closes what is open, as a canceled touch would, and
## forgets the fingers.
func cancel() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	match _state:
		State.DRAG:
			var at: Vector2 = _down.values()[0]
			out.append({"kind": "drag_end", "pos": at, "canceled": true})
		State.PINCH:
			out.append({"kind": "pinch_end"})
	_down.clear()
	_state = State.IDLE
	return out


## True while no finger counts.
func idle() -> bool:
	return _state == State.IDLE


## The press has become a hold when it has rested long enough, whichever event notices first.
func _held(t_ms: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _state == State.PRESS and t_ms - _press_ms >= Platform.LONG_PRESS_MS:
		_state = State.DONE
		out.append({"kind": "hold", "pos": _press_pos})
	return out


func _press(index: int, pos: Vector2, double_tap: bool, t_ms: int, out: Array[Dictionary]) -> void:
	if _down.has(index) or _down.size() >= 2:
		return
	_down[index] = pos
	match _state:
		State.IDLE:
			_state = State.PRESS
			_press_pos = pos
			_press_ms = t_ms
			_press_double = double_tap
		State.PRESS:
			_begin_pinch(out)
		State.DRAG:
			var at: Vector2 = _down.values()[0]
			out.append({"kind": "drag_end", "pos": at, "canceled": true})
			_begin_pinch(out)


func _lift(index: int, pos: Vector2, canceled: bool, out: Array[Dictionary]) -> void:
	if not _down.has(index):
		return
	_down.erase(index)
	match _state:
		State.PRESS:
			if not canceled:
				out.append({"kind": "tap", "pos": _press_pos, "double": _press_double})
		State.DRAG:
			out.append({"kind": "drag_end", "pos": pos, "canceled": canceled})
		State.PINCH:
			out.append({"kind": "pinch_end"})
	_state = State.IDLE if _down.is_empty() else State.DONE


func _begin_pinch(out: Array[Dictionary]) -> void:
	_state = State.PINCH
	var a: Vector2 = _down.values()[0]
	var b: Vector2 = _down.values()[1]
	_span0 = a.distance_to(b)
	_angle0 = (b - a).angle()
	_span = _span0
	_angle = _angle0
	_zooming = false
	_twisting = false
	out.append({"kind": "pinch_begin", "centre": (a + b) * 0.5})


func _pinch() -> Dictionary:
	var a: Vector2 = _down.values()[0]
	var b: Vector2 = _down.values()[1]
	var span := maxf(a.distance_to(b), 1.0)
	var angle := (b - a).angle()
	# Each starts where its threshold is crossed, so neither jumps.
	if not _zooming and absf(span - _span0) > SPAN_SLOP_DP * px_per_dp:
		_zooming = true
		_span = span
	if not _twisting and absf(angle_difference(_angle0, angle)) * span * 0.5 > Platform.TOUCH_SLOP_DP * px_per_dp:
		_twisting = true
		_angle = angle
	var zoom := 1.0
	if _zooming:
		zoom = _span / span
		_span = span
	var twist := 0.0
	if _twisting:
		twist = angle_difference(_angle, angle)
		_angle = angle
	return {"kind": "pinch", "centre": (a + b) * 0.5, "zoom": zoom, "twist": twist}
