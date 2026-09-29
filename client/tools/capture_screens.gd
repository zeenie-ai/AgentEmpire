extends SceneTree
## Builds a demo town in a real window, frames the camera and saves screenshots with
## get_viewport().get_texture().get_image():
##   out/map.png      the town from high up, HUD hidden
##   out/hud.png      the game screen with the HUD, the Keep selected and training
##   out/closeup.png  a low close-up of townsfolk working around the buildings, HUD hidden
##   out/night.png    the same town at night with the HUD
## out/ is at the repository root (next to client/). Needs a window, so do not pass --headless:
##   .tools/godot/Godot_v4.7.2-stable_win64_console.exe --path client -s res://tools/capture_screens.gd
## Options after "--": --out=<dir> --seed=<n> --quality=low|medium|high --size=1600x900
##   --only=map,hud,closeup,night

const DEFAULT_SIZE := Vector2i(1600, 900)

var _args: PackedStringArray
var _size: Vector2i = DEFAULT_SIZE


## Autoload names are not compile-time globals in a -s script, so fetch them from the tree.
func _game() -> Node:
	return root.get_node("Game")


func _initialize() -> void:
	_args = OS.get_cmdline_user_args()
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	for a in _args:
		if a.begins_with("--%s=" % name):
			return a.get_slice("=", 1)
	return fallback


func _wanted(shot: String) -> bool:
	var only := _arg("only", "")
	return only == "" or shot in only.split(",")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("capture_screens needs a real window: run it without --headless.")
		quit(2)
		return
	var sz := _arg("size", "%dx%d" % [DEFAULT_SIZE.x, DEFAULT_SIZE.y]).split("x")
	_size = Vector2i(int(sz[0]), int(sz[1]))
	await _fix_window()
	var map_seed := int(_arg("seed", "4127"))
	var main: Variant = load("res://game/main.tscn").instantiate()
	main.autostart = false
	root.add_child(main)
	await process_frame
	_game().paused = true
	var w: SimWorld = _game().new_town(map_seed, "demo")
	DemoTown.build(w, 12, 70.0)
	main.camera.input_enabled = false

	var out := DemoTown.out_dir(_args)
	DirAccess.make_dir_recursive_absolute(out)
	var k := w.keep()

	# 1. The town from high above, HUD hidden.
	if _wanted("map"):
		main.hud.visible = false
		main.camera.set_view(Vector3(k.center().x + 1.0, 0.0, k.center().y + 3.0), 70.0, deg_to_rad(-20.0))
		await _shot(30, out.path_join("map.png"))

	# 2. The game screen with the HUD: the Keep selected while training.
	if _wanted("hud"):
		main.hud.visible = true
		w.commands.push(GameCommands.train(k.id, "townsfolk"))
		w.step(1)
		main.selection.set_ids([k.id])
		main.camera.set_view(Vector3(k.center().x + 2.0, 0.0, k.center().y + 2.5), 29.0, deg_to_rad(-20.0))
		_game().paused = false
		await _shot(45, out.path_join("hud.png"))

	# 3. A close-up of townsfolk at work near the buildings (a fresh site keeps builders busy).
	if _wanted("closeup"):
		main.hud.visible = false
		main.selection.clear()
		_game().paused = false
		var focus := _busy_spot(w)
		main.camera.set_view(Vector3(focus.x, 0.0, focus.y), 13.0, deg_to_rad(-28.0))
		await _shot(90, out.path_join("closeup.png"))
		_print_animation(main.world_view)

	# 4. Night, with the HUD.
	if _wanted("night"):
		main.hud.visible = true
		main.world_view.environment_view.set_night(1.0)
		main.camera.set_view(Vector3(k.center().x + 1.0, 0.0, k.center().y + 2.0), 32.0, deg_to_rad(-20.0))
		await _shot(40, out.path_join("night.png"))
		main.world_view.environment_view.set_night(0.0)
	quit(0)


## Puts a new Cottage site next to the Keep with three builders, and returns a point between
## it and the Keep, where townsfolk walk, build and carry.
func _busy_spot(w: SimWorld) -> Vector2:
	var k := w.keep()
	var spot := DemoTown.find_spot(w, "cottage", Vector2i(k.center()) + Vector2i(3, 5), 5)
	if spot != Pathing.NO_CELL:
		var ids: Array = []
		for u: SimUnit in w.units.values():
			if ids.size() >= 3:
				break
			ids.append(u.id)
		w.commands.push(GameCommands.place_building(ids, "cottage", spot))
		w.step(int(w.tick_rate * 6))
		return (Vector2(spot) + Vector2(1, 1) + k.center()) * 0.5 + Vector2(0.0, 1.5)
	return k.center() + Vector2(0, 4)


## Which animation state each on-screen rigged unit is in, and where its clip is (diagnostic).
## Untyped on purpose: typed references to game classes would compile them before autoloads.
func _print_animation(view: Variant) -> void:
	var lines := 0
	for v: Variant in view.unit_views.values():
		if not v.rigged or v.anim_tree == null or not v.anim_tree.active or lines >= 8:
			continue
		var pb: AnimationNodeStateMachinePlayback = v.anim_tree.get("parameters/playback")
		print("anim: unit %d state %s node %s pos %.2f" % [v.unit_id, v.anim_state, pb.get_current_node(), pb.get_current_play_position()])
		lines += 1


func _fix_window() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(_size)
	for i in 3:
		await process_frame


func _shot(frames: int, path: String) -> void:
	var img: Image = null
	for attempt in 4:
		for i in frames:
			_hold_window()
			await process_frame
		img = root.get_viewport().get_texture().get_image()
		if img.get_size() == _size:
			break
		frames = 12
	var err := img.save_png(path)
	print("capture: %s %dx%d %s" % [path, img.get_width(), img.get_height(), "ok" if err == OK else "error %d" % err])


## The OS sometimes maximises the window mid-run; put it back to the capture size.
func _hold_window() -> void:
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if DisplayServer.window_get_size() != _size:
		DisplayServer.window_set_size(_size)
