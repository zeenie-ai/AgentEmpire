extends GutTest
## The HUD's layouts, each built in a SubViewport of the logical size it is checked at (on phones
## and tablets one logical pixel is one dp): the desktop's world band, which must not change; the
## compact phone layout down to the smallest phones, with every part on screen and every tap
## target at least 48 dp; the phone's compact selection details, minimap overlay, Select toggle
## and toasts; and the camera landing inside the phone's world band.

var _paused: bool = false


func before_each() -> void:
	_paused = Game.paused


func after_each() -> void:
	Game.stop_town()
	Game.paused = _paused
	await wait_process_frames(2)


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


## Connects the HUD to a bare RtsInput and its selection, as GameMain does; returns the input (its
## selection is input.selection). The command card stays empty: its slots label their hotkeys
## through the display server, which a headless run does not have, and the slots are not what
## these tests look at.
func _connect(hud: Hud) -> RtsInput:
	var input := RtsInput.new()
	autofree(input)
	input.selection = Selection.new()
	hud.setup(null, null, input.selection, input)
	hud.bottom.command_card.selection = null
	return input


## A paused demo town with finished buildings, bound to `hud`.
func _town(hud: Hud) -> SimWorld:
	Game.paused = true
	var w: SimWorld = Game.new_town(4127, "hud-test")
	DemoTown.build(w, 4, 70.0)
	hud.bind_world(w)
	return w


func _first(w: SimWorld, kind: String) -> int:
	for u: SimUnit in w.units.values():
		if u.kind == kind:
			return u.id
	return -1


func _building(w: SimWorld, type: String, complete: bool) -> int:
	for b: SimBuilding in w.buildings.values():
		if b.type == type and b.complete == complete:
			return b.id
	return -1


## Visible controls under `hud.safe` that leave the viewport, as "name rect" lines.
func _off_screen(hud: Hud) -> PackedStringArray:
	var screen := hud.get_viewport().get_visible_rect().grow(0.5)
	var out := PackedStringArray()
	for c in _controls(hud.safe):
		var r := c.get_global_rect()
		if r.size != Vector2.ZERO and not screen.encloses(r):
			out.append("%s %s" % [c.name, r])
	return out


## Visible buttons under `under` smaller than a touch target, as "name size" lines.
func _small_targets(under: Control) -> PackedStringArray:
	var out := PackedStringArray()
	for c in _controls(under):
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
	var sel := _connect(hud).selection
	var w := _town(hud)
	sel.set_ids([w.keep_id])
	await wait_process_frames(3)
	assert_eq(hud.top_bar.size.y, float(TopBar.TOUCH_HEIGHT), "the bar is one touch target tall")
	assert_false(hud.bottom.visible, "no bottom panel")
	assert_eq(hud.bottom.card_frame.get_parent(), hud.column, "the command card moved to the column")
	assert_eq(hud.bottom.selection_panel.get_parent(), hud.column, "and the selection details above it")
	var col := hud.column.get_global_rect()
	assert_eq(col.end, Vector2(914 - Hud.PHONE_GAP, 411 - Hud.PHONE_GAP), "the column sits at the bottom right")
	assert_eq(col.size, Vector2(336, 96 + Hud.PHONE_GAP + 192), "the details (96) over 5x3 slots of 60x56")
	assert_eq(hud.world_rect(), Rect2(0, TopBar.TOUCH_HEIGHT, col.position.x, 411 - TopBar.TOUCH_HEIGHT),
		"the world band: below the bar, left of the column, down to the bottom")
	for part: Control in [hud.top_bar._hall, hud.top_bar._mana, hud.top_bar._age, hud.top_bar._mark, hud.approval_tray]:
		assert_false(part.is_visible_in_tree(), "%s is hidden" % part.name)
	for part: Control in [hud.top_bar._map_button, hud.top_bar._menu_button, hud.top_bar._idle_button, hud.select_toggle]:
		assert_true(part.is_visible_in_tree())
	assert_eq(_off_screen(hud), PackedStringArray(), "everything is on screen")
	assert_eq(_small_targets(hud.safe), PackedStringArray(), "every tap target is at least 48 dp")
	hud.fps_label.visible = true
	hud.fps_label.text = "60 FPS"
	await wait_process_frames(1)
	assert_true(hud.world_rect().encloses(hud.fps_label.get_global_rect()), "the FPS readout is in the world band")


