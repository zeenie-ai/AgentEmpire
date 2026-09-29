extends SceneTree
## Diagnostic: renders every character GLB side by side while playing an animation, saves
## out/char_check.png and prints each character's skeleton, animation list and posed height.
##   .tools/godot/Godot_v4.7.2-stable_win64_console.exe --path client -s res://tools/char_check.gd

const IDS := ["townsfolk_a", "townsfolk_b", "townsfolk_c", "townsfolk_d",
	"agent_artificer", "agent_scholar", "agent_scribe", "agent_warden", "agent_herald"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 700))
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.62, 0.5)
	env.environment.ambient_light_color = Color(1, 1, 1)
	env.environment.ambient_light_energy = 0.6
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	world.add_child(sun)
	var cam := Camera3D.new()
	cam.position = Vector3(4.0, 1.4, 6.5)
	cam.look_at_from_position(cam.position, Vector3(4.0, 0.5, 0), Vector3.UP)
	cam.fov = 35
	world.add_child(cam)
	cam.current = true

	var players: Array[AnimationPlayer] = []
	for i in IDS.size():
		var path := "res://art/characters/%s.glb" % IDS[i]
		var scene := load(path) as PackedScene
		if scene == null:
			print("char: %s FAILED TO LOAD" % IDS[i])
			continue
		var inst := scene.instantiate() as Node3D
		inst.position = Vector3(i * 1.0, 0, 0)
		world.add_child(inst)
		var skel := inst.find_children("*", "Skeleton3D", true, false)
		var ap := inst.find_children("*", "AnimationPlayer", true, false)
		var meshes := inst.find_children("*", "MeshInstance3D", true, false)
		var anims: PackedStringArray = []
		if ap.size() > 0:
			var p := ap[0] as AnimationPlayer
			anims = p.get_animation_list()
			var clip := "Walking_A" if p.has_animation("Walking_A") else (anims[0] if anims.size() > 0 else "")
			if clip != "":
				p.play(clip)
				players.append(p)
		print("char: %s skeletons %d bones %d meshes %d anims %d [%s]" % [IDS[i], skel.size(),
			(skel[0] as Skeleton3D).get_bone_count() if skel.size() > 0 else 0, meshes.size(), anims.size(), ", ".join(anims)])
	for f in 45:
		await process_frame
	# Posed height: highest global bone position per character.
	for c in world.get_children():
		var sk := c.find_children("*", "Skeleton3D", true, false)
		if sk.is_empty():
			continue
		var s := sk[0] as Skeleton3D
		var top := -INF
		for b in s.get_bone_count():
			top = maxf(top, (s.global_transform * s.get_bone_global_pose(b)).origin.y)
		print("char: %s posed top bone y=%.2f" % [c.name, top])
	var out := ProjectSettings.globalize_path("res://").path_join("../out")
	DirAccess.make_dir_recursive_absolute(out)
	root.get_viewport().get_texture().get_image().save_png(out.path_join("char_check.png"))
	print("char: saved %s" % out.path_join("char_check.png"))
	quit(0)
