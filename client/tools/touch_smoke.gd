extends SceneTree
## End-to-end touch check in a real window, as on a phone: injects screen touches and drags
## (fingers 0 and 1) through Input.parse_input_event at window coordinates, so the engine also
## makes the mouse events it makes on a device, and verifies the results in the simulation:
##   tap the Keep -> its Rally card, tap the ground (rally point) -> tap a townsperson, double
##   tap (all of them) -> tap a berry bush (gather) -> the Cottage card, drag the ghost, Build
##   (a site, paid) -> the Select toggle and a drag (box select) -> one finger pans, two fingers
##   pinch (zoom) and twist (turn).
## Run (a real window, not --headless):
##   .tools/godot/Godot_v4.7.2-stable_win64_console.exe --path client -s res://tools/touch_smoke.gd -- --mobile --dpi=420
## Options after "--": --size=WxH (the window, default 2400x1080; 1200x540 with --dpi=210 is
## the same 914x411 dp phone), --shots=<dir> (screenshots of the steps).
## Command card buttons are tapped where they are on screen. One that does not fit the screen
## (the desktop card's bottom row on a phone, before the phone layout) is pressed through the
## card instead, and the run notes it.
## Game classes that use autoloads are held in untyped variables: a -s script compiles before
## the autoloads exist.

var _main: Variant
var _picking: Variant
var _failures: int = 0
var _notes: int = 0
var _shots: String = ""


func _game() -> Node:
	return root.get_node("Game")


