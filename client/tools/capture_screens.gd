extends SceneTree
## Builds a demo town in a real window, frames the camera and saves two screenshots with
## get_viewport().get_texture().get_image():
##   out/map.png  the town from high up, HUD hidden
##   out/hud.png  the game screen with the HUD, the Keep selected and training
## out/ is at the repository root (next to client/). Needs a window, so do not pass --headless:
##   .tools/godot/Godot_v4.7.2-stable_win64_console.exe --path client -s res://tools/capture_screens.gd
## Options after "--": --out=<dir> --seed=<n> --night

var _args: PackedStringArray


## Autoload names are not compile-time globals in a -s script, so fetch them from the tree.
func _game() -> Node:
	return root.get_node("Game")


func _initialize() -> void:
	_args = OS.get_cmdline_user_args()
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("capture_screens needs a real window: run it without --headless.")
		quit(2)
		return
	DisplayServer.window_set_size(Vector2i(1600, 900))
	var map_seed := 4127
	for a in _args:
		if a.begins_with("--seed="):
			map_seed = int(a.substr(7))
	var main: Variant = load("res://game/main.tscn").instantiate()
	main.autostart = false
	root.add_child(main)
	await process_frame
	_game().paused = true
	var w: SimWorld = _game().new_town(map_seed, "demo")
	DemoTown.build(w, 12, 70.0)
	main.camera.input_enabled = false
	if "--night" in _args:
		main.world_view.environment_view.set_night(1.0)

	var out := DemoTown.out_dir(_args)
	DirAccess.make_dir_recursive_absolute(out)

	# 1. The town from high above, HUD hidden.
	var k := w.keep()
	main.hud.visible = false
	main.camera.set_view(Vector3(k.center().x + 1.0, 0.0, k.center().y + 3.0), 70.0, deg_to_rad(-20.0))
	await _settle(30)
	_save(root.get_viewport().get_texture().get_image(), out.path_join("map.png"))

	# 2. The game screen with the HUD: the Keep selected while training.
	main.hud.visible = true
	w.commands.push(GameCommands.train(k.id, "townsfolk"))
	w.step(1)
	main.selection.set_ids([k.id])
	main.camera.set_view(Vector3(k.center().x + 2.0, 0.0, k.center().y + 2.5), 29.0, deg_to_rad(-20.0))
	_game().paused = false
	await _settle(45)
	_save(root.get_viewport().get_texture().get_image(), out.path_join("hud.png"))
	quit(0)


func _settle(frames: int) -> void:
	for i in frames:
		await process_frame


func _save(img: Image, path: String) -> void:
	var err := img.save_png(path)
	print("capture: %s %dx%d %s" % [path, img.get_width(), img.get_height(), "ok" if err == OK else "error %d" % err])
