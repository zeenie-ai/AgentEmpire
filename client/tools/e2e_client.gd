extends SceneTree
## Phase 3 end-to-end check, driven by scripts/e2e-client.mjs, which starts a real Town Hall
## with the scripted fake agent and passes its runtime file in AURELHAVEN_RUNTIME.
##   godot --headless --path client -s res://tools/e2e_client.gd -- --work=<git repo>
## It plays the whole loop through the same code the HUD uses (Game.link):
## connect -> open the Town Hall's town -> summon an Artificer -> it trains at the Keep ->
## choose its plot -> it builds its home and starting add-ons -> send a task by courier ->
## approve the shell command -> the result waits for review -> accept (merge) -> the reward
## arrives; then checks that the treasury matches the Town Hall's ledger and that saving and
## reloading the town gives back the same simulation. Prints "E2E OK" or "E2E FAILED: ...".

const SEED := 4127
const TIME_SCALE := 8.0

var work := ""
var failures: Array[String] = []
var steps: Array[String] = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--work="):
			work = a.substr(7)
	_run.call_deferred()


func _run() -> void:
	if work == "":
		_fail("pass --work=<git repo>")
		_finish()
		return
	await _play()
	_finish()


func _play() -> void:
	var game: Node = root.get_node("/root/Game")
	var net: Node = root.get_node("/root/Net")
	var realm: Node = root.get_node("/root/Realm")
	# Untyped on purpose: a -s script compiles before the autoloads exist, and TownLink uses them.
	var link: Node = game.link

	net.status_changed.connect(func(s: String) -> void: print("e2e: net %s %s" % [s, String(net.get("last_problem"))]))
	net.enable(true)
	if not await _wait(func() -> bool: return net.is_online(), 15.0, "connect to the Town Hall"):
		print("e2e: net status=%s attempts=%d endpoint=%s problem=%s" % [net.status, int(net.get("attempts")),
			JSON.stringify(net.endpoint), String(net.get("last_problem"))])
		return
	_step("connected (%s)" % String(net.endpoint.get("source", "")))
	if not await link.open_online_town(SEED):
		_fail("open the Town Hall's town")
		return
	game.time_scale = TIME_SCALE
	var w: SimWorld = game.world
	_step("town %s opened, %d townsfolk" % [w.town_id, w.unit_count("townsfolk")])

	# Summon an Artificer.
	var spec := {
		"name": "Mira", "provider": "claude", "model": "fake-claude", "role": "artificer",
		"instructions": "Keep changes small.", "approval_mode": "trusted_edits",
		"workspace": {"path": work}, "starting_tools": ["lectern", "quillworks", "forge"],
	}
	var req: NetRequest = link.summon(spec)
	await req.done
	if not req.ok:
		_fail("create_agent: " + req.error_message())
		return
	var agent_id := String(req.payload_dict().get("agent_id", ""))
	_step("summoned %s (free: %s)" % [agent_id, str(req.payload_dict().get("free", false))])
	if not await _wait(func() -> bool: return w.agent_unit(agent_id) != null, 30.0, "agent trained at the Keep"):
		return
	_step("trained")

	# Choose a plot; the agent builds its home, then its starting add-ons.
	var cell := _plot_spot(w, link.home_type(agent_id))
	if cell == Pathing.NO_CELL:
		_fail("no free plot")
		return
	req = link.place_home(agent_id, cell)
	await req.done
	if not req.ok:
		_fail("place_home: " + req.error_message())
		return
	_step("home placed at %s" % cell)
	if not await _wait(func() -> bool: return String(realm.agent(agent_id).get("lifecycle", "")) == "active", 90.0, "agent active (home and required add-ons built)"):
		_dump_agent(realm, w, agent_id)
		return
	_step("active with %d add-ons" % realm.tools_of(agent_id).size())
	if not await _wait(func() -> bool: return realm.tools_of(agent_id).size() >= 3 and w.agent_tools(agent_id).all(func(b: SimBuilding) -> bool: return b.complete), 90.0, "the Forge built too"):
		_dump_agent(realm, w, agent_id)
		return

	# Send a task by courier.
	var before_task := (game.link.ledger as RemoteLedger).treasury()
	req = link.assign_task(agent_id, {"title": "Add a greeting", "prompt": "[fake:e2e_reward] Add a greeting file.", "size": "S"})
	await req.done
	if not req.ok:
		_fail("assign_task: " + req.error_message())
		return
	var task_id := String(req.payload_dict().get("task_id", ""))
	var courier: Dictionary = realm.task(task_id).get("courier", {})
	_step("task %s sent by %s courier" % [task_id, String(courier.get("mode", "?"))])
	if not await _wait(func() -> bool: return String(realm.task(task_id).get("state", "in_transit")) != "in_transit", 60.0, "scroll delivered"):
		return
	_step("delivered")

	# Approve the shell command.
	if not await _wait(func() -> bool: return not realm.approvals_for(agent_id).is_empty(), 30.0, "approval requested"):
		return
	var ap: Dictionary = realm.approvals_for(agent_id)[0]
	_step("approval: %s (%s)" % [String(ap.get("summary", "")), String(ap.get("category", ""))])
	if w.agent_unit(agent_id).activity != "awaiting_approval":
		await _wait(func() -> bool: return w.agent_unit(agent_id).activity == "awaiting_approval", 5.0, "figure waits at the door")
	req = link.respond_approval(String(ap["id"]), "allow", "once")
	await req.done
	if not req.ok:
		_fail("respond_approval: " + req.error_message())
		return
	if not await _wait(func() -> bool: return w.agent_unit(agent_id).work_tool == "forge", 10.0, "figure works at the Forge"):
		return
	_step("working at the Forge")
	if not await _wait(func() -> bool: return String(realm.task(task_id).get("state", "")) == "awaiting_review", 90.0, "result ready for review"):
		return
	_step("awaiting review")

	# Review and accept.
	req = link.task_detail(task_id)
	await req.done
	var files: Array = (req.payload_dict().get("diff", {}) as Dictionary).get("files", [])
	_step("diff: %d file(s)" % files.size())
	req = link.accept_result(task_id, "merge")
	await req.done
	if not req.ok:
		_fail("accept_result: " + req.error_message())
		return
	var rewards: Variant = req.payload_dict().get("rewards")
	if typeof(rewards) != TYPE_DICTIONARY:
		_fail("accept_result gave no rewards: %s" % JSON.stringify(req.payload))
		return
	var paid: Dictionary = (rewards as Dictionary).get("resources", {})
	_step("accepted: %d RP, %s" % [int((rewards as Dictionary).get("rp", 0)), JSON.stringify(paid)])
	if int((rewards as Dictionary).get("rp", 0)) <= 0:
		_fail("zero reward: %s" % JSON.stringify(rewards))

	# The treasury mirror settles on the Town Hall's ledger (paused, so nobody gathers meanwhile).
	game.paused = true
	var ledger: RemoteLedger = game.link.ledger
	ledger.flush()
	await _wait(func() -> bool: return ledger.pending_count() == 0, 10.0, "ledger operations confirmed")
	req = net.request("get_ledger", {"limit": 5})
	await req.done
	var server: Dictionary = req.payload_dict().get("treasury", {})
	var mirror := ledger.treasury()
	for res in ["food", "wood", "stone", "gold"]:
		if int(server.get(res, -1)) != int(mirror.get(res, -2)):
			_fail("treasury %s: client %d, Town Hall %d" % [res, int(mirror.get(res, 0)), int(server.get(res, 0))])
	var gained := 0
	for res: String in paid:
		gained += int(paid[res])
	_step("treasury matches the Town Hall: %s (reward %d, before the task %s)" % [JSON.stringify(mirror), gained, JSON.stringify(before_task)])

	# Save and reload the town.
	req = link.save_now()
	if req == null:
		_fail("save_now refused")
		return
	await req.done
	if not req.ok:
		_fail("save_town: " + req.error_message())
		return
	var saved := _sim_json(game.world)
	if not await link.open_online_town(SEED):
		_fail("reload the town")
		return
	var loaded := _sim_json(game.world)
	if loaded != saved:
		var at := 0
		while at < mini(loaded.length(), saved.length()) and loaded[at] == saved[at]:
			at += 1
		var dir := OS.get_environment("AURELHAVEN_E2E_DIR")
		if dir != "":
			for pair in [["saved.json", saved], ["loaded.json", loaded]]:
				var f := FileAccess.open(dir.path_join(String(pair[0])), FileAccess.WRITE)
				f.store_string(String(pair[1]))
				f.close()
		print("e2e:   saved:  ...%s..." % saved.substr(maxi(at - 160, 0), 320).replace("
", " "))
		print("e2e:   loaded: ...%s..." % loaded.substr(maxi(at - 160, 0), 320).replace("
", " "))
		_fail("the reloaded town differs from the saved one at byte %d" % at)
	else:
		_step("save and reload give the same town (%d bytes)" % saved.length())
	if game.world.agent_home(agent_id) == null or game.world.agent_tools(agent_id).size() < 3:
		_fail("the reloaded town lost the agent's buildings")


## The simulation snapshot without the command queue (reconciliation queues commands on load).
func _sim_json(w: SimWorld) -> String:
	var d := w.to_dict()
	d.erase("pending_commands")
	return JSON.stringify(d, "", true, true)


func _plot_spot(w: SimWorld, type: String) -> Vector2i:
	var c := Vector2i(w.map_center())
	for r in range(5, 18):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var cell := c + Vector2i(dx, dy)
				if bool(Placement.check_plot(w, type, cell)["ok"]):
					return cell
	return Pathing.NO_CELL


func _dump_agent(realm: Node, w: SimWorld, agent_id: String) -> void:
	var a: Dictionary = realm.agent(agent_id)
	print("e2e: agent %s lifecycle=%s activity=%s blocked=%s home=%s" % [agent_id, a.get("lifecycle"), a.get("activity"),
		a.get("blocked_reason"), JSON.stringify(a.get("home"))])
	for t: Dictionary in realm.tools_of(agent_id):
		print("e2e:   tool %s %s %s" % [t.get("id"), t.get("type"), t.get("status")])
	var u := w.agent_unit(agent_id)
	if u != null:
		print("e2e:   figure job=%s phase=%s pos=%s" % [u.job, u.phase, u.pos])
	for b in w.agent_tools(agent_id):
		print("e2e:   site %s complete=%s work=%d" % [b.type, b.complete, b.work])
	var link: Node = root.get_node("/root/Game").link
	print("e2e:   waiting tools: %s" % JSON.stringify(link.get("waiting_tools")))


func _wait(cond: Callable, seconds: float, what: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(cond.call()):
			return true
		await process_frame
	_fail("timed out: " + what)
	return false


func _step(text: String) -> void:
	steps.append(text)
	print("e2e: " + text)


func _fail(text: String) -> void:
	failures.append(text)
	print("e2e: FAILED " + text)


func _finish() -> void:
	if failures.is_empty():
		print("E2E OK (%d steps)" % steps.size())
		quit(0)
	else:
		print("E2E FAILED: " + "; ".join(failures))
		quit(1)