func _initialize() -> void:
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.get_slice("=", 1)
	return fallback


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("touch_smoke needs a real window: run it without --headless.")
		quit(2)
		return
	if not Platform.is_mobile():
		printerr("touch_smoke plays the phone build: run it with -- --mobile --dpi=420.")
		quit(2)
		return
	var sz := _arg("size", "2400x1080").split("x")
	DisplayServer.window_set_size(Vector2i(int(sz[0]), int(sz[1])))
	_shots = _arg("shots", "")
	if _shots != "":
		DirAccess.make_dir_recursive_absolute(_shots)
	_picking = load("res://input/picking.gd")
	await _frames(3)
	_main = load("res://game/main.tscn").instantiate()
	_main.autostart = false
	root.add_child(_main)
	await process_frame
	var w: SimWorld = _game().new_town(4127, "touch")
	# The town only steps when the run steps it, so positions hold still between a look and a
	# touch.
	_game().paused = true
	var cam: Variant = _main.camera
	var selection: Selection = _main.selection
	var input: Variant = _main.input
	await _frames(10)
	print("touch_smoke: %s at %s dpi, %s dp, world %s" % [str(DisplayServer.window_get_size()), _arg("dpi", "?"),
		str(root.get_visible_rect().size), str(_main.world_rect())])
	var px_per_dp: float = _main.get_node("TouchControls").gestures.px_per_dp
	_check(absf(px_per_dp - 1.0) < 0.001, "touches are measured in dp (%.3f px per dp)" % px_per_dp)
	var k := w.keep()
	cam.set_view(Vector3(k.center().x, 0.0, k.center().y), 26.0, 0.0)
	await _focus(Vector3(k.center().x, 0.0, k.center().y))

	# 1. Tap the Keep: it is selected.
	await _tap_world(_screen(Vector3(k.center().x, 1.5, k.center().y)))
	_check(selection.ids.size() == 1 and selection.ids[0] == k.id, "a tap selects the Keep")

	# 2. Its Rally card, then a tap on the ground: the rally point.
	await _tap_card(3, "rally")
	_check(input.mode == input.Mode.RALLY, "the Rally card asks for the rally point")
	var rally_cell := _ground_cell(w, Vector2i(k.center()) + Vector2i(-5, 1))
	await _tap_world(_cell_screen(rally_cell))
	w.step(1)
	_check(not k.rally.is_empty() and Vector2i(int(k.rally["x"]), int(k.rally["y"])).distance_to(rally_cell) <= 1.5,
		"the next tap sets the rally point (%s)" % str(k.rally))
	_check(input.mode == input.Mode.SELECT, "and ends the rally mode")

	# 3. Tap a townsperson, then double tap: everyone of that kind on screen.
	var folk := _townsfolk(w)
	await _focus(_centroid(folk))
	await _shot("1_town")
	await _tap_world(_unit_screen(folk[0]))
	_check(selection.ids.size() == 1 and selection.ids[0] == folk[0], "a tap selects a townsperson")
	await _tap_world(_unit_screen(folk[0]), true)
	_check(selection.ids.size() == folk.size(), "a double tap selects all %d townsfolk (got %d)" % [folk.size(), selection.ids.size()])

	# 4. Tap a berry bush: they go gathering.
	var bush := await _bush_in_view(w)
	_check(bush != null, "a berry bush is in view")
	if bush == null:
		_finish()
		return
	await _tap_world(_screen(Vector3(bush.center().x, 0.3, bush.center().y)))
	w.step(1)
	var gathering := 0
	for id in selection.ids:
		var u: SimUnit = w.units[id]
		if u.job == SimConst.JOB_GATHER and u.target_id == bush.id:
			gathering += 1
	_check(gathering == folk.size(), "a tap on a bush sends them gathering (%d)" % gathering)

	# 5. The Cottage card: the ghost appears in the middle of the view. Drag it to a free spot,
	#    then Build.
	var spot := DemoTown.find_spot(w, "cottage", Vector2i(k.center()) + Vector2i(6, 3), 6)
	var fp := Vector2(w.econ.building_footprint("cottage"))
	var spot_mid := Vector3(spot.x + fp.x * 0.5, 0.0, spot.y + fp.y * 0.5)
	await _focus(spot_mid + Vector3(-3.0, 0.0, 1.0))
	await _tap_card(_card_index(input, "build:cottage"), "build:cottage")
	_check(input.mode == input.Mode.PLACE, "the Cottage card starts placing")
	var under: Vector3 = cam.screen_to_ground(cam.safe_rect().get_center())
	_check(Rect2(Vector2(input.place_cell), fp).has_point(Vector2(under.x, under.z)), "the ghost starts in the middle of the view")
	var ghost_mid := _screen(Vector3(input.place_cell.x + fp.x * 0.5, 0.0, input.place_cell.y + fp.y * 0.5))
	await _swipe(ghost_mid, _screen(spot_mid))
	_check(input.place_cell == spot, "a drag on the ghost moves it (%s, wanted %s)" % [str(input.place_cell), str(spot)])
	_check(bool(input.place_check.get("ok", false)), "the spot works")
	await _shot("2_placing")
	var wood := w.ledger.amount("wood")
	await _tap_card(13, "mode_build")
	w.step(1)
	var site := w.building_at(spot)
	_check(site != null and site.type == "cottage", "Build places a Cottage site at %s" % str(spot))
	_check(w.ledger.amount("wood") == wood - int(w.econ.building_cost("cottage")["wood"]), "the Cottage was paid for")
	_check(input.mode == input.Mode.SELECT, "placing ends after one without Repeat")
	var builders := 0
	for id in selection.ids:
		if (w.units[id] as SimUnit).job == SimConst.JOB_BUILD:
			builders += 1
	_check(builders == folk.size(), "the selected townsfolk go and build it (%d)" % builders)

	# 6. The Select toggle, then a drag: a selection box.
	selection.clear()
	await _focus(_centroid(folk))
	input.set_drag_selects(true)
	var box := Rect2(_unit_screen(folk[0]), Vector2.ZERO)
	for id in folk:
		box = box.expand(_unit_screen(id))
	box = box.grow(24.0)
	_check(_main.world_rect().encloses(box), "the townsfolk fit in the view")
	await _swipe(box.position, box.end, 6, "3_box")
	_check(selection.ids.size() == folk.size(), "the Select toggle's drag box-selects all %d (got %d)" % [folk.size(), selection.ids.size()])
	_check(not input.drag_selects, "the toggle turns itself off after one box")

	# 7. One finger pans: the ground under it follows it.
	var view: Rect2 = _main.world_rect()
	var p0 := view.get_center() + Vector2(view.size.x * 0.15, 0.0)
	var p1 := view.get_center() - Vector2(view.size.x * 0.15, 0.0)
	var grabbed: Vector3 = cam.screen_to_ground(p0)
	var pivot: Vector3 = cam.pivot
	await _swipe(p0, p1)
	var after: Vector3 = cam.screen_to_ground(p1)
	_check(cam.pivot.distance_to(pivot) > 1.0, "one finger pans the view")
	_check(after.distance_to(grabbed) < 0.5, "the ground under the finger follows it (%.2f tiles off)" % after.distance_to(grabbed))
	await _shot("4_panned")

	# 8. Two fingers spread: the camera comes closer. 9. They twist: the view turns with them.
	var c := view.get_center()
	var before: float = cam.distance
	await _fingers(c, Vector2(50, 0), Vector2(150, 0), 0.0)
	_check(cam.distance < before * 0.75, "a pinch zooms in (%.1f -> %.1f)" % [before, cam.distance])
	var yaw: float = cam.yaw
	await _fingers(c, Vector2(90, 0), Vector2(90, 0), 0.6)
	_check(cam.yaw > yaw + 0.3, "a clockwise twist turns the view with the fingers (%.2f -> %.2f rad)" % [yaw, cam.yaw])
	await _shot("5_turned")

	# 10. In the desktop preview the mouse is a finger: a click is one tap. With the townsfolk
	#     selected, a click on the ground moves them and keeps them selected (a left click
	#     handled as on desktop as well would deselect them), and nothing lights up under it.
	if not OS.has_feature("mobile"):
		cam.set_view(cam.pivot, 26.0, 0.0)
		await _focus(_centroid(folk))
		selection.set_ids(folk)
		_main.world_view.hover_id = 0
		await _hover(_unit_screen(folk[0]))
		_check(_main.world_view.hover_id == 0, "no hover under the mouse")
		var cell := _ground_cell(w, Vector2i(_centroid(folk).x, _centroid(folk).z) + Vector2i(3, 0))
		await _click(_cell_screen(cell))
		w.step(1)
		var walking := 0
		for id in folk:
			if (w.units[id] as SimUnit).job == SimConst.JOB_MOVE:
				walking += 1
		_check(walking == folk.size() and selection.ids.size() == folk.size(),
			"a mouse click is one tap: they walk, still selected (%d walking, %d selected)" % [walking, selection.ids.size()])
	_finish()


