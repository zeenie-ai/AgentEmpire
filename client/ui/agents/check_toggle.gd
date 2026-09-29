class_name CheckToggle
extends Button
## A check box in the window's look: a small bevelled box with a check mark, then the text.

var look: int = AgentTheme.STATUS


func _init(label_text: String = "", check_look: int = AgentTheme.STATUS) -> void:
	look = check_look
	text = label_text
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	theme_type_variation = "CheckToggle"
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	toggled.connect(func(_on: bool) -> void: queue_redraw())
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)


func _draw() -> void:
	var box := Rect2(Vector2(3, floorf((size.y - 17.0) * 0.5)), Vector2(17, 17))
	var accent := AgentTheme.c(look, "focus")
	var hovered := is_hovered() and not disabled
	draw_rect(box, AgentTheme.c(look, "field"))
	draw_rect(box, Color(accent, 0.9) if hovered or button_pressed else AgentTheme.c(look, "field_border"), false, 1.5)
	if button_pressed:
		draw_rect(box.grow(-3.0), Color(accent, 0.22))
		Glyph.paint(self, "check", box.grow(-3.0), accent if look != AgentTheme.DOCUMENT else UiTokens.BTN, 1.25)
	if disabled:
		draw_rect(box, Color(0, 0, 0, 0.25))
