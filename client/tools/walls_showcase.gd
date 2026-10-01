extends SceneTree
## Screenshots of the town walls, from a real game window (no Town Hall: the ages are set with
## the debug_set_age command). Saves into out/phase5/ at the repository root:
##   walls_age1_opening.png  a new Age I town in the opening view, with the HUD
##   walls_age1.png .. walls_age4.png   towns grown to each age, their walls standing
##   walls_rise.png          the Merchant Ring half way through its rise, close to its east gate
##   walls_rise_overview.png the same rise as the player sees it (the camera framing the ring)
##   walls_gate.png          a close look at a gatehouse with townsfolk passing through
##   walls_plates.png, walls_plates_close.png   agent homes' name plates at the default zoom and
##                           close up (needs fake agents in Realm, set up here)
##   walls_research.png, walls_research_yard.png   the Market Age being researched: the Keep, and
##                           a masons' yard at a gate of the Merchant Ring
## Needs a window, so do not pass --headless:
##   <godot> --path client -s res://tools/walls_showcase.gd
## Options after "--": --out=<dir> --seed=<n> --size=1920x1080 --only=age1,age2,rise,...
##   --quality=low|medium|high

const DEFAULT_SIZE := Vector2i(1920, 1080)
const SEED := 4127

var _args: PackedStringArray
var _size: Vector2i = DEFAULT_SIZE
var _out: String = ""
var main: Variant
var game: Node


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
		printerr("walls_showcase needs a real window: run it without --headless.")
		quit(2)
		return
	var sz := _arg("size", "%dx%d" % [DEFAULT_SIZE.x, DEFAULT_SIZE.y]).split("x")
	_size = Vector2i(int(sz[0]), int(sz[1]))
	_out = _arg("out", ProjectSettings.globalize_path("res://").path_join("../out/phase5").simplify_path())
	DirAccess.make_dir_recursive_absolute(_out)
	await _fix_window()
	game = root.get_node("Game")
	main = load("res://game/main.tscn").instantiate()
	main.autostart = false
	root.add_child(main)
	await process_frame
	var map_seed := int(_arg("seed", str(SEED)))

	if _wanted("age1_opening"):
		var w := _town(map_seed, 1)
		main.hud.visible = true
		game.paused = false
		await _frames(20)
		main.frame_town()
		await _shot("walls_age1_opening", 60)

	for age in range(1, 5):
		if not _wanted("age%d" % age):
			continue
		var w := _town(map_seed, age)
		_grow(w, age)
		main.hud.visible = false
		game.paused = false
		# After the main scene's own opening view (it frames the Keep once the HUD has laid out).
		await _frames(6)
		_overview(w, age)
		await _shot("walls_age%d" % age, 90)

	if _wanted("rise"):
		# As the player sees it: the camera glides out and the Merchant Ring rises round from the
		# south gate.
		var w := _town(map_seed, 1)
		_grow(w, 1)
		main.hud.visible = false
		game.paused = false
		await _seconds(2.0)
		game.issue(GameCommands.debug_set_age(2))
		await _seconds(WallView.LEAD_S + 1.6)
		await _shot("walls_rise_overview", 1)
		await _seconds(6.0)
		# Close up on the front of the rise, at the Merchant Ring's east gate.
		w = _town(map_seed, 1)
		_grow(w, 1)
		game.paused = false
		await _seconds(2.0)
		var g: WallLayout.Piece = w.walls.pieces_of(1, WallLayout.GATE)[5]
		var at := g.center + g.outward * 1.0
		game.issue(GameCommands.debug_set_age(2))
		while w.walls_up < 2:
			await _frames(1)
		await _frames(2)
		main.camera.end_cinema(false)
		# From the field, looking back at the gate as it rises with the town behind it.
		main.camera.set_view(Vector3(at.x, 0.0, at.y), 21.0, atan2(g.outward.x, g.outward.y) + 0.35)
		await _seconds(WallView.LEAD_S + 1.2)
		await _shot("walls_rise", 1)
		await _seconds(6.0)

	if _wanted("gate"):
		var w := _town(map_seed, 2)
		_grow(w, 2)
		main.hud.visible = false
		game.paused = false
		var g: WallLayout.Piece = w.walls.pieces_of(0, WallLayout.GATE)[0]
		_traffic(w, g)
		await _seconds(1.0)
		main.camera.set_view(Vector3(g.center.x - 1.5, 0.0, g.center.y + 1.0), 15.0, deg_to_rad(-24.0))
		await _shot("walls_gate", 140)

	if _wanted("night"):
		var w := _town(map_seed, 3)
		_grow(w, 3)
		main.hud.visible = false
		game.paused = false
		await _frames(6)
		main.world_view.environment_view.set_night(1.0)
		var g: WallLayout.Piece = w.walls.pieces_of(1, WallLayout.GATE)[0]
		main.camera.set_view(Vector3(g.center.x, 0.0, g.center.y - 4.0), 26.0, deg_to_rad(-15.0))
		await _shot("walls_night", 60)
		main.world_view.environment_view.set_night(0.0)

	if _wanted("fps"):
		# Every ring standing and a busy town: frames per second at the default zoom and far out.
		var w := _town(map_seed, 4)
		_grow(w, 4)
		main.hud.visible = true
		game.paused = false
		await _frames(6)
		for view: Array in [[30.0, "default zoom"], [70.0, "farthest zoom"]]:
			main.camera.set_view(Vector3(64.0, 0.0, 70.0), float(view[0]), 0.0)
			await _seconds(1.5)
			var frames := 0
			var start := Time.get_ticks_usec()
			while Time.get_ticks_usec() - start < 3000000:
				await process_frame
				frames += 1
			var fps := float(frames) / (float(Time.get_ticks_usec() - start) / 1000000.0)
			print("fps: %s %.1f (%dx%d)" % [view[1], fps, _size.x, _size.y])

	if _wanted("research"):
		var w := _town(map_seed, 1)
		_grow(w, 1)
		main.hud.visible = true
		game.paused = false
		var started := int(Time.get_unix_time_from_system()) - 38
		main.world_view.research_override = {"target": 2, "duration_ms": 90000,
			"started_at": Time.get_datetime_string_from_unix_time(started) + ".000Z"}
		await _seconds(1.5)
		main.frame_town()
		await _shot("walls_research", 30)
		var g: WallLayout.Piece = w.walls.pieces_of(1, WallLayout.GATE)[0]
		main.hud.visible = false
		main.camera.set_view(Vector3(g.center.x + 1.0, 0.0, g.center.y - 1.5), 17.0, deg_to_rad(-20.0))
		await _shot("walls_research_yard", 30)
		main.world_view.research_override = {}

	if _wanted("plates"):
		var w := _town(map_seed, 2)
		_grow(w, 2)
		var homes := _agents(w)
		main.hud.visible = true
		game.paused = false
		await _seconds(1.0)
		if homes.is_empty():
			printerr("walls_showcase: no room for the agents' plots")
			quit(1)
			return
		var h: SimBuilding = homes[0]
		main.camera.set_view(Vector3(h.center().x + 2.5, 0.0, h.center().y + 1.5), 30.0, deg_to_rad(-12.0))
		main.camera.focus(Vector3(h.center().x + 3.0, 0.0, h.center().y), true)
		await _shot("walls_plates", 60)
		main.hud.visible = false
		main.camera.set_view(Vector3(h.center().x, 0.0, h.center().y + 1.5), 11.0, deg_to_rad(-18.0))
		await _shot("walls_plates_close", 40)
	quit(0)