func _finish() -> void:
	print("touch_smoke: %s (%d failure%s, %d note%s)" % ["PASS" if _failures == 0 else "FAIL", _failures,
		"" if _failures == 1 else "s", _notes, "" if _notes == 1 else "s"])
	quit(0 if _failures == 0 else 1)


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _note(what: String) -> void:
	print("note  %s" % what)
	_notes += 1


func _frames(n: int) -> void:
	for i in n:
		await process_frame


# --- where things are ----------------------------------------------------------------------------

func _screen(p: Vector3) -> Vector2:
	return _main.camera.camera.unproject_position(p)


func _unit_screen(id: int) -> Vector2:
	return _screen(_main.world_view.unit_visual_position(id) + Vector3(0, 0.45, 0))


func _cell_screen(cell: Vector2i) -> Vector2:
	return _screen(Vector3(cell.x + 0.5, 0.0, cell.y + 0.5))


func _townsfolk(w: SimWorld) -> Array[int]:
	var out: Array[int] = []
	for u: SimUnit in w.units.values():
		if u.kind == "townsfolk":
			out.append(u.id)
	out.sort()
	return out


func _centroid(ids: Array[int]) -> Vector3:
	var sum := Vector3.ZERO
	for id in ids:
		sum += _main.world_view.unit_visual_position(id)
	return sum / float(ids.size())


## Centres the world's view on `p`, as the camera's own focus jump does.
func _focus(p: Vector3) -> void:
	_main.camera.focus(p, true)
	await _frames(3)


## A ground cell near `near` that a tap reaches, inside the world's view.
func _ground_cell(w: SimWorld, near: Vector2i) -> Vector2i:
	for r in range(0, 6):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var c := near + Vector2i(dx, dy)
				var sp := _cell_screen(c)
				if _main.world_rect().has_point(sp) and String(_picking.pick(w, _main.world_view, _main.camera.camera, sp)["kind"]) == "ground":
					return c
	return near


## The berry bush nearest the Keep that a tap reaches once the view is centred on it (none
## stands behind a building).
func _bush_in_view(w: SimWorld) -> SimResourceNode:
	var bushes: Array[SimResourceNode] = []
	for n: SimResourceNode in w.nodes.values():
		if n.kind == "berry_bush" and n.is_live():
			bushes.append(n)
	var k := w.keep().center()
	bushes.sort_custom(func(a: SimResourceNode, b: SimResourceNode) -> bool: return a.center().distance_to(k) < b.center().distance_to(k))
	for n in bushes.slice(0, 8):
		await _focus(Vector3(n.center().x, 0.0, n.center().y))
		var sp := _screen(Vector3(n.center().x, 0.3, n.center().y))
		if int(_picking.pick(w, _main.world_view, _main.camera.camera, sp)["id"]) == n.id:
			return n
	return null


