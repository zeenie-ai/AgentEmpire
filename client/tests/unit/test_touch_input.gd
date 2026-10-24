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