## A fresh offline town at `age` (its walls standing), paused.
func _town(map_seed: int, age: int) -> SimWorld:
	game.paused = true
	var w: SimWorld = game.new_town(map_seed, "walls-%d" % age)
	w.allow_debug_commands = true
	main.camera.input_enabled = false
	main.selection.clear()
	if age > 1:
		w.commands.push(GameCommands.debug_set_age(age))
		w.step(1)
	return w


## Grows the town as far as `age` allows: cottages, farms and storehouses inside the build
## zone (a few more each age), more townsfolk, and a while of simulated work.
func _grow(w: SimWorld, age: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 991 + age
	var k := w.keep()
	w.commands.push(GameCommands.debug_spawn(6 + age * 5, k.cell + Vector2i(1, 7)))
	w.step(1)
	var radii := w.econ.ring_radii()
	var plan := {1: [7, 2, 1], 2: [16, 4, 2], 3: [26, 7, 3], 4: [36, 9, 4]}
	var counts: Array = plan[age]
	var types := ["cottage", "farm", "storehouse"]
	for t in 3:
		var placed := 0
		var tries := 0
		while placed < int(counts[t]) and tries < 900:
			tries += 1
			var outer := float(radii[mini(age, radii.size() - 1)]) - 3.0
			var r := rng.randf_range(5.5, outer)
			var a := rng.randf() * TAU
			var cell := Vector2i(w.map_center() + Vector2(cos(a), sin(a)) * r)
			var type: String = types[t]
			if bool(Placement.check(w, type, cell, false)["ok"]):
				w.add_building(type, cell, true, "")
				placed += 1
	w.step(int(w.tick_rate * 20))


## Frames every standing ring from high up, slightly turned.
func _overview(w: SimWorld, age: int) -> void:
	var r := float(w.econ.ring_radii()[mini(age, 4) - 1])
	var c := w.map_center()
	var pts := PackedVector3Array()
	for i in 24:
		var a := TAU * float(i) / 24.0
		var p := Vector3(c.x + cos(a) * (r + 1.5), 0.0, c.y + sin(a) * (r + 1.5))
		pts.append(p)
		pts.append(p + Vector3.UP * 4.5)
	pts.append(Vector3(c.x, 7.0, c.y))
	main.camera.frame(pts, 26.0 + r * 0.8, 0.02, true, 150.0, deg_to_rad(-16.0))


## Sends townsfolk back and forth through gate `g`.
func _traffic(w: SimWorld, g: WallLayout.Piece) -> void:
	var outside := Pathing.cell_of(g.center + g.outward * 5.0)
	var inside := Pathing.cell_of(g.center - g.outward * 5.0)
	var n := 0
	for u: SimUnit in w.units.values():
		if u.kind != "townsfolk" or n >= 6:
			continue
		w.commands.push(GameCommands.move([u.id], outside if n % 2 == 0 else inside))
		n += 1
	w.step(1)


## Two agents with homes and add-ons, and Realm entries so their homes show name plates.
func _agents(w: SimWorld) -> Array[SimBuilding]:
	var realm := root.get_node("Realm")
	var agents := [
		{"id": "a1", "name": "Mira", "role": "artificer", "rank": "F", "activity": "working", "lifecycle": "active", "created_at": "2026-09-30T10:00:00.000Z"},
		{"id": "a2", "name": "Odo", "role": "scribe", "rank": "E", "activity": "idle", "lifecycle": "active", "created_at": "2026-09-30T10:01:00.000Z"},
	]
	var approvals := [{"id": "ap1", "agent_id": "a1", "status": "pending", "summary": "Run: npm test", "tool": "Bash",
		"category": "command", "risk": "medium", "input_preview": "{\"command\": \"npm test\"}", "created_at": "2026-09-30T10:05:00.000Z"}]
	realm.call("apply_state", {"agents": agents, "approvals": approvals, "tools": [], "tasks": [], "age": {"current": w.age, "research": null}})
	var homes: Array[SimBuilding] = []
	var c := w.map_center()
	var spots := [Vector2i(c + Vector2(cos(2.55), sin(2.55)) * 16.0), Vector2i(c + Vector2(cos(0.35), sin(0.35)) * 16.0)]
	for i in agents.size():
		var a: Dictionary = agents[i]
		var home_type := w.econ.role_home(String(a["role"]))
		var cell := _plot_near(w, home_type, spots[i])
		if cell == Pathing.NO_CELL:
			continue
		w.commands.push(GameCommands.spawn_agent(String(a["id"]), String(a["role"]), cell + Vector2i(1, 4)))
		w.commands.push(GameCommands.place_home(String(a["id"]), home_type, cell, true))
		w.step(1)
		var home := w.agent_home(String(a["id"]))
		homes.append(home)
		var tools := ["lectern", "quillworks", "forge"]
		for j in tools.size():
			var taken: Array[Rect2i] = []
			for t in w.agent_tools(String(a["id"])):
				taken.append(t.rect())
			var tc := HomeLayout.tool_cell(home.plot, w.econ.building_footprint(tools[j]), taken)
			if tc != Pathing.NO_CELL:
				w.commands.push(GameCommands.place_tool(String(a["id"]), "%s-t%d" % [a["id"], j], tools[j], tc, true))
				w.step(1)
	return homes


func _plot_near(w: SimWorld, home_type: String, near: Vector2i) -> Vector2i:
	for r in range(0, 14):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var cell := near + Vector2i(dx, dy)
				if bool(Placement.check_plot(w, home_type, cell)["ok"]):
					return cell
	return Pathing.NO_CELL


func _fix_window() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(_size)
	for i in 3:
		await process_frame


func _frames(n: int) -> void:
	for i in n:
		_hold_window()
		await process_frame


func _seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		_hold_window()
		await process_frame


func _shot(name: String, frames: int) -> void:
	var img: Image = null
	for attempt in 4:
		await _frames(frames)
		img = root.get_viewport().get_texture().get_image()
		if img.get_size() == _size:
			break
		frames = 12
	var path := _out.path_join(name + ".png")
	var err := img.save_png(path)
	print("capture: %s %dx%d %s" % [path, img.get_width(), img.get_height(), "ok" if err == OK else "error %d" % err])


## The OS sometimes maximises the window mid-run; put it back to the capture size.
func _hold_window() -> void:
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if DisplayServer.window_get_size() != _size:
		DisplayServer.window_set_size(_size)
