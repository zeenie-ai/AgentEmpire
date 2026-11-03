extends GutTest
## RtsInput on touch, in a generated town seen through a real camera: what a tap, a long press
## and the Select toggle's box do, and that the mouse events the engine makes from touches are
## left alone. Everything runs synchronously: the town steps only when a test steps it. The
## scene sits in its own 1600x900 viewport: the headless root window is a 64 px square stretched
## to 1600x1600, which no screen is.

var w: SimWorld
var vp: SubViewport
var view: WorldView
var cam: RtsCamera
var selection: Selection
var input: RtsInput


func before_each() -> void:
	Game.paused = true
	w = SimFixture.generated_world(4127)
	vp = SubViewport.new()
	vp.size = Vector2i(1600, 900)
	vp.own_world_3d = true
	add_child_autofree(vp)
	view = WorldView.new()
	vp.add_child(view)
	cam = RtsCamera.new()
	vp.add_child(cam)
	cam.edge_scroll = false
	selection = Selection.new()
	view.selection = selection
	input = RtsInput.new()
	vp.add_child(input)
	input.setup(view, cam, selection, null)
	input.touch_mode = true
	Game.start_world(w)
	view.bind(w)
	cam.map_size = float(w.grid.size)
	var k := w.keep()
	cam.set_view(Vector3(k.center().x, 0.0, k.center().y + 3.0), 32.0, 0.0)


func after_each() -> void:
	Game.stop_town()
	Game.paused = false
	view.unbind()


func _townsfolk() -> Array[int]:
	var out: Array[int] = []
	for u: SimUnit in w.units.values():
		if u.kind == "townsfolk":
			out.append(u.id)
	out.sort()
	return out


func _unit_screen(id: int) -> Vector2:
	return cam.camera.unproject_position(view.unit_visual_position(id) + Vector3(0, 0.45, 0))


func _cell_screen(cell: Vector2i) -> Vector2:
	return cam.camera.unproject_position(Vector3(cell.x + 0.5, 0.0, cell.y + 0.5))


func _pick(screen: Vector2) -> Dictionary:
	return Picking.pick(w, view, cam.camera, screen)


## The berry bush nearest the Keep that a touch reaches (in view, not behind a building).
func _bush_in_view() -> SimResourceNode:
	var best: SimResourceNode = null
	var near := w.keep().center()
	var screen := cam.get_viewport().get_visible_rect()
	for n: SimResourceNode in w.nodes.values():
		if n.kind != "berry_bush" or not n.is_live():
			continue
		if best != null and n.center().distance_to(near) >= best.center().distance_to(near):
			continue
		var sp := cam.camera.unproject_position(Vector3(n.center().x, 0.3, n.center().y))
		if screen.has_point(sp) and int(_pick(sp)["id"]) == n.id:
			best = n
	return best


## A free ground cell near the Keep, in view.
func _ground_cell() -> Vector2i:
	var k := Vector2i(w.keep().center())
	for dy in range(4, 12):
		for dx in range(-6, 7):
			var c := k + Vector2i(dx, dy)
			if String(_pick(_cell_screen(c))["kind"]) == "ground":
				return c
	return Pathing.NO_CELL


func _select_townsfolk() -> Array[int]:
	var ids := _townsfolk()
	selection.set_ids(ids)
	return ids


func test_a_tap_selects_a_townsperson() -> void:
	var id := _townsfolk()[0]
	input.tap_at(_unit_screen(id), false)
	assert_eq(selection.ids, [id] as Array[int])


func test_a_double_tap_selects_everyone_of_that_kind() -> void:
	var ids := _townsfolk()
	input.tap_at(_unit_screen(ids[0]), false)
	input.tap_at(_unit_screen(ids[0]), true)
	assert_eq(selection.ids.size(), ids.size(), "all %d townsfolk on screen" % ids.size())


