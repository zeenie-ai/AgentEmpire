extends SceneTree
## End-to-end input check in a real window: injects mouse and keyboard events (as a player
## would) into the main scene and verifies the results in the simulation.
##   box-select the starting townsfolk -> right-click a berry bush (gather) -> Q, click (place a
##   Cottage) -> H (select the Keep) -> Q (train) -> right-click ground (rally) -> "." (idle)
## Run: .tools/godot/Godot_v4.7.2-stable_win64_console.exe --path client -s res://tools/input_smoke.gd

var _main: Variant
var _failures: int = 0


func _game() -> Node:
	return root.get_node("Game")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("input_smoke needs a real window: run it without --headless.")
		quit(2)
		return
	DisplayServer.window_set_size(Vector2i(1600, 900))
	_main = load("res://game/main.tscn").instantiate()
	_main.autostart = false
	root.add_child(_main)
	await process_frame
	var w: SimWorld = _game().new_town(4127, "smoke")
	var cam: RtsCamera = _main.camera
	var selection: Selection = _main.selection
	var input: RtsInput = _main.input
	cam.input_enabled = false
	var k := w.keep()
	cam.set_view(Vector3(k.center().x, 0.0, k.center().y + 3.0), 32.0, 0.0)
	await _frames(10)

	# 1. Box-select the three starting townsfolk.
	var pts: Array[Vector2] = []
	for id: int in w.units:
		pts.append(cam.camera.unproject_position(_main.world_view.unit_visual_position(id) + Vector3(0, 0.35, 0)))
	var box := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		box = box.expand(p)
	box = box.grow(30.0)
	await _drag(box.position, box.end)
	_check(selection.ids.size() == w.units.size(), "box select picks all %d townsfolk (got %d)" % [w.units.size(), selection.ids.size()])

	# 2. Right-click the nearest berry bush: everyone gathers it.
	var bush := w.find_nearest_node(k.center(), ["berry_bush"], 20.0)
	await _click(_screen_of(cam, bush.center(), 0.3), MOUSE_BUTTON_RIGHT)
	await _frames(4)
	var gathering := 0
	for id in selection.ids:
		var u: SimUnit = w.units[id]
		if u.job == SimConst.JOB_GATHER and u.target_id == bush.id:
			gathering += 1
	_check(gathering == selection.ids.size(), "right-click on a bush sends everyone gathering (%d)" % gathering)

	# 3. Q with townsfolk selected, then click a free spot: a Cottage site appears.
	var spot := DemoTown.find_spot(w, "cottage", Vector2i(k.center()) + Vector2i(6, 3), 6)
	var wood := w.ledger.amount("wood")
	await _key(KEY_Q)
	_check(input.mode == RtsInput.Mode.PLACE, "Q enters placement mode")
	var centre := Vector2(spot) + Vector2(w.econ.building_footprint("cottage")) * 0.5
	var sp := _screen_of(cam, centre, 0.0)
	await _move(sp)
	await _click(sp, MOUSE_BUTTON_LEFT)
	await _frames(4)
	var site := w.building_at(spot)
	_check(site != null and site.type == "cottage", "clicking places a Cottage site at %s" % spot)
	_check(w.ledger.amount("wood") == wood - int(w.econ.building_cost("cottage")["wood"]), "the Cottage was paid for")
	_check(input.mode == RtsInput.Mode.SELECT, "placement ends after one click")
	var builders := 0
	for id in selection.ids:
		if w.units[id].job == SimConst.JOB_BUILD:
			builders += 1
	_check(builders == selection.ids.size(), "the selected townsfolk go and build it (%d)" % builders)

	# 4. H selects the Keep, Q trains a townsperson.
	await _key(KEY_H)
	_check(selection.ids.size() == 1 and selection.ids[0] == k.id, "H selects the Keep")
	var food := w.ledger.amount("food")
	await _key(KEY_Q)
	await _frames(3)
	_check(k.queue.size() == 1, "Q on the Keep queues a townsperson")
	_check(w.ledger.amount("food") == food - int(w.econ.unit_cost("townsfolk")["food"]), "training was paid when queued")

	# 5. Right-click the ground with the Keep selected: rally point.
	var rally_cell := Vector2i(k.center()) + Vector2i(-4, 6)
	await _click(_screen_of(cam, Vector2(rally_cell) + Vector2(0.5, 0.5), 0.0), MOUSE_BUTTON_RIGHT)
	await _frames(3)
	_check(not k.rally.is_empty() and Vector2i(int(k.rally["x"]), int(k.rally["y"])).distance_to(rally_cell) <= 1.5,
		"right-click with the Keep selected sets the rally point (%s)" % str(k.rally))

	# 6. Ctrl+2 / 2 control groups and Escape.
	await _key(KEY_2, true)
	await _key(KEY_ESCAPE)
	_check(selection.ids.is_empty(), "Escape clears the selection")
	await _key(KEY_2)
	_check(selection.ids.size() == 1 and selection.ids[0] == k.id, "2 recalls control group 2")

	print("input_smoke: %s (%d failure%s)" % ["PASS" if _failures == 0 else "FAIL", _failures, "" if _failures == 1 else "s"])
	quit(0 if _failures == 0 else 1)


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _screen_of(cam: RtsCamera, p: Vector2, height: float) -> Vector2:
	return cam.camera.unproject_position(Vector3(p.x, height, p.y))


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _move(p: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.global_position = p
	Input.parse_input_event(e)
	await _frames(2)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.position = p
	e.global_position = p
	e.button_index = button
	e.pressed = pressed
	Input.parse_input_event(e)
	await _frames(2)


func _click(p: Vector2, button: MouseButton) -> void:
	await _move(p)
	await _button(p, button, true)
	await _button(p, button, false)


func _drag(from: Vector2, to: Vector2) -> void:
	await _move(from)
	await _button(from, MOUSE_BUTTON_LEFT, true)
	await _move(from.lerp(to, 0.5))
	await _move(to)
	await _button(to, MOUSE_BUTTON_LEFT, false)


func _key(code: Key, ctrl: bool = false) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.physical_keycode = code
		e.keycode = code
		e.ctrl_pressed = ctrl
		e.pressed = pressed
		Input.parse_input_event(e)
		await _frames(2)
