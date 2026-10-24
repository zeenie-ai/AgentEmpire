class_name CursorHint
extends PanelContainer
## A status window that follows the cursor during placement and rally modes; it names the
## reason when a spot is invalid. On a touch screen there is no cursor to follow, so it sits at
## the bottom centre of the world band (Hud.world_rect()).

const OFFSET := Vector2(22, 24)
## Touch: the space between the hint and the bottom of the world band.
const BAND_MARGIN := 12.0

## Phones and tablets: touch rather than a mouse (tests set it before the hint enters the tree).
var touch: bool = Platform.is_mobile()

var _label: Label
## Touch: the HUD the hint belongs to, for its world band.
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
		position = band_position(_hud.world_rect(), size)
		return
	var vp := get_viewport().get_visible_rect().size
	var p := get_viewport().get_mouse_position() + OFFSET
	p.x = minf(p.x, vp.x - size.x - 4.0)
	p.y = minf(p.y, vp.y - size.y - 4.0)
	position = p


## Touch: the top-left corner of a `hint_size` hint centred at the bottom of the world band.
static func band_position(band: Rect2, hint_size: Vector2) -> Vector2:
	return Vector2(band.get_center().x - hint_size.x * 0.5, band.end.y - BAND_MARGIN - hint_size.y).floor()


## The HUD this hint is part of (Hud puts it in its root control).
func _find_hud() -> Hud:
	var n := get_parent()
	while n != null and not (n is Hud):
		n = n.get_parent()
	return n as Hud
