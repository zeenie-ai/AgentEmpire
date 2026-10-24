extends GutTest
## The placement hint on a touch screen: with no pointer to follow, it sits at the bottom centre
## of the world band, above the Select toggle while that shows, and wraps to stay inside the band.
## On desktop it follows the pointer and never wraps.

const FakeHud = preload("res://tests/fixtures/fake_hud.gd")
const LONG := "Cottage: tap or drag to move it, then tap Build."
## The world band of a 640x360 dp phone while something is selected: the column takes the rest.
const NARROW := Rect2(0, 46, 296, 314)


## A fake HUD whose world band is `band`, with `toggle` as its Select toggle (a hidden one when
## null).
func _hud(band: Rect2, toggle: SelectToggle = null) -> FakeHud:
	var hud: FakeHud = autofree(FakeHud.new())
	hud.band = band
	if toggle == null:
		toggle = autofree(SelectToggle.new())
		toggle.visible = false
	hud.select_toggle = toggle
	return hud


## A touch hint in `hud` showing `text`, once it has settled.
func _hint(hud: FakeHud, text: String) -> CursorHint:
	var hint := CursorHint.new()
	hint.touch = true
	add_child_autofree(hint)
	hint._hud = hud
	hint.set_hint(text, true)
	await wait_process_frames(3)
	return hint


func test_the_touch_hint_sits_at_the_bottom_centre_of_the_world_band() -> void:
	var band := Rect2(0, 40, 914, 300)
	assert_eq(CursorHint.band_position(band, Vector2(300, 40)), Vector2(307, 340 - CursorHint.BAND_MARGIN - 40))


func test_the_touch_hint_follows_the_world_band_not_the_pointer() -> void:
	var hud := _hud(Rect2(0, 40, 914, 300))
	var hint := await _hint(hud, LONG)
	assert_eq(hint.position, CursorHint.band_position(hud.band, hint.size))
	assert_eq(hint._label.autowrap_mode, TextServer.AUTOWRAP_OFF, "a wide band leaves the text on one line")


func test_a_long_hint_wraps_inside_a_narrow_band() -> void:
	var hint := await _hint(_hud(NARROW), LONG)
	assert_gt(hint._label.get_line_count(), 1, "the text wraps")
	assert_lte(hint.size.x, NARROW.size.x - 2.0 * CursorHint.BAND_MARGIN, "no wider than the band allows")
	assert_gte(hint.position.x, NARROW.position.x + CursorHint.BAND_MARGIN, "clear of the band's left edge")
	assert_lte(hint.get_rect().end.x, NARROW.end.x - CursorHint.BAND_MARGIN, "clear of the column")


func test_the_hint_stays_above_the_select_toggle() -> void:
	var toggle: SelectToggle = add_child_autofree(SelectToggle.new())
	toggle.position = Vector2(Hud.PHONE_GAP, NARROW.end.y - Hud.PHONE_GAP - SelectToggle.SIZE)
	var hint := await _hint(_hud(NARROW, toggle), LONG)
	assert_lte(hint.get_rect().end.y, toggle.get_global_rect().position.y - Hud.PHONE_GAP, "above the toggle")
	toggle.visible = false
	await wait_process_frames(2)
	assert_almost_eq(hint.get_rect().end.y, NARROW.end.y - CursorHint.BAND_MARGIN, 1.0, "down to the band's bottom without it")


func test_desktop_hints_follow_the_pointer_unwrapped() -> void:
	var hint := CursorHint.new()
	hint.touch = false
	add_child_autofree(hint)
	hint.set_hint(LONG, true)
	await wait_process_frames(3)
	assert_eq(hint._label.autowrap_mode, TextServer.AUTOWRAP_OFF)
	assert_eq(hint._label.get_line_count(), 1)


func test_the_hint_finds_its_hud() -> void:
	var hud: FakeHud = autofree(FakeHud.new())
	var root := Control.new()
	hud.add_child(root)
	var hint := CursorHint.new()
	root.add_child(hint)
	assert_eq(hint._find_hud(), hud)
