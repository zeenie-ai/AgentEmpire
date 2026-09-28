class_name IconView
extends Control
## A Control that paints one IconDraw icon.

var icon: String = "":
	set(value):
		icon = value
		queue_redraw()
var dim: bool = false:
	set(value):
		dim = value
		queue_redraw()


func _init(icon_name: String = "", size_px: float = 20.0) -> void:
	icon = icon_name
	custom_minimum_size = Vector2(size_px, size_px)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	if icon != "":
		IconDraw.draw(self, icon, Rect2(Vector2.ZERO, size), dim)
