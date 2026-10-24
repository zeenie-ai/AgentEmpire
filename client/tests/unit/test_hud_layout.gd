extends GutTest
## The HUD's layouts, each built in a SubViewport of the logical size it is checked at (on phones
## and tablets one logical pixel is one dp): the desktop's world band, which must not change.


func _hud_at(size: Vector2i) -> Hud:
	var sv := SubViewport.new()
	sv.size = size
	add_child_autofree(sv)
	var hud := Hud.new()
	sv.add_child(hud)
	await wait_process_frames(3)
	return hud


func test_desktop_world_band_is_unchanged() -> void:
	var hud: Hud = await _hud_at(Vector2i(1600, 900))
	assert_eq(hud.world_rect(), Rect2(0, 46, 1600, 628), "between the top bar and the bottom panel")
