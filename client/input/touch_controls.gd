class_name TouchControls
extends Node
## Touch in the world on phones and tablets. Reads InputEventScreenTouch and ScreenDrag through
## TouchGestures and turns the gestures into RtsInput and RtsCamera calls:
## - a tap: RtsInput.tap_at(), which selects, or gives selected townsfolk the order a
##   right-click gives; while placing it moves the ghost, in rally mode it sets the point;
## - a long press: selects without giving an order (while placing or rallying, a tap);
## - one finger: grabs the ground and pans; while the Select toggle is on it draws a selection
##   box instead (one box, then the toggle turns off); while placing, a drag that starts on the
##   ghost moves the ghost;
## - two fingers: pinch to zoom, twist to turn, both carrying the ground between them along.
## HUD touches never get here: its controls stop them (and its buttons take the mouse events the
## engine emulates from touches). Nothing is read while a window is open or no town runs, and
## the camera stays put while its input is off (scripted views).
## GameMain creates this only when Platform.is_mobile().

## What the open one-finger drag does.
enum Drag { NONE, PAN, BOX, GHOST }

var view: WorldView
var camera: RtsCamera
var selection: Selection
var input: RtsInput
var hud: Hud
var gestures: TouchGestures = TouchGestures.new()

var _drag: Drag = Drag.NONE
var _box_from: Vector2 = Vector2.ZERO
## From the finger moving the ghost to the ghost's middle, on screen.
var _ghost_offset: Vector2 = Vector2.ZERO


func setup(world_view: WorldView, rts_camera: RtsCamera, sel: Selection, rts_input: RtsInput, hud_layer: Hud) -> void:
	view = world_view
	camera = rts_camera
	selection = sel
	input = rts_input
	hud = hud_layer
	gestures.px_per_dp = Platform.px_per_dp(get_viewport())


func _unhandled_input(event: InputEvent) -> void:
	var st := event as InputEventScreenTouch
	var sd := event as InputEventScreenDrag
	if st == null and sd == null:
		return
	if _blocked():
		_act(gestures.cancel())
		return
	if st != null:
		_act(gestures.touch(st.index, st.position, st.pressed, st.double_tap, st.canceled, Time.get_ticks_msec()))
	else:
		_act(gestures.drag(sd.index, sd.position, Time.get_ticks_msec()))
	get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if _blocked():
		_act(gestures.cancel())
		return
	_act(gestures.tick(Time.get_ticks_msec()))


## No town, or a window over it: what is open closes and touches are ignored.
func _blocked() -> bool:
	return Game.world == null or hud.has_window()


func _act(intents: Array[Dictionary]) -> void:
	for it in intents:
		match String(it["kind"]):
			"tap":
				_on_tap(it)
			"hold":
				_on_hold(it)
			"drag_begin":
				_on_drag_begin(it)
			"drag":
				_on_drag(it)
			"drag_end":
				_on_drag_end(it)
			"pinch_begin":
				_on_pinch_begin(it)
			"pinch":
				_on_pinch(it)
			"pinch_end":
				_on_pinch_end()


func _on_tap(it: Dictionary) -> void:
	var p: Vector2 = it["pos"]
	input.tap_at(p, bool(it["double"]))


func _on_hold(it: Dictionary) -> void:
	var p: Vector2 = it["pos"]
	if input.mode == RtsInput.Mode.SELECT:
		input.select_at(p)
	else:
		input.tap_at(p, false)


func _on_drag_begin(it: Dictionary) -> void:
	var p: Vector2 = it["pos"]
	if input.mode == RtsInput.Mode.SELECT and input.drag_selects:
		_drag = Drag.BOX
		_box_from = p
		hud.set_box(Rect2(p, Vector2.ZERO))
	elif input.ghost_contains(p):
		_drag = Drag.GHOST
		_ghost_offset = camera.camera.unproject_position(view.ghost.global_position) - p
	elif camera.input_enabled:
		_drag = Drag.PAN
		camera.grab(p)
	else:
		_drag = Drag.NONE


func _on_drag(it: Dictionary) -> void:
	var p: Vector2 = it["pos"]
	match _drag:
		Drag.BOX:
			hud.set_box(Rect2(_box_from, p - _box_from).abs())
		Drag.GHOST:
			input.move_ghost(p + _ghost_offset)
		Drag.PAN:
			camera.drag_to(p)


## A box selects when the finger lifts (a second finger cancels it, and the Select toggle stays
## on for the next drag).
func _on_drag_end(it: Dictionary) -> void:
	var p: Vector2 = it["pos"]
	match _drag:
		Drag.BOX:
			hud.set_box(Rect2())
			if not bool(it["canceled"]):
				input.box_select(Rect2(_box_from, p - _box_from).abs())
				input.set_drag_selects(false)
		Drag.PAN:
			camera.release()
	_drag = Drag.NONE


func _on_pinch_begin(it: Dictionary) -> void:
	if camera.input_enabled:
		var c: Vector2 = it["centre"]
		camera.grab(c)


## The ground between the fingers follows them while they zoom and turn the view.
func _on_pinch(it: Dictionary) -> void:
	if not camera.input_enabled:
		return
	var c: Vector2 = it["centre"]
	var zoom := float(it["zoom"])
	var twist := float(it["twist"])
	if zoom != 1.0:
		camera.zoom_at(c, zoom, false)
	if twist != 0.0:
		camera.rotate_by(twist)
	camera.drag_to(c)


func _on_pinch_end() -> void:
	camera.release()
