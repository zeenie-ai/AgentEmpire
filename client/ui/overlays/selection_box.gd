class_name SelectionBoxOverlay
extends Control
## The drag-selection rectangle.

var box: Rect2 = Rect2()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_box(r: Rect2) -> void:
	box = r
	queue_redraw()


func _draw() -> void:
	if box.size.x < 1.0 and box.size.y < 1.0:
		return
	draw_rect(box, Color(UiTokens.MINT, 0.12))
	draw_rect(box, UiTokens.MINT, false, 1.5)
