class_name CursorHint
extends PanelContainer
## A status window that follows the cursor during placement and rally modes; it names the
## reason when a spot is invalid. On a touch screen there is no cursor to follow, so it sits at
## the bottom centre of the world band (Hud.world_rect()), above the Select toggle while that
## shows, and wraps its text to stay inside the band.

const OFFSET := Vector2(22, 24)
## Touch: the space the hint keeps from the bottom and the sides of the world band.
const BAND_MARGIN := 12.0

## Phones and tablets: touch rather than a mouse (tests set it before the hint enters the tree).
var touch: bool = Platform.is_mobile()

var _label: Label
## Touch: the HUD the hint belongs to, for its world band and the Select toggle.
var _hud: Hud


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme_type_variation = "StatusPanel"
	_label = Label.new()
	_label.theme_type_variation = "StatusLabel"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	visible = false
	if touch:
		_hud = _find_hud()


func set_hint(text: String, ok: bool) -> void:
	visible = text != ""
	_label.text = text
	add_theme_stylebox_override("panel", ThemeBuilder.status_box(UiTokens.MINT if ok else UiTokens.BAD))
	_label.add_theme_color_override("font_color", Color("#eef6ff") if ok else UiTokens.BAD.lightened(0.35))
	reset_size()


func _process(_delta: float) -> void:
	if not visible:
		return
	if touch:
		var band := touch_band()
		_wrap_to(band.size.x - 2.0 * BAND_MARGIN)
		position = band_position(band, size)
		return
	var vp := get_viewport().get_visible_rect().size
	var p := get_viewport().get_mouse_position() + OFFSET
	p.x = minf(p.x, vp.x - size.x - 4.0)
	p.y = minf(p.y, vp.y - size.y - 4.0)
	position = p


## Touch: the part of the world band the hint sits in, which ends PHONE_GAP above the Select
## toggle while the toggle shows.
func touch_band() -> Rect2:
	var band := _hud.world_rect()
	if _hud.select_toggle.is_visible_in_tree():
		band.size.y = _hud.select_toggle.get_global_rect().position.y - Hud.PHONE_GAP - band.position.y
	return band


## Touch: the top-left corner of a `hint_size` hint centred at the bottom of the world band.
static func band_position(band: Rect2, hint_size: Vector2) -> Vector2:
	return Vector2(band.get_center().x - hint_size.x * 0.5, band.end.y - BAND_MARGIN - hint_size.y).floor()


## Touch: wraps the text when the hint would be wider than `width`; a shorter text keeps its own
## width.
func _wrap_to(width: float) -> void:
	var sb := get_theme_stylebox("panel")
	var room := width - sb.get_margin(SIDE_LEFT) - sb.get_margin(SIDE_RIGHT)
	var text_width := _label.get_theme_font("font").get_string_size(_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		_label.get_theme_font_size("font_size")).x
	var wrap_width := room if text_width > room else 0.0
	if _label.custom_minimum_size.x == wrap_width:
		return
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap_width > 0.0 else TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size.x = wrap_width
	reset_size()


## The HUD this hint is part of (Hud puts it in its root control).
func _find_hud() -> Hud:
	var n := get_parent()
	while n != null and not (n is Hud):
		n = n.get_parent()
	return n as Hud
