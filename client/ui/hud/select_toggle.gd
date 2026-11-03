class_name SelectToggle
extends Button
## The Select toggle on phones and tablets: while it is on, the next one-finger drag in the town
## draws a selection box instead of moving the view (RtsInput.drag_selects, which the touch
## controls turn off after one box). It looks like a command-card slot: the select glyph over its
## label, sunk in with a pulsing mint border while on.

const SIZE := 56.0

var _pulse: float = 0.0


func _init() -> void:
	theme_type_variation = "CardButton"
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(SIZE, SIZE)
	tooltip_text = "Select: your next drag draws a box around townsfolk instead of moving the view."


## Follows `input`'s Select toggle both ways.
func bind(input: RtsInput) -> void:
	set_pressed_no_signal(input.drag_selects)
	toggled.connect(input.set_drag_selects)
	input.drag_selects_changed.connect(_on_drag_selects_changed)


func _on_drag_selects_changed(on: bool) -> void:
	set_pressed_no_signal(on)
	queue_redraw()


func _toggled(_on: bool) -> void:
	_pulse = 0.0
	queue_redraw()


func _process(delta: float) -> void:
	if button_pressed:
		_pulse += delta
		queue_redraw()


func _draw() -> void:
	IconDraw.draw(self, "select", Rect2(Vector2(13, 8), Vector2(size.x - 26, size.y - 26)))
	var f := UiFonts.mono(500, 0)
	var label := "Select"
	var col := UiTokens.GOLD_BRIGHT if button_pressed else UiTokens.BTN_TEXT
	draw_string(f, Vector2(1, size.y - 5.0), label, HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, Color(0, 0, 0, 0.7))
	draw_string(f, Vector2(0, size.y - 6.0), label, HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, col)
	if button_pressed:
		var a := 0.65 + 0.35 * sin(_pulse * 4.0)
		draw_rect(Rect2(Vector2(2, 2), size - Vector2(4, 4)), Color(UiTokens.MINT, a), false, 2.0)
