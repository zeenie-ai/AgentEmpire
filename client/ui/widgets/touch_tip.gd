class_name TouchTip
extends RefCounted
## Tooltips on a touch screen, where nothing hovers: shows a control's tooltip beside it until the
## next touch anywhere or Back. The tip is what the engine would show on hover, on the parchment
## TooltipPanel: the control's own tooltip (_make_custom_tooltip: a card button's CraftedTooltip),
## or else its tooltip_text. It sits above the control in the lower half of the screen and below
## it in the upper half, inside the screen. It never takes a touch: the touch that hides it still
## reaches what is under the finger.

## The space between the control and its tip, and between a tip and the screen's edges.
const GAP := 8.0
const MARGIN := 8.0
## Over the HUD (layer 10) and its windows.
const LAYER := 100

static var _layer: CanvasLayer


## Shows `control`'s tooltip beside it, in place of a tip already showing.
static func show_for(control: Control) -> void:
	dismiss()
	var text := control.tooltip_text
	if text == "":
		return
	var content: Control = null
	if control.has_method("_make_custom_tooltip"):
		content = control.call("_make_custom_tooltip", text) as Control
	if content == null:
		var label := Label.new()
		label.theme_type_variation = "TooltipLabel"
		label.text = text
		content = label
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := PanelContainer.new()
	panel.theme = ThemeBuilder.theme()
	panel.theme_type_variation = "TooltipPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(content)
	_layer = Tip.new()
	_layer.layer = LAYER
	_layer.add_child(panel)
	control.get_viewport().add_child(_layer)
	var target := control.get_global_rect()
	var view := control.get_viewport_rect().size
	# Wrapped text settles its height after the first layout: keep the tip in place as it does.
	var put := func() -> void: panel.position = place(target, panel.size, view)
	panel.resized.connect(put)
	panel.reset_size()
	put.call()


## Hides the tip if one is showing. True when it did (the first step of the Back chain).
static func dismiss() -> bool:
	if not is_instance_valid(_layer):
		return false
	_layer.queue_free()
	_layer = null
	return true


## True while a tip is showing.
static func showing() -> bool:
	return is_instance_valid(_layer)


## The top-left corner of a `tip_size` tip beside `target`, on a screen of size `view`.
static func place(target: Rect2, tip_size: Vector2, view: Vector2) -> Vector2:
	var y := target.end.y + GAP if target.get_center().y < view.y * 0.5 else target.position.y - GAP - tip_size.y
	var x := target.get_center().x - tip_size.x * 0.5
	return Vector2(clampf(x, MARGIN, view.x - tip_size.x - MARGIN), clampf(y, MARGIN, view.y - tip_size.y - MARGIN)).floor()


## The tip's layer: the next touch anywhere hides it.
class Tip:
	extends CanvasLayer

	func _input(event: InputEvent) -> void:
		var touch := event as InputEventScreenTouch
		if touch != null and touch.pressed:
			TouchTip.dismiss()
