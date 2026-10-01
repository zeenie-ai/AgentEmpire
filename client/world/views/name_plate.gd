class_name NamePlate
extends PanelContainer
## An agent home's name plate, drawn in screen space over the town (a layer under the HUD): the
## agent's name in Cinzel above a caption in small mono capitals (role and rank, or what needs
## the player), on a dark wood backdrop with a thin bronze edge, so it reads on grass, roofs and
## at night alike.
##
## HomeStatusView places it each frame above the home's roof. Its size follows the zoom: scale 1
## when the home is about HOME_PX wide on screen, clamped to MIN_SCALE..MAX_SCALE, so it stays
## readable far out and never grows much wider than the home up close. Font sizes are whole
## pixels at every scale step (crisp text); below CAPTION_MIN_SCALE only the name shows.

const NAME_SIZE := 15.0
const CAPTION_SIZE := 9.5
const MIN_SCALE := 0.78
const MAX_SCALE := 1.5
const HOME_PX := 120.0
const CAPTION_MIN_SCALE := 0.9
## Space between the plate's bottom and the point it labels.
const LIFT_PX := 6.0
const BACKDROP := Color(0.075, 0.052, 0.035, 0.8)
const EDGE := Color(0.42, 0.32, 0.19, 0.95)

var _name: Label
var _caption: Label
var _style: StyleBoxFlat
var _step: int = -1
var _text_key: String = ""


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_style = StyleBoxFlat.new()
	_style.bg_color = BACKDROP
	_style.border_color = EDGE
	_style.set_border_width_all(1)
	_style.set_corner_radius_all(3)
	_style.shadow_color = Color(0, 0, 0, 0.28)
	_style.shadow_size = 3
	_style.shadow_offset = Vector2(0, 1)
	add_theme_stylebox_override("panel", _style)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 0)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(box)
	_name = _label(UiFonts.cinzel(700, 1))
	box.add_child(_name)
	_caption = _label(UiFonts.mono(600, 2))
	box.add_child(_caption)
	_apply_scale(1.0)


func _label(font: Font) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", font)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l


## The name (tinted by what the agent is doing) and the caption line under it.
func set_text(agent_name: String, caption: String, name_color: Color, caption_color: Color) -> void:
	var key := "%s|%s|%s|%s" % [agent_name, caption, name_color.to_html(), caption_color.to_html()]
	if key == _text_key:
		return
	_text_key = key
	_name.text = agent_name
	_caption.text = caption
	_name.add_theme_color_override("font_color", name_color)
	_caption.add_theme_color_override("font_color", caption_color)
	_style.border_color = EDGE if caption_color == UiTokens.HUD_SUBTLE else Color(caption_color, 0.75)
	reset_size()


## Puts the plate's bottom centre just above screen point `at`, sized for a home that spans
## `home_px` pixels on screen.
func place(at: Vector2, home_px: float) -> void:
	_apply_scale(clampf(home_px / HOME_PX, MIN_SCALE, MAX_SCALE))
	position = (at - Vector2(size.x * 0.5, size.y + LIFT_PX)).round()


func _apply_scale(s: float) -> void:
	var step := int(round(s * 16.0))
	if step == _step:
		return
	_step = step
	var k := float(step) / 16.0
	_name.add_theme_font_size_override("font_size", maxi(int(round(NAME_SIZE * k)), 9))
	_caption.add_theme_font_size_override("font_size", maxi(int(round(CAPTION_SIZE * k)), 7))
	_caption.visible = k >= CAPTION_MIN_SCALE
	_style.content_margin_left = round(9.0 * k)
	_style.content_margin_right = round(9.0 * k)
	_style.content_margin_top = round(2.0 * k)
	_style.content_margin_bottom = round(3.0 * k)
	reset_size()