func test_a_tap_on_a_bush_sends_the_townsfolk_gathering() -> void:
	var ids := _select_townsfolk()
	var bush := _bush_in_view()
	assert_not_null(bush, "a bush is in view")
	if bush == null:
		return
	input.tap_at(cam.camera.unproject_position(Vector3(bush.center().x, 0.3, bush.center().y)), false)
	w.step(1)
	for id in ids:
		var u: SimUnit = w.units[id]
		assert_eq(u.job, SimConst.JOB_GATHER, "townsperson %d gathers" % id)
		assert_eq(u.target_id, bush.id)
	assert_eq(selection.ids, ids, "an order keeps the selection")


func test_a_tap_on_the_ground_moves_them() -> void:
	var ids := _select_townsfolk()
	var cell := _ground_cell()
	assert_ne(cell, Pathing.NO_CELL)
	input.tap_at(_cell_screen(cell), false)
	w.step(1)
	for id in ids:
		assert_eq((w.units[id] as SimUnit).job, SimConst.JOB_MOVE, "townsperson %d walks" % id)
	assert_eq(selection.ids, ids)


func test_a_tap_on_a_unit_or_building_selects_it() -> void:
	var ids := _select_townsfolk()
	input.tap_at(_unit_screen(ids[1]), false)
	assert_eq(selection.ids, [ids[1]] as Array[int], "another townsperson: no walk onto it")
	_select_townsfolk()
	var k := w.keep()
	input.tap_at(cam.camera.unproject_position(Vector3(k.center().x, 1.0, k.center().y)), false)
	assert_eq(selection.ids, [k.id] as Array[int], "the Keep, with nothing to carry there")
	w.step(1)
	for id in ids:
		assert_eq((w.units[id] as SimUnit).job, SimConst.JOB_IDLE, "nobody was ordered")


func test_a_tap_on_the_ground_without_townsfolk_deselects() -> void:
	selection.set_ids([w.keep().id])
	input.tap_at(_cell_screen(_ground_cell()), false)
	assert_true(selection.is_empty())


func test_a_touch_picks_units_further_away() -> void:
	var id := _townsfolk()[1]
	var above := _unit_screen(id) + Vector2(0, -30)
	assert_false(int(_pick(above)["id"]) == id, "30 px off is too far for a click")
	var hit := Picking.pick(w, view, cam.camera, above, 40.0)
	assert_eq(String(hit["kind"]), "unit")
	assert_eq(int(hit["id"]), id, "within a wider radius")


func test_a_long_press_selects_without_an_order() -> void:
	var ids := _select_townsfolk()
	var bush := _bush_in_view()
	if bush == null:
		fail_test("no bush in view")
		return
	input.select_at(cam.camera.unproject_position(Vector3(bush.center().x, 0.3, bush.center().y)))
	assert_eq(selection.ids, [bush.id] as Array[int], "the bush is selected")
	w.step(1)
	for id in ids:
		assert_eq((w.units[id] as SimUnit).job, SimConst.JOB_IDLE, "nobody went gathering")


func test_box_select() -> void:
	var ids := _townsfolk()
	var box := Rect2(_unit_screen(ids[0]), Vector2.ZERO)
	for id in ids:
		box = box.expand(_unit_screen(id))
	input.box_select(box.grow(20.0))
	assert_eq(selection.ids.size(), ids.size())
	input.box_select(Rect2(Vector2(1, 1), Vector2(4, 4)))
	assert_true(selection.is_empty(), "an empty box clears the selection")


func test_rally_mode_takes_the_next_tap() -> void:
	var k := w.keep()
	selection.set_ids([k.id])
	input.activate({"id": "rally"})
	assert_eq(input.mode, RtsInput.Mode.RALLY)
	var cell := _ground_cell()
	input.tap_at(_cell_screen(cell), false)
	w.step(1)
	assert_false(k.rally.is_empty(), "the rally point is set")
	assert_eq(Vector2i(int(k.rally["x"]), int(k.rally["y"])), cell)
	assert_eq(input.mode, RtsInput.Mode.SELECT, "and the mode ends")
	assert_eq(selection.ids, [k.id] as Array[int])


