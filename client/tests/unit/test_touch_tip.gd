extends GutTest
## Touch tips: a control's tooltip beside it until the next touch or Back, and a long press on a
## card showing its tip instead of activating the slot.


func after_each() -> void:
	TouchTip.dismiss()


func _control(tip: String) -> Button:
	var b: Button = add_child_autofree(Button.new())
	b.position = Vector2(200, 600)
	b.size = Vector2(96, 38)
	b.tooltip_text = tip
	return b


func _tip_content() -> Control:
	return TouchTip._layer.get_child(0).get_child(0) as Control


## Events are given in viewport coordinates (the test window is stretched).
func _touch(pressed: bool, at: Vector2) -> void:
	var t := InputEventScreenTouch.new()
	t.pressed = pressed
	t.position = at
	get_viewport().push_input(t, true)


# --- TouchTip --------------------------------------------------------------------------------------

func test_a_tip_shows_the_tooltip_until_dismissed() -> void:
	var b := _control("Wood: 120\nIncome: +30 per minute")
	TouchTip.show_for(b)
	assert_true(TouchTip.showing())
	var panel := TouchTip._layer.get_child(0) as PanelContainer
	assert_eq(panel.theme_type_variation, &"TooltipPanel")
	assert_eq((_tip_content() as Label).text, b.tooltip_text)
	assert_true(TouchTip.dismiss())
	assert_false(TouchTip.showing())
	assert_false(TouchTip.dismiss(), "nothing left to dismiss")


func test_a_control_without_a_tooltip_shows_nothing() -> void:
	TouchTip.show_for(_control(""))
	assert_false(TouchTip.showing())


func test_the_next_touch_anywhere_hides_the_tip() -> void:
	var b := _control("Stone: 40")
	TouchTip.show_for(b)
	_touch(false, b.get_global_rect().get_center())
	assert_true(TouchTip.showing(), "lifting the finger that asked for it does not")
	_touch(true, Vector2(900, 300))
	_touch(false, Vector2(900, 300))
	assert_false(TouchTip.showing())


func test_a_tip_sits_beside_its_control_inside_the_screen() -> void:
	var view := Vector2(914, 411)
	var tip := Vector2(220, 64)
	# A card at the bottom right: the tip goes above it, inside the right edge.
	var card := Rect2(840, 345, 60, 56)
	var p := TouchTip.place(card, tip, view)
	assert_eq(p.y, card.position.y - TouchTip.GAP - tip.y)
	assert_eq(p.x, view.x - TouchTip.MARGIN - tip.x)
	# A chip in the top bar: below it, inside the left edge.
	var chip := Rect2(10, 4, 96, 38)
	p = TouchTip.place(chip, tip, view)
	assert_eq(p.y, chip.end.y + TouchTip.GAP)
	assert_eq(p.x, TouchTip.MARGIN)


func test_a_shown_tip_is_placed_by_its_control() -> void:
	var b := _control("Gold: 60")
	TouchTip.show_for(b)
	var panel := TouchTip._layer.get_child(0) as PanelContainer
	assert_eq(panel.position, TouchTip.place(b.get_global_rect(), panel.size, b.get_viewport_rect().size))


# --- card buttons ------------------------------------------------------------------------------------

## A touch-screen card with a slot. Its index has no hotkey, as on a phone (and headless runs
## cannot name keys).
func _card() -> CardButton:
	var b := CardButton.new(InputActions.CARD_SLOTS)
	b.touch = true
	b.set_slot({"id": "stop", "icon": "stop", "label": "Stop", "tooltip": "Stop\nThe selected townsfolk stop what they are doing."})
	add_child_autofree(b)
	b.position = Vector2(300, 600)
	return b


## The emulated mouse of a finger on `b` (headless runs have no pointer, so `b` is told it is
## under it first).
func _press(b: Control, down: bool) -> void:
	if down:
		b.notification(Control.NOTIFICATION_MOUSE_ENTER)
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = down
	e.position = b.get_global_rect().get_center()
	e.global_position = e.position
	get_viewport().push_input(e, true)


func test_a_long_press_shows_the_tip_and_does_not_activate_the_slot() -> void:
	var b := _card()
	var presses := [0]
	b.pressed.connect(func() -> void: presses[0] += 1)
	await wait_process_frames(1)
	_press(b, true)
	assert_eq(b.get_draw_mode(), BaseButton.DRAW_PRESSED)
	await wait_seconds(Platform.LONG_PRESS_MS / 1000.0 + 0.15)
	assert_true(TouchTip.showing(), "held long enough: the tip")
	assert_true(_tip_content() is CraftedTooltip, "the card's own rich tooltip")
	_press(b, false)
	assert_eq(presses[0], 0, "letting go does not activate the slot")
	assert_true(TouchTip.showing(), "and the tip stays")


func test_a_tap_still_activates_the_slot() -> void:
	var b := _card()
	var presses := [0]
	b.pressed.connect(func() -> void: presses[0] += 1)
	await wait_process_frames(1)
	_press(b, true)
	_press(b, false)
	assert_eq(presses[0], 1)
	await wait_seconds(Platform.LONG_PRESS_MS / 1000.0 + 0.15)
	assert_false(TouchTip.showing(), "no tip after a tap")


func test_touch_cards_do_not_lift_on_hover() -> void:
	var b := _card()
	var desk := CardButton.new(InputActions.CARD_SLOTS)
	desk.touch = false
	desk.set_slot(b.slot)
	add_child_autofree(desk)
	await wait_process_frames(1)
	b.mouse_entered.emit()
	desk.mouse_entered.emit()
	await wait_seconds(0.3)
	assert_eq(b.scale, Vector2.ONE, "touch: no lift")
	assert_almost_eq(desk.scale.x, CardButton.HOVER_SCALE, 0.01, "the mouse still lifts it")
