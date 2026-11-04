class_name RiveSprite
extends Control
## One emblem of the Rive state tracker (RiveSprites): a task's seal or an agent's sigil, playing
## the loop of its state as the Rive state machine plays it. set_state() changes state the way
## the machine's transitions do: the new loop fades in over the old one for the set's blend time,
## with a small pop so the change catches the eye. Only a state the player has seen fades out: the
## first state after the sprite was made, or before it was ever drawn, simply appears. The frames
## fit the control's rect (centred, aspect kept) and draw with mipmaps, so a seal stays smooth at
## any HUD scale. It animates only while visible.

## A new state starts this much smaller and settles with a slight overshoot over POP_S.
const POP_FROM := 0.84
const POP_S := 0.34
## During a fade the new loop is fully drawn once this much of the blend has passed, so the
## emblem never turns see-through halfway.
const FADE_IN_SHARE := 0.6

## The Rive set: "task_seal" or "agent_sigil".
var set_name: String = ""
## The state shown. A state the bake has no sheet for shows the set's fallback.
var state: String = ""

var _sheet: Dictionary = {}
var _old: Dictionary = {}
var _old_t: float = 0.0
var _t: float = 0.0
var _blend: float = 1.0
var _pop: float = 1.0
var _frame: int = -1
## Whether the sprite has drawn anything yet: until then a change of state is nothing the player
## could see go, so it cuts.
var _drawn: bool = false


func _init(set_id: String = "task_seal", initial_state: String = "", px: float = 40.0) -> void:
	set_name = set_id
	custom_minimum_size = Vector2(px, px)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if initial_state != "":
		set_state(initial_state, false)


## Shows `new_state`: with `animate` (and something already shown) it fades and pops into it,
## otherwise it cuts.
func set_state(new_state: String, animate: bool = true) -> void:
	if new_state == state and not _sheet.is_empty():
		return
	var next := RiveSprites.sheet(set_name, new_state)
	state = new_state
	if animate and _drawn and not _sheet.is_empty() and is_visible_in_tree():
		# Changing again mid-fade: the sheet that shows more goes on fading out.
		if _old.is_empty() or _blend >= 0.5:
			_old = _sheet
			_old_t = _t
		_blend = 0.0
		if _pop >= 1.0:
			_pop = 0.0
	else:
		_old = {}
		_blend = 1.0
		_pop = 1.0
	_sheet = next
	_t = 0.0
	_frame = -1
	queue_redraw()


## Whether a state change is still fading or popping.
func is_changing() -> bool:
	return _blend < 1.0 or _pop < 1.0


## The frame of the current state's loop on screen.
func current_frame() -> int:
	return maxi(_frame, 0)


func _process(delta: float) -> void:
	if _sheet.is_empty() or not is_visible_in_tree():
		return
	_t += delta
	var changing := is_changing()
	if _blend < 1.0:
		var blend_s: float = _sheet.get("blend_s", 0.2)
		_blend = minf(1.0, _blend + delta / maxf(blend_s, 0.001))
		_old_t += delta
		if _blend >= 1.0:
			_old = {}
	if _pop < 1.0:
		_pop = minf(1.0, _pop + delta / POP_S)
	var f := RiveSprites.frame_at(_sheet, _t)
	if f != _frame or changing:
		_frame = f
		queue_redraw()


func _draw() -> void:
	if _sheet.is_empty():
		return
	var k := _pop_scale()
	if not _old.is_empty():
		_draw_sheet(_old, _old_t, k, 1.0 - _blend)
	_draw_sheet(_sheet, _t, k, minf(1.0, _blend / FADE_IN_SHARE) if not _old.is_empty() else 1.0)
	if size.x > 0.0 and size.y > 0.0:
		_drawn = true


func _pop_scale() -> float:
	if _pop >= 1.0:
		return 1.0
	# Ease out with a slight overshoot (easeOutBack).
	var c1 := 1.70158
	var x := _pop - 1.0
	var e := 1.0 + (c1 + 1.0) * x * x * x + c1 * x * x
	return lerpf(POP_FROM, 1.0, e)


func _draw_sheet(sh: Dictionary, t: float, scale_k: float, alpha: float) -> void:
	var tex: Texture2D = sh.get("texture")
	if tex == null or alpha <= 0.0:
		return
	var frame_size: Vector2 = sh.get("size", Vector2.ONE)
	var fit := minf(size.x / frame_size.x, size.y / frame_size.y) * scale_k
	var shown := frame_size * fit
	var box := Rect2((size - shown) * 0.5, shown)
	draw_texture_rect_region(tex, box, RiveSprites.frame_rect(sh, RiveSprites.frame_at(sh, t)), Color(1, 1, 1, alpha))