func _card_index(input: Variant, id: String) -> int:
	var slots: Array[Dictionary] = input.card_slots()
	for i in slots.size():
		if String(slots[i].get("id", "")) == id:
			return i
	return -1


# --- fingers -------------------------------------------------------------------------------------

## A point in the viewport (dp on a phone) as the window pixel a touch screen reports.
func _win(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _touch(index: int, p: Vector2, pressed: bool, double_tap: bool = false) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = _win(p)
	e.pressed = pressed
	e.double_tap = double_tap
	Input.parse_input_event(e)


func _move(index: int, p: Vector2, from: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = _win(p)
	e.relative = _win(p) - _win(from)
	Input.parse_input_event(e)


## A tap in the world's view (a point outside it would land on the HUD).
func _tap_world(p: Vector2, double_tap: bool = false) -> void:
	if not _main.world_rect().has_point(p):
		_check(false, "%s is in the world's view %s" % [str(p), str(_main.world_rect())])
	await _tap(p, double_tap)


func _tap(p: Vector2, double_tap: bool = false) -> void:
	_touch(0, p, true, double_tap)
	await _frames(1)
	_touch(0, p, false)
	await _frames(3)


## Taps command card slot `i` (which should hold `id`) where its button is on screen.
func _tap_card(i: int, id: String) -> void:
	var slots: Array[Dictionary] = _main.input.card_slots()
	_check(i >= 0 and String(slots[i].get("id", "")) == id, "the card offers %s in slot %d" % [id, i])
	if i < 0:
		return
	var button: Control = _main.hud.bottom.command_card.get_child(i)
	var r := button.get_global_rect()
	if root.get_visible_rect().encloses(r):
		await _tap(r.get_center())
	else:
		_note("card slot %d (%s) is off screen at this size; pressed through the card instead" % [i, id])
		button.pressed.emit()
		await _frames(3)


## One finger from `from` to `to` in `steps` moves (a screenshot named `shot` before lifting).
func _swipe(from: Vector2, to: Vector2, steps: int = 6, shot: String = "") -> void:
	_touch(0, from, true)
	await _frames(1)
	var last := from
	for s in range(1, steps + 1):
		var p := from.lerp(to, float(s) / float(steps))
		_move(0, p, last)
		last = p
		await _frames(1)
	if shot != "":
		await _shot(shot)
	_touch(0, to, false)
	await _frames(3)


## Two fingers either side of `centre`, `arm0` from it, move until they are `arm1` from it and
## have turned `turn` radians (clockwise on screen when positive).
func _fingers(centre: Vector2, arm0: Vector2, arm1: Vector2, turn: float) -> void:
	_touch(0, centre - arm0, true)
	await _frames(1)
	_touch(1, centre + arm0, true)
	await _frames(1)
	var a := centre - arm0
	var b := centre + arm0
	var steps := 10
	for s in range(1, steps + 1):
		var t := float(s) / float(steps)
		var arm := arm0.lerp(arm1, t).rotated(turn * t)
		_move(0, centre - arm, a)
		a = centre - arm
		await _frames(1)
		_move(1, centre + arm, b)
		b = centre + arm
		await _frames(1)
	_touch(1, b, false)
	await _frames(1)
	_touch(0, a, false)
	await _frames(3)


## The real mouse, as the OS reports it: the engine turns it into touches in the preview.
func _hover(p: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = _win(p)
	e.global_position = _win(p)
	Input.parse_input_event(e)
	await _frames(10)


func _click(p: Vector2) -> void:
	await _hover(p)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.position = _win(p)
		e.global_position = _win(p)
		e.button_index = MOUSE_BUTTON_LEFT
		if pressed:
			e.button_mask = MOUSE_BUTTON_MASK_LEFT
		e.pressed = pressed
		Input.parse_input_event(e)
		await _frames(2)


func _shot(name: String) -> void:
	if _shots == "":
		return
	await _frames(2)
	var path := _shots.path_join("touch_%s.png" % name)
	var img := root.get_texture().get_image()
	print("shot: %s %s" % [path, "ok" if img.save_png(path) == OK else "error"])
