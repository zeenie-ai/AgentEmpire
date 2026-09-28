extends SceneTree
## Diagnostic: runs the real main scene exactly as a player launches it, waits for it to settle,
## saves out/main.png and prints the camera, environment and HUD state.
##   .tools/godot/Godot_v4.7.2-stable_win64_console.exe --path client -s res://tools/snap_main.gd


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var main: Node = load("res://game/main.tscn").instantiate()
	root.add_child(main)
	for i in 90:
		await process_frame
	var cam := root.get_viewport().get_camera_3d()
	if cam == null:
		print("snap: no active Camera3D")
	else:
		print("snap: camera at %s rotation_deg %s fov %.1f near %.2f far %.1f current %s" % [
			cam.global_position, cam.global_rotation_degrees, cam.fov, cam.near, cam.far, cam.current])
	var env: Environment = null
	if cam != null and cam.environment != null:
		env = cam.environment
	elif root.get_world_3d() != null:
		env = root.get_world_3d().environment
	if env == null:
		print("snap: no Environment")
	else:
		print("snap: background_mode %d fog_enabled %s fog_mode %d density %.4f depth_begin %.1f depth_end %.1f" % [
			env.background_mode, env.fog_enabled, env.fog_mode, env.fog_density, env.fog_depth_begin, env.fog_depth_end])
	var hud := main.get_node_or_null("Hud")
	print("snap: hud %s visible %s" % [hud, hud.visible if hud != null else false])
	var out := ProjectSettings.globalize_path("res://").path_join("../out")
	DirAccess.make_dir_recursive_absolute(out)
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png(out.path_join("main.png"))
	print("snap: saved %s %s" % [out.path_join("main.png"), "ok" if err == OK else str(err)])
	quit(0)
