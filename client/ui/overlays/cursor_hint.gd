class_name CursorHint
extends PanelContainer
## A status window that follows the cursor during placement and rally modes; it names the
## reason when a spot is invalid.

const OFFSET := Vector2(22, 24)

var _label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme_type_variation = "StatusPanel"
	_label = Label.new()
	_label.theme_type_variation = "StatusLabel"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	visible = false


func set_hint(text: String, ok: bool) -> void:
	visible = text != ""
	_label.text = text
	add_theme_stylebox_override("panel", ThemeBuilder.status_box(UiTokens.MINT if ok else UiTokens.BAD))
	_label.add_theme_color_override("font_color", Color("#eef6ff") if ok else UiTokens.BAD.lightened(0.35))
	reset_size()


func _process(_delta: float) -> void:
	if not visible:
		return
	var vp := get_viewport().get_visible_rect().size
	var p := get_viewport().get_mouse_position() + OFFSET
	p.x = minf(p.x, vp.x - size.x - 4.0)
	p.y = minf(p.y, vp.y - size.y - 4.0)
	position = p
