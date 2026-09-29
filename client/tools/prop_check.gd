extends SceneTree
## Look-dev: renders a townsperson walking with the carried wood and food props in several
## hand orientations, from the side, to tune UnitView.prop_offset(). Saves out/prop_check.png.
##   .tools/godot/Godot_v4.7.2-stable_win64_console.exe --path client -s res://tools/prop_check.gd

const ROTS := [Vector3(0, 0, 0), Vector3(0, 90, 0), Vector3(90, 0, 0), Vector3(90, 90, 0), Vector3(0, 0, 0), Vector3(90, 0, 0)]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1500, 700))
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.75, 0.8, 0.85)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	root.add_child(sun)
	sun.look_at_from_position(Vector3(3, 6, 5), Vector3.ZERO, Vector3.UP)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 3.3
	if "--top" in OS.get_cmdline_user_args():
		cam.look_at_from_position(Vector3(2.9, 7.0, 7.0), Vector3(2.9, 0.4, 0.0), Vector3.UP)
	else:
		cam.look_at_from_position(Vector3(2.9, 0.7, 9.0), Vector3(2.9, 0.55, 0.0), Vector3.UP)
	cam.current = true
	var paths := AssetCatalog.character_paths("townsfolk")
	if paths.is_empty():
		print("prop_check: no character art")
		quit(1)
		return
	for i in ROTS.size():
		var r: Vector3 = ROTS[i]
		var scene := load(paths[0]) as PackedScene
		var ch := scene.instantiate() as Node3D
		ch.position = Vector3(float(i) * 1.15, 0, 0)
		ch.rotation_degrees.y = 90.0
		root.add_child(ch)
		var player := ch.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
		player.play("Walking_A")
		player.seek(0.3, true)
		player.pause()
		var sk := ch.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
		var ba := BoneAttachment3D.new()
		sk.add_child(ba)
		ba.bone_name = "handslot.r"
		var prop := ModelLibrary.instance("carry/wood" if i < 4 else "carry/food")
		prop.rotation_degrees = r
		ba.add_child(prop)
		var label := Label3D.new()
		label.text = "%d: %s" % [i, str(r)]
		label.position = Vector3(float(i) * 1.15, 1.25, 0.5)
		label.pixel_size = 0.004
		label.modulate = Color.BLACK
		root.add_child(label)
	for f in 20:
		await process_frame
	var out := ProjectSettings.globalize_path("res://").path_join("../out/prop_check.png").simplify_path()
	root.get_viewport().get_texture().get_image().save_png(out)
	print("prop_check: saved ", out)
	quit(0)
