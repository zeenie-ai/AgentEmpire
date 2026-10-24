extends GutTest
## The HUD's layouts, each built in a SubViewport of the logical size it is checked at (on phones
## and tablets one logical pixel is one dp): the desktop's world band, which must not change; the
## compact phone layout down to the smallest phones, with every part on screen and every tap
## target at least 48 dp; and the camera landing inside the phone's world band.


func _hud_at(size: Vector2i) -> Hud:
	var sv := SubViewport.new()
	sv.size = size
	add_child_autofree(sv)
	var hud := Hud.new()
	sv.add_child(hud)
	await wait_process_frames(3)
	return hud


func _phone_at(size: Vector2i) -> Hud:
	var hud: Hud = await _hud_at(size)
	hud.use_layout(Hud.Layout.PHONE, false)
	await wait_process_frames(3)
	return hud


## Visible controls under `hud.safe` that leave the viewport, as "name rect" lines.
func _off_screen(hud: Hud) -> PackedStringArray:
	var screen := hud.get_viewport().get_visible_rect().grow(0.5)
	var out := PackedStringArray()
	for c in _controls(hud.safe):
		var r := c.get_global_rect()
		if r.size != Vector2.ZERO and not screen.encloses(r):
			out.append("%s %s" % [c.name, r])
	return out


## Visible buttons under `hud.safe` smaller than a touch target, as "name size" lines.
func _small_targets(hud: Hud) -> PackedStringArray:
	var out := PackedStringArray()
	for c in _controls(hud.safe):
		if c is BaseButton and (c.size.x < Platform.TOUCH_TARGET_DP or c.size.y < Platform.TOUCH_TARGET_DP):
			out.append("%s %s" % [c.get_path(), c.size])
	return out


func _controls(under: Node) -> Array[Control]:
	var out: Array[Control] = []
	for n in under.get_children():
		var c := n as Control
		if c == null or not c.is_visible_in_tree():
			continue
		out.append(c)
		out.append_array(_controls(c))
	return out


func test_desktop_world_band_is_unchanged() -> void:
	var hud: Hud = await _hud_at(Vector2i(1600, 900))
	assert_eq(hud.layout, Hud.Layout.DESKTOP)
	assert_eq(hud.world_rect(), Rect2(0, 46, 1600, 628), "between the top bar and the bottom panel")


func test_phone_layout_at_914x411() -> void:
	var hud: Hud = await _phone_at(Vector2i(914, 411))
	assert_eq(hud.top_bar.size.y, float(TopBar.TOUCH_HEIGHT), "the bar is one touch target tall")
	assert_false(hud.bottom.visible, "no bottom panel")
	assert_true(hud.column.visible)
	assert_eq(hud.bottom.card_frame.get_parent(), hud.column, "the command card moved to the column")
	var col := hud.column.get_global_rect()
	assert_eq(col.end, Vector2(914 - Hud.PHONE_GAP, 411 - Hud.PHONE_GAP), "the column sits at the bottom right")
	assert_eq(col.size, Vector2(336, 192), "5x3 slots of 60x56 in their frame")
	assert_eq(hud.world_rect(), Rect2(0, TopBar.TOUCH_HEIGHT, col.position.x, 411 - TopBar.TOUCH_HEIGHT),
		"the world band: below the bar, left of the column, down to the bottom")
	for part: Control in [hud.top_bar._hall, hud.top_bar._mana, hud.top_bar._age, hud.top_bar._mark, hud.approval_tray]:
		assert_false(part.is_visible_in_tree(), "%s is hidden" % part.name)
	for part: Control in [hud.top_bar._map_button, hud.top_bar._menu_button, hud.top_bar._idle_button]:
		assert_true(part.is_visible_in_tree())
	assert_eq(_off_screen(hud), PackedStringArray(), "everything is on screen")
	assert_eq(_small_targets(hud), PackedStringArray(), "every tap target is at least 48 dp")
	hud.fps_label.visible = true
	hud.fps_label.text = "60 FPS"
	await wait_process_frames(1)
	assert_true(hud.world_rect().encloses(hud.fps_label.get_global_rect()), "the FPS readout is in the world band")


func test_phone_layout_follows_a_resize() -> void:
	var hud: Hud = await _phone_at(Vector2i(914, 411))
	(hud.get_parent() as SubViewport).size = Vector2i(731, 411)
	await wait_process_frames(3)
	var left := hud.column.get_global_rect().position.x
	assert_eq(hud.column.get_global_rect().end, Vector2(731 - Hud.PHONE_GAP, 411 - Hud.PHONE_GAP))
	assert_eq(hud.world_rect().end.x, left, "the band ends at the column")
	assert_eq(hud.toasts.get_global_rect().end.x, left, "toasts are centred over the band")


func test_phone_layout_fits_the_smallest_phones() -> void:
	for size: Vector2i in [Vector2i(731, 411), Vector2i(640, 360)]:
		var hud: Hud = await _phone_at(size)
		var bar := hud.top_bar
		# A late town: five-digit stores, a full population and a dozen idle.
		for res: String in bar._chips:
			(bar._values[res] as Label).text = "12500"
		bar._pop_label.text = "100/100"
		bar._idle_label.text = "Idle 12"
		assert_true(bar.get_combined_minimum_size().x <= float(size.x), "the bar fits %s: %s" % [size, bar.get_combined_minimum_size()])
		await wait_process_frames(2)
		assert_eq(_off_screen(hud), PackedStringArray(), "everything is on screen at %s" % size)
		assert_eq(_small_targets(hud), PackedStringArray(), "tap targets at %s" % size)
		var band := hud.world_rect()
		assert_true(band.size.x > 64.0 and band.size.y > 64.0, "a world band at %s: %s" % [size, band])


func test_toasts_stay_in_the_phone_world_band() -> void:
	var hud: Hud = await _phone_at(Vector2i(640, 360))
	for i in 5:
		hud.toasts.show_toast("Need houses: build a Cottage to raise the population cap.", "warn")
	await wait_process_frames(3)
	var band := hud.world_rect()
	var shown := 0
	for t in hud.toasts.get_children():
		if not t.is_queued_for_deletion() and t in hud.toasts._toasts:
			shown += 1
			var r := (t as Control).get_global_rect()
			assert_true(r.position.x >= band.position.x and r.end.x <= band.end.x, "toast inside the band: %s in %s" % [r, band])
			assert_true(r.position.y >= hud.top_bar.get_global_rect().end.y, "toast under the bar")
	assert_eq(shown, 3, "at most three toasts on a phone")


func test_focus_and_frame_land_in_the_phone_world_band() -> void:
	var hud: Hud = await _phone_at(Vector2i(914, 411))
	var cam := RtsCamera.new()
	cam.input_enabled = false
	hud.get_parent().add_child(cam)
	cam.safe_rect_provider = hud.world_rect
	await wait_process_frames(1)
	var band := hud.world_rect()
	var target := Vector3(64, 0, 64)
	cam.focus(target, true)
	var at: Variant = cam.project(cam.camera.global_transform, target)
	assert_true(at is Vector2 and band.has_point(at), "focus lands in the band: %s in %s" % [at, band])
	assert_almost_eq(at as Vector2, band.get_center(), Vector2(1, 1), "in its middle")
	var points := PackedVector3Array([Vector3(56, 0, 58), Vector3(73, 0, 64), Vector3(64, 3, 72), Vector3(60, 0, 70)])
	cam.frame(points)
	for p in points:
		var s: Variant = cam.project(cam.camera.global_transform, p)
		assert_true(s is Vector2 and band.has_point(s), "frame keeps %s in the band: %s" % [p, s])
