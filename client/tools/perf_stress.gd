extends SceneTree
## Stress test: 90 townsfolk that keep walking around the town, with the full scene and HUD.
## Prints the average FPS over 10 seconds (after a 2 second warm-up). Needs a real window:
##   .tools/godot/Godot_v4.7.2-stable_win64_console.exe --path client -s res://tools/perf_stress.gd
## Options after "--": --units=90 --seconds=10 --vsync (keep vsync on; off by default so the
## number is not capped by the monitor's refresh rate).

var _args: PackedStringArray


## Autoload names are not compile-time globals in a -s script, so fetch them from the tree.
func _game() -> Node:
	return root.get_node("Game")


func _initialize() -> void:
	_args = OS.get_cmdline_user_args()
	_run.call_deferred()


func _arg(name: String, fallback: float) -> float:
	for a in _args:
		if a.begins_with("--%s=" % name):
			return float(a.get_slice("=", 1))
	return fallback


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("perf_stress needs a real window: run it without --headless.")
		quit(2)
		return
	var target_units := int(_arg("units", 90))
	var seconds := _arg("seconds", 10.0)
	var vsync := "--vsync" in _args
	DisplayServer.window_set_size(Vector2i(1600, 900))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var main: Variant = load("res://game/main.tscn").instantiate()
	main.autostart = false
	root.add_child(main)
	await process_frame
	var w: SimWorld = _game().new_town(4127, "perf")
	w.allow_debug_commands = true
	var k := w.keep()
	var missing := target_units - w.units.size()
	if missing > 0:
		_game().issue(GameCommands.debug_spawn(missing, k.cell + Vector2i(1, 8), true))
	await process_frame
	await process_frame
	main.camera.input_enabled = false
	main.camera.set_view(Vector3(k.center().x, 0.0, k.center().y + 3.0), 45.0, 0.0)
	main.selection.set_ids(w.units.keys())

	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var orders_every := 3.0
	var next_orders := 0.0
	var warmup := 2.0
	var t := 0.0
	var frames := 0
	var frame_ms: Array[float] = []
	var process_ms := 0.0
	var start_tick := w.tick
	var start_paths := w.path_service.total_served
	var last := Time.get_ticks_usec()
	var measure_start := 0
	while true:
		await process_frame
		var now := Time.get_ticks_usec()
		var dt := float(now - last) / 1000000.0
		last = now
		t += dt
		if t >= next_orders:
			next_orders = t + orders_every
			_orders(w, rng)
		if t < warmup:
			continue
		if frames == 0:
			measure_start = now
			start_tick = w.tick
			start_paths = w.path_service.total_served
		frames += 1
		frame_ms.append(dt * 1000.0)
		process_ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		if float(now - measure_start) / 1000000.0 >= seconds:
			break
	var elapsed := float(Time.get_ticks_usec() - measure_start) / 1000000.0
	frame_ms.sort()
	var p95 := frame_ms[int(frame_ms.size() * 0.95)] if not frame_ms.is_empty() else 0.0
	var worst := frame_ms[frame_ms.size() - 1] if not frame_ms.is_empty() else 0.0
	var moving := 0
	for u: SimUnit in w.units.values():
		if u.job == SimConst.JOB_MOVE:
			moving += 1
	print("PERF units=%d moving_at_end=%d seconds=%.2f frames=%d avg_fps=%.1f p95_frame_ms=%.2f worst_frame_ms=%.2f avg_process_ms=%.2f sim_ticks=%d paths=%d vsync=%s renderer=%s gpu=%s" % [
		w.units.size(), moving, elapsed, frames, float(frames) / elapsed, p95, worst, process_ms / float(maxi(frames, 1)),
		w.tick - start_tick, w.path_service.total_served - start_paths, "on" if vsync else "off",
		RenderingServer.get_current_rendering_method(), RenderingServer.get_video_adapter_name()])
	quit(0)


## Sends every townsperson to a random free cell around the Keep (one command per unit).
func _orders(w: SimWorld, rng: RandomNumberGenerator) -> void:
	var c := w.keep().center()
	for u: SimUnit in w.units.values():
		for attempt in 6:
			var a := rng.randf() * TAU
			var r := rng.randf_range(4.0, 20.0)
			var cell := Vector2i(floori(c.x + cos(a) * r), floori(c.y + sin(a) * r))
			if w.grid.is_walkable(cell):
				_game().issue(GameCommands.move([u.id], cell))
				break
