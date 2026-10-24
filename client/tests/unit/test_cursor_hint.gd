extends GutTest
## The placement hint on a touch screen: with no pointer to follow, it sits at the bottom centre
## of the world band.

const FakeHud = preload("res://tests/fixtures/fake_hud.gd")


func test_the_touch_hint_sits_at_the_bottom_centre_of_the_world_band() -> void:
	var band := Rect2(0, 40, 914, 300)
	assert_eq(CursorHint.band_position(band, Vector2(300, 40)), Vector2(307, 340 - CursorHint.BAND_MARGIN - 40))


func test_the_touch_hint_follows_the_world_band_not_the_pointer() -> void:
	var hud: FakeHud = autofree(FakeHud.new())
	hud.band = Rect2(0, 40, 914, 300)
	var hint := CursorHint.new()
	hint.touch = true
	add_child_autofree(hint)
	hint._hud = hud
	hint.set_hint("Cottage: drag the outline, then tap Build.", true)
	await wait_process_frames(2)
	assert_eq(hint.position, CursorHint.band_position(hud.band, hint.size))


func test_the_hint_finds_its_hud() -> void:
	var hud: FakeHud = autofree(FakeHud.new())
	var root := Control.new()
	hud.add_child(root)
	var hint := CursorHint.new()
	root.add_child(hint)
	assert_eq(hint._find_hud(), hud)
