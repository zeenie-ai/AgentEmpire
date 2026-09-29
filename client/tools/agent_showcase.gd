extends SceneTree
## Screenshots of agents living in the town, from a real game window talking to a real Town
## Hall (start one with the scripted fake agent and pass its runtime file):
##   AURELHAVEN_RUNTIME=<data>/runtime.json <godot> --path client -s res://tools/agent_showcase.gd -- --work=<git repo>
## Saves to out/ (repo root): agents_homes, agents_courier, agents_approval, agents_forge,
## agents_review, agents_wisp and agents_hud (.png). Needs a window, so no --headless.
## Options after "--": --work=<folder the Town Hall allows> --size=1600x900 --out=<dir>

const DEFAULT_SIZE := Vector2i(1600, 900)
const SEED := 4127
const TIME_SCALE := 6.0

var _args: PackedStringArray
var _size: Vector2i = DEFAULT_SIZE
var _out: String = ""
var main: Variant
var game: Node
var link: Node
var realm: Node


func _initialize() -> void:
	_args = OS.get_cmdline_user_args()
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	for a in _args:
		if a.begins_with("--%s=" % name):
			return a.get_slice("=", 1)
	return fallback


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("agent_showcase needs a real window: run it without --headless.")
		quit(2)
		return
	var sz := _arg("size", "%dx%d" % [DEFAULT_SIZE.x, DEFAULT_SIZE.y]).split("x")
	_size = Vector2i(int(sz[0]), int(sz[1]))
	_out = _arg("out", ProjectSettings.globalize_path("res://").path_join("../out").simplify_path())
	DirAccess.make_dir_recursive_absolute(_out)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(_size)
	var ok: bool = await _play()
	print("showcase: " + ("done" if ok else "FAILED"))
	quit(0 if ok else 1)


func _play() -> bool:
	game = root.get_node("Game")
	realm = root.get_node("Realm")
	var net: Node = root.get_node("Net")
	main = load("res://game/main.tscn").instantiate()
	main.autostart = false
	root.add_child(main)
	await process_frame
	link = game.link
	net.enable(true)
	if not await _wait(func() -> bool: return net.is_online(), 15.0, "Town Hall"):
		return false
	if not await link.open_online_town(SEED):
		return false
	game.time_scale = TIME_SCALE
	main.camera.input_enabled = false
	var w: SimWorld = game.world
	var work := _arg("work", "")

	var mira := await _summon("Mira", "claude", "artificer", work, ["lectern", "quillworks", "forge"])
	var odo := await _summon("Odo", "codex", "scribe", work, ["lectern", "quillworks"])
	if mira == "" or odo == "":
		return false
	if not await _wait(func() -> bool: return w.agent_unit(mira) != null and w.agent_unit(odo) != null, 60.0, "trained"):
		return false
	var k := w.keep()
	var spot_a := _plot(w, link.home_type(mira), Vector2i(k.center()) + Vector2i(8, -2))
	var req: NetRequest = link.place_home(mira, spot_a)
	await req.done
	var spot_b := _plot(w, link.home_type(odo), Vector2i(k.center()) + Vector2i(-9, 1))
	req = link.place_home(odo, spot_b)
	await req.done
	if not await _wait(func() -> bool: return _settled(w, mira, 3) and _settled(w, odo, 2), 240.0, "homes and add-ons"):
		_dump(w, [mira, odo])
		return false
	var mid := (Vector2(spot_a) + Vector2(spot_b)) * 0.5 + Vector2(1.5, 1.5)
	main.hud.visible = false
	main.camera.set_view(Vector3(mid.x, 0.0, mid.y + 2.0), 30.0, deg_to_rad(-18.0))
	await _shot("agents_homes", 40)

	# A task: a townsperson fetches the scroll at the Keep and carries it to Mira's home.
	req = link.assign_task(mira, {"title": "Add a greeting", "prompt": "[fake:e2e_reward] Add a greeting file.", "size": "S"})
	await req.done
	var task_id := J.gs(req.payload_dict(), "task_id")
	game.time_scale = 2.0
	await _wait(func() -> bool: return _courier(w) != null and CourierJob.carrying_scroll(_courier(w)), 20.0, "courier with the scroll")
	var c: SimUnit = _courier(w)
	if c != null:
		main.camera.set_view(Vector3(c.pos.x, 0.0, c.pos.y + 1.0), 12.0, deg_to_rad(-25.0))
		await _shot("agents_courier", 30)
	game.time_scale = TIME_SCALE

	# The approval: the bell rings over the home, Mira waits at the door.
	if not await _wait(func() -> bool: return not realm.approvals_for(mira).is_empty(), 60.0, "approval"):
		return false
	await _wait(func() -> bool: return AgentJob.at_spot(w.agent_unit(mira)), 10.0, "Mira at the door")
	var home_a := w.agent_home(mira)
	main.hud.visible = true
	main.selection.set_ids([home_a.id])
	main.camera.set_view(Vector3(home_a.center().x, 0.0, home_a.center().y + 1.5), 16.0, deg_to_rad(-22.0))
	await _shot("agents_approval", 40)

	# Approved: Mira hammers at the Forge.
	var ap: Dictionary = realm.approvals_for(mira)[0]
	req = link.respond_approval(J.gs(ap, "id"), "allow", "once")
	await req.done
	await _wait(func() -> bool: return AgentJob.at_spot(w.agent_unit(mira)) and w.agent_unit(mira).work_tool == "forge", 15.0, "Mira at the Forge")
	main.hud.visible = false
	main.selection.clear()
	var forge := AgentJob.tool_of_type(w, mira, "forge")
	if forge != null:
		main.camera.set_view(Vector3(forge.center().x, 0.0, forge.center().y + 0.5), 10.0, deg_to_rad(-30.0))
	await _shot("agents_forge", 50)

	# The result waits for review: a chest glows at the door.
	if not await _wait(func() -> bool: return J.gs(realm.task(task_id), "state") == "awaiting_review", 90.0, "review"):
		return false
	main.camera.set_view(Vector3(home_a.center().x, 0.0, home_a.center().y + 1.5), 13.0, deg_to_rad(-15.0))
	await _shot("agents_review", 40)

	# A Font Wisp flying a scroll to Odo's home.
	var home_b := w.agent_home(odo)
	game.issue(GameCommands.wisp(home_b.id, "tsk_showcase", odo, 0))
	game.time_scale = 1.0
	await _wait(func() -> bool: return not w.wisps.is_empty(), 3.0, "wisp")
	for i in 30:
		await process_frame
	if not w.wisps.is_empty():
		var p: Vector2 = w.wisps[0]["pos"]
		main.camera.set_view(Vector3(p.x, 0.0, p.y + 1.0), 14.0, deg_to_rad(-20.0))
		await _shot("agents_wisp", 8)
	game.time_scale = TIME_SCALE

	# The game screen: Mira's home selected, her card and panel in the HUD.
	main.hud.visible = true
	main.selection.set_ids([home_a.id])
	main.camera.set_view(Vector3(home_a.center().x, 0.0, home_a.center().y + 2.0), 26.0, deg_to_rad(-18.0))
	await _shot("agents_hud", 40)
	return true