## The screen point of the middle of a `type` footprint at `cell`.
func _footprint_screen(type: String, cell: Vector2i) -> Vector2:
	var fp := Vector2(w.econ.building_footprint(type))
	return cam.camera.unproject_position(Vector3(cell.x + fp.x * 0.5, 0.0, cell.y + fp.y * 0.5))


func _ghost_rect() -> Rect2:
	return Rect2(Vector2(input.place_cell), Vector2(w.econ.building_footprint(input.place_type)))


func _cottage_spot() -> Vector2i:
	return DemoTown.find_spot(w, "cottage", Vector2i(w.keep().center()) + Vector2i(6, 3), 6)


func test_touch_placement_starts_in_the_middle_of_the_view() -> void:
	_select_townsfolk()
	input.begin_placement("cottage")
	assert_eq(input.mode, RtsInput.Mode.PLACE)
	assert_true(view.ghost.visible)
	var g: Vector3 = cam.screen_to_ground(cam.safe_rect().get_center())
	assert_true(_ghost_rect().has_point(Vector2(g.x, g.z)), "the ghost stands under the middle of the view")


func test_a_tap_moves_the_ghost() -> void:
	_select_townsfolk()
	input.begin_placement("cottage")
	var spot := _cottage_spot()
	input.tap_at(_footprint_screen("cottage", spot), false)
	assert_eq(input.place_cell, spot)
	assert_true(bool(input.place_check["ok"]))
	assert_eq(input.mode, RtsInput.Mode.PLACE, "a tap only moves it")
	assert_eq(selection.ids.size(), 3, "and selects nothing")


func test_the_ghost_is_there_to_be_dragged() -> void:
	_select_townsfolk()
	input.begin_placement("cottage")
	var middle := _footprint_screen("cottage", input.place_cell)
	assert_true(input.ghost_contains(middle))
	assert_gt(30.0, input._touch_pick_px(), "this view's touch radius")
	assert_true(input.ghost_contains(middle + Vector2(0, -30)), "its model counts too")
	assert_false(input.ghost_contains(middle + Vector2(300, 0)))
	input.cancel_mode()
	assert_false(input.ghost_contains(middle), "no ghost, nothing to drag")


func test_build_places_the_site_and_pays() -> void:
	var ids := _select_townsfolk()
	input.begin_placement("cottage")
	var spot := _cottage_spot()
	input.move_ghost(_footprint_screen("cottage", spot))
	var wood := w.ledger.amount("wood")
	input.activate({"id": "mode_build"})
	w.step(1)
	var site := w.building_at(spot)
	assert_true(site != null and site.type == "cottage", "a Cottage site at %s" % spot)
	assert_eq(w.ledger.amount("wood"), wood - int(w.econ.building_cost("cottage")["wood"]))
	for id in ids:
		assert_eq((w.units[id] as SimUnit).job, SimConst.JOB_BUILD)
	assert_eq(input.mode, RtsInput.Mode.SELECT, "one at a time without Repeat")


func test_build_on_a_bad_spot_places_nothing() -> void:
	_select_townsfolk()
	input.begin_placement("cottage")
	input.move_ghost(_footprint_screen("cottage", w.keep().cell))
	assert_false(bool(input.place_check["ok"]), "on the Keep")
	var count := w.buildings.size()
	input.confirm_placement()
	w.step(1)
	assert_eq(w.buildings.size(), count)
	assert_eq(input.mode, RtsInput.Mode.PLACE, "still placing")


