class_name ChoiceCard
extends Button
## A selectable card (harness, role, task size, add-on): a toggle button drawn in the card style
## of its window's look, holding any controls put in `content`. The chosen card glows and wears a
## small check gem; a `locked_on` card stays chosen (required add-ons); a disabled card dims and
## shows why in its tooltip. Tooltips are the rich parchment kind.

var content: VBoxContainer
var look: int = AgentTheme.STATUS
## Stays pressed whatever the player clicks (required add-ons).
var locked_on: bool = false:
	set(value):
		locked_on = value
		if value:
			set_pressed_no_signal(true)
		mouse_default_cursor_shape = Control.CURSOR_ARROW if value or disabled else Control.CURSOR_POINTING_HAND
		if _overlay != null:
			_overlay.queue_redraw()
## Draw the check gem on the chosen card.
var show_check: bool = true

var _margin: MarginContainer
var _overlay: Control
var _tween: Tween


func _init(card_look: int = AgentTheme.STATUS, padding: int = 10) -> void:
	look = card_look
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	theme_type_variation = "CardChoice"
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clip_contents = false
	_margin = MarginContainer.new()
	_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		_margin.add_theme_constant_override("margin_" + side, padding)
	add_child(_margin)
	_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content = VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("separation", 4)
	_margin.add_child(content)
	# The check gem draws above the contents.
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.draw.connect(_draw_gem)
	_margin.minimum_size_changed.connect(_sync_min)
	toggled.connect(_on_toggled)
	resized.connect(func() -> void: pivot_offset = size * 0.5)
	mouse_entered.connect(_on_hover.bind(true))
	mouse_exited.connect(_on_hover.bind(false))


## Adds a control to the card (it ignores the mouse so the card gets the clicks).
func add(c: Control) -> Control:
	_ignore_mouse(c)
	content.add_child(c)
	return c


func _ignore_mouse(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for ch in c.get_children():
		if ch is Control:
			_ignore_mouse(ch as Control)


## Disables the card with a reason (shown in the tooltip), or enables it again.
func set_locked(locked: bool, reason: String = "") -> void:
	disabled = locked
	content.modulate = Color(1, 1, 1, 0.42) if locked else Color.WHITE
	mouse_default_cursor_shape = Control.CURSOR_FORBIDDEN if locked else (Control.CURSOR_ARROW if locked_on else Control.CURSOR_POINTING_HAND)
	if reason != "":
		tooltip_text = reason
	queue_redraw()


func _sync_min() -> void:
	var m := _margin.get_combined_minimum_size()
	custom_minimum_size = Vector2(maxf(custom_minimum_size.x, m.x), m.y)


func _on_toggled(on: bool) -> void:
	if locked_on and not on:
		set_pressed_no_signal(true)
	_overlay.queue_redraw()


## Selects or clears the card without emitting toggled.
func set_chosen(on: bool) -> void:
	set_pressed_no_signal(on or locked_on)
	_overlay.queue_redraw()


func _on_hover(on: bool) -> void:
	if disabled:
		return
	if _tween != null:
		_tween.kill()
	_tween = create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "scale", Vector2.ONE * (1.025 if on else 1.0), 0.14)


func _make_custom_tooltip(for_text: String) -> Object:
	if for_text == "":
		return null
	return CraftedTooltip.make(for_text)


func _draw_gem() -> void:
	if not (button_pressed and show_check):
		return
	var col := AgentTheme.c(look, "card_sel_trim")
	var ctr := Vector2(_overlay.size.x - 12.0, 12.0)
	var r := 8.0
	_overlay.draw_colored_polygon(PackedVector2Array([ctr + Vector2(0, -r - 1.5), ctr + Vector2(r + 1.5, 0), ctr + Vector2(0, r + 1.5), ctr + Vector2(-r - 1.5, 0)]),
		Color(0, 0, 0, 0.45))
	_overlay.draw_polygon(PackedVector2Array([ctr + Vector2(0, -r), ctr + Vector2(r, 0), ctr + Vector2(0, r), ctr + Vector2(-r, 0)]),
		PackedColorArray([col.lightened(0.4), col, col.darkened(0.3), col.lightened(0.1)]))
	var ink := Color("#10131f") if look != AgentTheme.DOCUMENT else Color("#fff6e2")
	if locked_on:
		Glyph.paint(_overlay, "lock", Rect2(ctr - Vector2(4.5, 4.5), Vector2(9, 9)), ink)
	else:
		Glyph.paint(_overlay, "check", Rect2(ctr - Vector2(4.5, 4.5), Vector2(9, 9)), ink, 1.2)