func _summon(name: String, provider: String, role: String, work: String, tools: Array) -> String:
	var spec := {"name": name, "provider": provider, "model": "fake-" + provider, "role": role,
		"instructions": "Keep changes small.", "approval_mode": "trusted_edits", "workspace": {"path": work},
		"starting_tools": tools}
	var req: NetRequest = link.summon(spec)
	await req.done
	if not req.ok:
		printerr("showcase: summon %s failed: %s" % [name, req.error_message()])
		return ""
	return J.gs(req.payload_dict(), "agent_id")


func _dump(w: SimWorld, ids: Array) -> void:
	print("showcase: treasury %s" % JSON.stringify(root.get_node("Economy").ledger.treasury()))
	for id: String in ids:
		var a: Dictionary = realm.agent(id)
		print("showcase: %s lifecycle=%s activity=%s blocked=%s home=%s tools=%d waiting=%s" % [J.gs(a, "name"), J.gs(a, "lifecycle"),
			J.gs(a, "activity"), J.gs(a, "blocked_reason"), JSON.stringify(a.get("home")), realm.tools_of(id).size(),
			JSON.stringify(link.waiting_tools.get(id, {}))])
		var u := w.agent_unit(id)
		if u != null:
			print("showcase:   figure job=%s phase=%s at %s" % [u.job, u.phase, u.pos])
		for b in w.agent_tools(id):
			print("showcase:   %s complete=%s" % [b.type, b.complete])


func _settled(w: SimWorld, agent_id: String, tools: int) -> bool:
	var home := w.agent_home(agent_id)
	if home == null or not home.complete or w.agent_tools(agent_id).size() < tools:
		return false
	for t in w.agent_tools(agent_id):
		if not t.complete:
			return false
	return true


func _courier(w: SimWorld) -> SimUnit:
	for u: SimUnit in w.units.values():
		if u.job == SimConst.JOB_COURIER:
			return u
	return null


## The valid plot nearest to `near`.
func _plot(w: SimWorld, type: String, near: Vector2i) -> Vector2i:
	for r in range(0, 14):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var cell := near + Vector2i(dx, dy)
				if bool(Placement.check_plot(w, type, cell)["ok"]):
					return cell
	return near


func _wait(cond: Callable, seconds: float, what: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(cond.call()):
			return true
		_hold_window()
		await process_frame
	printerr("showcase: timed out waiting for " + what)
	return false


func _shot(name: String, frames: int) -> void:
	var img: Image = null
	for attempt in 4:
		for i in frames:
			_hold_window()
			await process_frame
		img = root.get_viewport().get_texture().get_image()
		if img.get_size() == _size:
			break
		frames = 12
	var path := _out.path_join(name + ".png")
	var err := img.save_png(path)
	print("capture: %s %dx%d %s" % [path, img.get_width(), img.get_height(), "ok" if err == OK else "error %d" % err])


func _hold_window() -> void:
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if DisplayServer.window_get_size() != _size:
		DisplayServer.window_set_size(_size)
