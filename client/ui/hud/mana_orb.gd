class_name ManaOrb
extends Control
## The Mana orb: an animated globe of liquid (mana_orb.gdshader). Mana is the real-money
## budget (1 Mana = $0.01) owned by the Town Hall. Without a Town Hall the orb is dim, low and
## still, and reads "offline". Online, set_mana() fills it with the share of the pool left and
## shows the Mana remaining; the Town Hall's levels map to the looks below ("dim" is "low",
## "depleted" is "dark"). Clicking it opens the budget (`pressed`).

const SHADER := preload("res://ui/hud/mana_orb.gdshader")
const LEVELS := {
	"offline": {"fill": 0.32, "activity": 0.0, "top": Color("#6f8f86"), "deep": Color("#1c2c3a"), "glow": 0.0},
	"normal": {"fill": 0.72, "activity": 1.0, "top": Color("#a9f0d0"), "deep": Color("#1a6a78"), "glow": 0.7},
	"low": {"fill": 0.3, "activity": 0.8, "top": Color("#f0c27a"), "deep": Color("#7a4a1a"), "glow": 0.5},
	"warning": {"fill": 0.14, "activity": 0.9, "top": Color("#ff9a78"), "deep": Color("#7a2418"), "glow": 0.6},
	"dark": {"fill": 0.02, "activity": 0.2, "top": Color("#50506a"), "deep": Color("#141422"), "glow": 0.0},
}

signal pressed()

var level: String = ""
## What the label shows under MANA (the level offline, the Mana left online).
var caption: String = ""
var _orb: ColorRect
var _mat: ShaderMaterial
var _tween: Tween


func _init() -> void:
	custom_minimum_size = Vector2(132, 38)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_PASS
	tooltip_text = "Mana is your real budget (1 Mana = $0.01).\nIt appears here once the Town Hall is connected."
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_orb = ColorRect.new()
	_orb.material = _mat
	_orb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_orb.custom_minimum_size = Vector2(38, 38)
	_orb.size = Vector2(38, 38)
	add_child(_orb)
	set_level("offline")


## The Town Hall's Mana object (PROTOCOL.md) and its level; {} and "offline" without one.
func set_mana(protocol_level: String, mana: Dictionary) -> void:
	var look := {"dim": "low", "depleted": "dark"}.get(protocol_level, protocol_level) as String
	set_level(look)
	if mana.is_empty() or look == "offline":
		caption = "offline"
		tooltip_text = "Mana is your real budget (1 Mana = $0.01).
It appears here once the Town Hall is connected."
		queue_redraw()
		return
	var per := 10000.0
	var cap := J.f(mana.get("cap_micros")) / per
	var left := J.f(mana.get("remaining_micros")) / per
	var spent := J.f(mana.get("spent_micros")) / per
	var reserved := J.f(mana.get("reserved_micros")) / per
	caption = "%d / %d" % [int(round(left)), int(round(cap))]
	if cap > 0.0:
		var target := clampf(left / cap, 0.03, 0.95) if left > 0.0 else 0.02
		var from: Variant = _mat.get_shader_parameter("fill")
		if _tween != null:
			_tween.kill()
		_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_method(func(v: float) -> void: _mat.set_shader_parameter("fill", v), float(from) if from != null else target, target, 0.6)
	var est := " (estimates)" if J.b(mana.get("estimates")) else ""
	tooltip_text = "Mana: %d of %d left this %s%s
Spent %d, reserved for running tasks %d.
1 Mana = $0.01. Click (or F4) to set the budget." % [
		int(round(left)), int(round(cap)), J.gs(mana, "period", "day"), est, int(round(spent)), int(round(reserved))]
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		pressed.emit()
		accept_event()


func set_level(value: String) -> void:
	if value == level:
		return
	level = value
	var spec: Dictionary = LEVELS.get(value, LEVELS["normal"])
	if _tween != null:
		_tween.kill()
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var from_fill: float = _mat.get_shader_parameter("fill") if _mat.get_shader_parameter("fill") != null else float(spec["fill"])
	_tween.tween_method(func(v: float) -> void: _mat.set_shader_parameter("fill", v), from_fill, float(spec["fill"]), 0.8)
	_mat.set_shader_parameter("activity", float(spec["activity"]))
	_mat.set_shader_parameter("liquid_top", spec["top"])
	_mat.set_shader_parameter("liquid_deep", spec["deep"])
	_mat.set_shader_parameter("glow", float(spec["glow"]))
	queue_redraw()


func _draw() -> void:
	var x := 38.0 + 10.0
	var c := size.y * 0.5
	var online := level != "offline"
	draw_string(UiFonts.mono(500, 2), Vector2(x, c - 3), "MANA", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UiTokens.HUD_MUTED)
	draw_string(UiFonts.mono(500, 1), Vector2(x, c + 12), caption if caption != "" else level, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
		UiTokens.MINT if online else UiTokens.HUD_SUBTLE)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _orb != null:
		_orb.position = Vector2(0, (size.y - _orb.size.y) * 0.5)
