class_name ManaOrb
extends Control
## The Mana orb: an animated globe of liquid (mana_orb.gdshader). Mana is the real-money
## budget (1 Mana = $0.01) owned by the Town Hall; until that connection exists (Phase 3) the
## orb is dim, low and still, and reads "offline". Levels from Realm: "offline", "normal",
## "low" (25% or less), "warning" (10%), "dark" (empty).

const SHADER := preload("res://ui/hud/mana_orb.gdshader")
const LEVELS := {
	"offline": {"fill": 0.32, "activity": 0.0, "top": Color("#6f8f86"), "deep": Color("#1c2c3a"), "glow": 0.0},
	"normal": {"fill": 0.72, "activity": 1.0, "top": Color("#a9f0d0"), "deep": Color("#1a6a78"), "glow": 0.7},
	"low": {"fill": 0.3, "activity": 0.8, "top": Color("#f0c27a"), "deep": Color("#7a4a1a"), "glow": 0.5},
	"warning": {"fill": 0.14, "activity": 0.9, "top": Color("#ff9a78"), "deep": Color("#7a2418"), "glow": 0.6},
	"dark": {"fill": 0.02, "activity": 0.2, "top": Color("#50506a"), "deep": Color("#141422"), "glow": 0.0},
}

var level: String = ""
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
	draw_string(UiFonts.mono(500, 1), Vector2(x, c + 12), level, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
		UiTokens.MINT if online else UiTokens.HUD_SUBTLE)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _orb != null:
		_orb.position = Vector2(0, (size.y - _orb.size.y) * 0.5)