func test_phone_column_shows_only_with_a_selection() -> void:
	var hud: Hud = await _phone_at(Vector2i(914, 411))
	var sel := _connect(hud).selection
	var w := _town(hud)
	await wait_process_frames(2)
	var band := hud.world_rect()
	assert_false(hud.bottom.card_frame.is_visible_in_tree(), "no command card with nothing selected")
	assert_false(hud.bottom.selection_panel.is_visible_in_tree())
	sel.set_ids([_first(w, "townsfolk")])
	await wait_process_frames(2)
	assert_true(hud.bottom.card_frame.is_visible_in_tree(), "a selection shows the card")
	assert_true(hud.bottom.selection_panel.is_visible_in_tree(), "and the details")
	assert_eq(hud.world_rect(), band, "the world band stays put")
	sel.clear()
	await wait_process_frames(2)
	assert_false(hud.bottom.card_frame.is_visible_in_tree())
	assert_eq(hud.world_rect(), band)


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
		var sel := _connect(hud).selection
		var w := _town(hud)
		sel.set_ids([w.keep_id])
		var bar := hud.top_bar
		# A late town: five-digit stores, a full population and a dozen idle.
		for res: String in bar._chips:
			(bar._values[res] as Label).text = "12500"
		bar._pop_label.text = "100/100"
		bar._idle_label.text = "12"
		assert_true(bar.get_combined_minimum_size().x <= float(size.x), "the bar fits %s: %s" % [size, bar.get_combined_minimum_size()])
		await wait_process_frames(3)
		assert_eq(_off_screen(hud), PackedStringArray(), "everything is on screen at %s" % size)
		assert_eq(_small_targets(hud.safe), PackedStringArray(), "tap targets at %s" % size)
		assert_true(hud.column.get_global_rect().position.y >= bar.get_global_rect().end.y, "the column clears the bar at %s" % size)
		var band := hud.world_rect()
		assert_true(band.size.x > 64.0 and band.size.y > 64.0, "a world band at %s: %s" % [size, band])
		Game.stop_town()


func test_compact_idle_shows_the_count() -> void:
	var hud: Hud = await _phone_at(Vector2i(914, 411))
	_town(hud)
	hud.top_bar._refresh()
	assert_eq(hud.top_bar._idle_button.size.x, float(TopBar.COMPACT_IDLE))
	assert_true(hud.top_bar._idle_label.text.is_valid_int(), "just the count: %s" % hud.top_bar._idle_label.text)


func test_compact_selection_details_fit() -> void:
	var hud: Hud = await _phone_at(Vector2i(640, 360))
	var sel := _connect(hud).selection
	var w := _town(hud)
	var folk: Array[int] = []
	for u: SimUnit in w.units.values():
		if u.kind == "townsfolk":
			folk.append(u.id)
	var tree := w.find_nearest_node(w.keep().center(), ["tree"], 40.0)
	var spot := DemoTown.find_spot(w, "cottage", Vector2i(w.keep().center()) + Vector2i(0, -9), 8)
	w.commands.push(GameCommands.place_building([folk[0]], "cottage", spot))
	w.step(1)
	var views := {
		"the Keep": [w.keep_id],
		"a townsperson": [folk[0]],
		"a group": folk,
		"a tree": [tree.id],
		"a cottage": [_building(w, "cottage", true)],
		"a site": [_building(w, "cottage", false)],
	}
	var panel := hud.bottom.selection_panel
	for view: String in views:
		sel.set_ids(views[view])
		await wait_process_frames(3)
		var box := panel.get_global_rect()
		assert_eq(box.size, Vector2(336, SelectionPanel.COMPACT_HEIGHT), "%s keeps the panel's size" % view)
		var outside := PackedStringArray()
		var x_buttons := 0
		for c in _controls(panel):
			if c.size != Vector2.ZERO and not box.grow(0.5).encloses(c.get_global_rect()):
				outside.append("%s %s" % [c.name, c.get_global_rect()])
			if c is Button and c.theme_type_variation == "FlatButton":
				x_buttons += 1
		assert_eq(outside, PackedStringArray(), "%s stays inside the panel" % view)
		assert_eq(x_buttons, 1, "%s has the X" % view)
		assert_eq(_small_targets(panel), PackedStringArray(), "%s: tap targets" % view)