func test_repeat_keeps_placing_until_the_next_placement() -> void:
	_select_townsfolk()
	input.begin_placement("cottage")
	input.activate({"id": "mode_repeat"})
	assert_true(input.place_repeat)
	input.move_ghost(_footprint_screen("cottage", _cottage_spot()))
	input.confirm_placement()
	assert_eq(input.mode, RtsInput.Mode.PLACE, "Repeat keeps the ghost up")
	input.begin_placement("farm")
	assert_false(input.place_repeat, "a new placement starts without Repeat")
	input.activate({"id": "mode_cancel"})
	assert_eq(input.mode, RtsInput.Mode.SELECT)
	assert_false(view.ghost.visible)


func test_the_card_shows_the_mode_bar() -> void:
	_select_townsfolk()
	input.begin_placement("cottage")
	input.move_ghost(_footprint_screen("cottage", _cottage_spot()))
	var slots := input.card_slots()
	assert_eq(String(slots[0]["id"]), String(CommandCardModel.slots(w, selection.ids)[0]["id"]), "the rows above stay")
	assert_eq(String(slots[12]["id"]), "mode_repeat")
	assert_false(bool(slots[12]["active"]))
	assert_eq(String(slots[13]["id"]), "mode_build")
	assert_eq(String(slots[13]["icon"]), "cottage")
	assert_true(bool(slots[13]["enabled"]), "the spot works")
	assert_eq(String(slots[14]["id"]), "mode_cancel")
	input.move_ghost(_footprint_screen("cottage", w.keep().cell))
	assert_false(bool(input.card_slots()[13]["enabled"]), "Build follows the ghost")
	input.activate({"id": "mode_repeat"})
	assert_true(bool(input.card_slots()[12]["active"]), "Repeat shows when it is on")
	input.touch_mode = false
	assert_true(input.card_slots()[13].is_empty(), "no mode bar with a mouse")


func test_rally_mode_bar_only_cancels() -> void:
	var k := w.keep()
	selection.set_ids([k.id])
	input.activate({"id": "rally"})
	var slots := input.card_slots()
	assert_true(slots[12].is_empty())
	assert_true(slots[13].is_empty())
	assert_eq(String(slots[14]["id"]), "mode_cancel")
	input.activate(slots[14])
	assert_eq(input.mode, RtsInput.Mode.SELECT)
	assert_true(k.rally.is_empty(), "no rally point was set")


func test_touch_hints_say_tap_and_build() -> void:
	var hints: Array[String] = []
	input.hint_changed.connect(func(text: String, _ok: bool) -> void: hints.append(text))
	_select_townsfolk()
	input.begin_placement("cottage")
	input.move_ghost(_footprint_screen("cottage", _cottage_spot()))
	assert_eq(hints.back(), "Cottage: tap or drag to move it, then tap Build.")
	input.cancel_mode()
	selection.set_ids([w.keep().id])
	input.activate({"id": "rally"})
	assert_eq(hints.back(), "Tap where new townsfolk should go.")
	for text in hints:
		assert_false(text.to_lower().contains("click"), "no clicks on touch: %s" % text)
	input.cancel_mode()
	input.touch_mode = false
	input.activate({"id": "rally"})
	assert_eq(hints.back(), "Click to set the rally point. Right-click cancels.", "desktop wording stays")


func test_mouse_events_made_from_touches_are_left_alone() -> void:
	var id := _townsfolk()[0]
	var at := _unit_screen(id)
	_click(at, InputEvent.DEVICE_ID_EMULATION)
	assert_true(selection.is_empty(), "touch mode: TouchControls has the touch itself")
	_click(at, 0)
	assert_eq(selection.ids, [id] as Array[int], "a real mouse still clicks")
	selection.clear()
	input.touch_mode = false
	_click(at, InputEvent.DEVICE_ID_EMULATION)
	assert_eq(selection.ids, [id] as Array[int], "desktop: unchanged")


func test_no_hover_on_touch() -> void:
	view.hover_id = 5
	input._update_hover()
	assert_eq(view.hover_id, 0)


func _click(at: Vector2, device: int) -> void:
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.device = device
		e.button_index = MOUSE_BUTTON_LEFT
		e.position = at
		e.pressed = pressed
		input._unhandled_input(e)