func test_the_x_clears_the_selection() -> void:
	var hud: Hud = await _phone_at(Vector2i(914, 411))
	var sel := _connect(hud).selection
	var w := _town(hud)
	sel.set_ids([w.keep_id])
	await wait_process_frames(2)
	for c in _controls(hud.bottom.selection_panel):
		if c is Button and c.theme_type_variation == "FlatButton":
			(c as Button).pressed.emit()
	assert_eq(sel.ids.size(), 0, "nothing selected")


func test_minimap_overlay() -> void:
	var hud: Hud = await _phone_at(Vector2i(640, 360))
	assert_false(hud.close_overlay(), "nothing to close")
	assert_true(hud.open_map(), "a phone has the overlay")
	await wait_process_frames(2)
	var frame := hud.bottom.map_frame.get_global_rect()
	assert_eq(hud.bottom.minimap.size, Vector2.ONE * Minimap.PHONE_SIZE)
	assert_eq(frame.end.x, 640.0 - Hud.PHONE_GAP, "top right")
	assert_eq(frame.position.y, hud.top_bar.get_global_rect().end.y + Hud.PHONE_GAP, "under the bar")
	assert_true(hud.top_bar._map_button.button_pressed, "Map shows it open")
	assert_eq(_off_screen(hud), PackedStringArray(), "on screen")
	assert_true(hud.close_overlay(), "close_overlay() closes it")
	assert_false(hud.map_overlay.visible)
	assert_false(hud.top_bar._map_button.button_pressed)
	hud.top_bar.map_requested.emit()
	assert_true(hud.map_overlay.visible, "Map opens it")
	hud.top_bar.map_requested.emit()
	assert_false(hud.map_overlay.visible, "and Map again closes it")
	hud.open_map()
	var tap := InputEventMouseButton.new()
	tap.button_index = MOUSE_BUTTON_LEFT
	tap.pressed = true
	hud._on_map_overlay_input(tap)
	assert_false(hud.map_overlay.visible, "a tap beside it closes it")
	hud.use_layout(Hud.Layout.DESKTOP, true)
	assert_false(hud.open_map(), "no overlay on desktop")
	assert_eq(hud.bottom.map_frame.get_parent().get_parent(), hud.bottom, "the minimap is back in the bottom panel")


func test_select_toggle_follows_the_input() -> void:
	var hud: Hud = await _phone_at(Vector2i(914, 411))
	var input := _connect(hud)
	var toggle := hud.select_toggle
	assert_eq(toggle.size, Vector2.ONE * SelectToggle.SIZE)
	assert_eq(toggle.get_global_rect().position, Vector2(Hud.PHONE_GAP, 411 - Hud.PHONE_GAP - SelectToggle.SIZE), "bottom left")
	toggle.button_pressed = true
	assert_true(input.drag_selects, "turning it on makes the next drag select")
	input.set_drag_selects(false)
	assert_false(toggle.button_pressed, "the touch controls turn it off after one box")
	input.set_drag_selects(true)
	assert_true(toggle.button_pressed)


func test_toasts_stay_in_the_phone_world_band() -> void:
	var hud: Hud = await _phone_at(Vector2i(640, 360))
	for i in 5:
		hud.toasts.show_toast("Need houses: build a Cottage to raise the population cap.", "warn")
	await wait_process_frames(3)
	var band := hud.world_rect()
	var shown := 0
	for t in hud.toasts.get_children():
		if t in hud.toasts._toasts:
			shown += 1
			var r := (t as Control).get_global_rect()
			assert_true(r.position.x >= band.position.x and r.end.x <= band.end.x, "toast inside the band: %s in %s" % [r, band])
			assert_true(r.position.y >= hud.top_bar.get_global_rect().end.y, "toast under the bar")
	assert_eq(shown, ToastLayer.MAX_TOASTS_COMPACT, "at most two toasts on a phone")


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
