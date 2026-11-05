extends GutTest
## The Rive state tracker in the client: the baked sheets (RiveSprites, from
## scripts/bake-rive.mjs), the RiveSprite that plays them, the task tracker in the HUD, and the
## agent sigils on the agent panel and the home name plates. Realm holds AgentUiDemo's state:
## Mira works on "Fix the login redirect loop" with "Add tests" queued and two petitions waiting,
## and Corvin's "Document the town save format" waits for review.

const Protocol = preload("res://net/protocol.gd")
const MOODS := ["idle", "training", "settling", "working", "waiting", "review", "blocked", "retired"]


## Stands in for TownLink's waiting_tools: add-ons waiting for resources, by agent.
class WaitLink:
	extends RefCounted
	var waiting_tools: Dictionary = {}


var now: float = 100.0


func before_each() -> void:
	now = 100.0
	Realm.apply_state(AgentUiDemo.state())


func after_each() -> void:
	Realm.clear()
	await wait_process_frames(2)


func _task_event(id: String, state: String, extra: Dictionary = {}) -> void:
	var t: Dictionary = Realm.task(id).duplicate(true)
	t["state"] = state
	t.merge(extra, true)
	Realm.apply_event({"type": Protocol.EVT_TASK_UPDATED, "payload": {"task": t}})


func _new_task(id: String, state: String, created: String, extra: Dictionary = {}) -> void:
	var t := AgentUiDemo.task_tests()
	t["id"] = id
	t["title"] = "Task %s" % id
	t["state"] = state
	t["created_at"] = created
	t.merge(extra, true)
	Realm.apply_event({"type": Protocol.EVT_TASK_UPDATED, "payload": {"task": t}})


func _agent_event(id: String, extra: Dictionary) -> void:
	var a: Dictionary = Realm.agent(id).duplicate(true)
	a.merge(extra, true)
	Realm.apply_event({"type": Protocol.EVT_AGENT_UPDATED, "payload": {"agent": a}})


func _status(agent_id: String, link: Object = null) -> Dictionary:
	return AgentUi.agent_status(Realm.agent(agent_id), link)


## Agent `agent_id`'s home, its name plate on `layer`.
func _home(agent_id: String, layer: Control, link: Object = null) -> HomeStatusView:
	var b := SimBuilding.new()
	b.id = 900 + layer.get_child_count()
	b.owner_agent_id = agent_id
	b.cell = Vector2i(10, 10)
	b.size = Vector2i(3, 3)
	var home := HomeStatusView.new()
	home.link = link
	add_child_autofree(home)
	home.setup(b, 2.0, Vector3.ZERO, layer)
	return home


func _tracker() -> TaskTracker:
	var host := Control.new()
	host.size = Vector2(1600, 900)
	add_child_autofree(host)
	var tr := TaskTracker.new()
	tr.clock = func() -> float: return now
	# The test's town stands in for the Town Hall's.
	tr.online = func() -> bool: return true
	# Not the player's saved fold.
	tr.folded = false
	host.add_child(tr)
	return tr


## The rows listed, top to bottom; rows fading out are not.
func _ids(tr: TaskTracker) -> Array[String]:
	var out: Array[String] = []
	for c in tr.get_children():
		var row := c as TaskTracker.TrackerRow
		if row != null and not row.leaving and not row.is_queued_for_deletion():
			out.append(row.task_id)
	return out


## A left click let go in the middle of `c` (laid out first).
func _click(c: Control) -> void:
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = c.size * 0.5
	c._gui_input(up)


# --- the baked sheets ---------------------------------------------------------------------------

func test_every_task_state_has_a_seal() -> void:
	assert_true(RiveSprites.has_set("task_seal"))
	for s: String in Protocol.TaskState.ALL:
		assert_true(RiveSprites.has_state("task_seal", s), "a seal for %s" % s)


func test_every_mood_has_a_sigil() -> void:
	assert_true(RiveSprites.has_set("agent_sigil"))
	for m: String in MOODS:
		assert_true(RiveSprites.has_state("agent_sigil", m), "a sigil for %s" % m)


func test_sheets_load_and_match_the_manifest() -> void:
	for set_name: String in ["task_seal", "agent_sigil"]:
		for s in RiveSprites.states(set_name):
			var sh := RiveSprites.sheet(set_name, s)
			assert_false(sh.is_empty(), "%s %s loads" % [set_name, s])
			if sh.is_empty():
				continue
			var tex: Texture2D = sh["texture"]
			var frames: int = sh["frames"]
			var columns: int = sh["columns"]
			var size: Vector2 = sh["size"]
			var cell := size + Vector2.ONE * 2.0 * float(sh["pad"])
			var rows := ceili(float(frames) / float(columns))
			assert_eq(Vector2(tex.get_size()), Vector2(cell.x * columns, cell.y * rows), "%s %s sheet size" % [set_name, s])
			var last := RiveSprites.frame_rect(sh, frames - 1)
			assert_true(Rect2(Vector2.ZERO, Vector2(tex.get_size())).encloses(last), "%s %s last frame inside" % [set_name, s])


func test_an_unknown_state_falls_back() -> void:
	assert_eq(String(RiveSprites.sheet("task_seal", "no_such_state")["state"]), "queued")
	assert_eq(String(RiveSprites.sheet("agent_sigil", "")["state"]), "idle")
	assert_true(RiveSprites.sheet("no_such_set", "idle").is_empty())


func test_frames_walk_the_grid_and_wrap() -> void:
	var sh := {"frames": 5, "columns": 3, "size": Vector2(10, 10), "pad": 2.0, "fps": 10.0}
	assert_eq(RiveSprites.frame_rect(sh, 0), Rect2(2, 2, 10, 10))
	assert_eq(RiveSprites.frame_rect(sh, 2), Rect2(30, 2, 10, 10))
	assert_eq(RiveSprites.frame_rect(sh, 3), Rect2(2, 16, 10, 10))
	assert_eq(RiveSprites.frame_rect(sh, 5), Rect2(2, 2, 10, 10), "wraps to the first frame")
	assert_eq(RiveSprites.frame_at(sh, 0.0), 0)
	assert_eq(RiveSprites.frame_at(sh, 0.35), 3)
	assert_eq(RiveSprites.frame_at(sh, 0.55), 0, "the loop starts again")


# --- RiveSprite ------------------------------------------------------------------------------------

func test_sprite_plays_its_loop() -> void:
	var sp := RiveSprite.new("task_seal", "running", 40.0)
	add_child_autofree(sp)
	sp._process(0.0)
	var first := sp.current_frame()
	sp._process(0.25)
	assert_ne(sp.current_frame(), first, "the hammer moves")


func test_sprite_fades_into_a_new_state() -> void:
	var sp := RiveSprite.new("task_seal", "running", 40.0)
	add_child_autofree(sp)
	await wait_process_frames(2)
	assert_false(sp.is_changing())
	sp.set_state("awaiting_approval")
	assert_eq(sp.state, "awaiting_approval")
	assert_true(sp.is_changing(), "fades and pops")
	sp._process(0.1)
	assert_true(sp.is_changing())
	sp._process(0.5)
	assert_false(sp.is_changing(), "settled")
	sp.set_state("failed", false)
	assert_false(sp.is_changing(), "a cut does not fade")
	sp.set_state("failed")
	assert_false(sp.is_changing(), "the same state again changes nothing")


func test_a_new_sprite_shows_its_first_state_at_once() -> void:
	var sp := RiveSprite.new("agent_sigil", "idle", 32.0)
	add_child_autofree(sp)
	sp.set_state("working")
	assert_false(sp.is_changing(), "idle was never on screen: nothing fades from it")
	await wait_process_frames(2)
	sp.set_state("review")
	assert_true(sp.is_changing(), "a state the player saw fades out")


func test_a_change_mid_fade_keeps_the_sheet_that_shows_more() -> void:
	var sp := RiveSprite.new("task_seal", "running", 40.0)
	add_child_autofree(sp)
	await wait_process_frames(2)
	sp.set_state("awaiting_approval")
	sp._process(0.04)
	sp.set_state("failed")
	assert_eq(String(sp._old.get("state", "")), "running", "early in the fade the old sheet still shows most")
	sp._process(0.15)
	sp.set_state("paused")
	assert_eq(String(sp._old.get("state", "")), "failed", "late in the fade the new sheet does")


# --- the task tracker --------------------------------------------------------------------------------

func test_tracker_lists_live_tasks_by_need() -> void:
	var tr := _tracker()
	assert_true(tr.visible)
	assert_eq(_ids(tr), ["tsk_docs", "tsk_login", "tsk_tests"] as Array[String], "review, then work, then the queue")
	for id in _ids(tr):
		assert_eq(tr.row_for(id).seal.state, J.gs(Realm.task(id), "state"), "%s shows its state's seal" % id)
	var docs := tr.row_for("tsk_docs")
	assert_string_contains(docs.sub.text, "CORVIN")
	assert_string_contains(docs.sub.text, "READY FOR REVIEW")
	assert_string_contains(tr._header_label.text, "3")


func test_tracker_follows_a_state_change() -> void:
	var tr := _tracker()
	await wait_process_frames(2)
	_task_event("tsk_login", Protocol.TaskState.AWAITING_APPROVAL)
	var row := tr.row_for("tsk_login")
	assert_eq(row.seal.state, "awaiting_approval")
	assert_true(row.seal.is_changing(), "the seal fades into the bell")
	assert_eq(_ids(tr)[0], "tsk_login", "a petition goes to the top")
	assert_string_contains(row.sub.text, "WAITING FOR APPROVAL")


func test_tracker_clicks_ask_for_what_the_task_needs() -> void:
	var tr := _tracker()
	await wait_process_frames(2)
	watch_signals(tr)
	_click(tr.row_for("tsk_docs"))
	assert_signal_emitted_with_parameters(tr, "review_requested", ["tsk_docs"])
	_click(tr.row_for("tsk_tests"))
	assert_signal_emitted_with_parameters(tr, "focus_requested", ["agt_mira"])
	_task_event("tsk_login", Protocol.TaskState.AWAITING_APPROVAL)
	_click(tr.row_for("tsk_login"))
	assert_signal_emitted_with_parameters(tr, "approvals_requested", ["agt_mira"])


func test_a_finished_task_lingers_then_goes() -> void:
	var tr := _tracker()
	_task_event("tsk_docs", Protocol.TaskState.ACCEPTED)
	assert_eq(_ids(tr)[0], "tsk_docs", "stays, on top, with its final seal")
	var docs := tr.row_for("tsk_docs")
	assert_eq(docs.seal.state, "accepted")
	assert_string_contains(tr._header_label.text, "2", "only live tasks are counted")
	now += TaskTracker.LINGER_S - 1.0
	tr._process(0.0)
	assert_true("tsk_docs" in _ids(tr))
	now += 2.0
	tr._process(0.0)
	assert_false("tsk_docs" in _ids(tr), "gone after LINGER_S")
	assert_eq(_ids(tr), ["tsk_login", "tsk_tests"] as Array[String])
	assert_true(docs.leaving and docs.top_level, "fades where it stood, out of the list's layout")
	watch_signals(tr)
	_click(docs)
	assert_signal_not_emitted(tr, "focus_requested", "a fading row takes clicks and does nothing")


func test_a_press_dragged_off_a_row_or_the_header_does_nothing() -> void:
	var tr := _tracker()
	await wait_process_frames(2)
	watch_signals(tr)
	var row := tr.row_for("tsk_docs")
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = row.size + Vector2(40, 40)
	row._gui_input(up)
	assert_signal_not_emitted(tr, "review_requested", "let go outside the row")
	tr._on_header_input(up)
	assert_false(tr.folded, "let go outside the header")
	_click(row)
	assert_signal_emitted_with_parameters(tr, "review_requested", ["tsk_docs"])


func test_a_finished_task_shows_first_when_the_list_is_full() -> void:
	for i in 4:
		_new_task("tsk_extra%d" % i, Protocol.TaskState.IN_TRANSIT, "2026-02-0%dT00:00:00Z" % (i + 1))
	var tr := _tracker()
	assert_eq(_ids(tr).size(), TaskTracker.MAX_ROWS)
	_task_event("tsk_docs", Protocol.TaskState.ACCEPTED)
	assert_eq(_ids(tr)[0], "tsk_docs", "the final seal is on show")
	assert_eq(_ids(tr).size(), TaskTracker.MAX_ROWS)
	assert_string_contains(tr._header_label.text, "6", "six live tasks")
	assert_string_contains(tr._more_label.text, "2 MORE TASKS", "the live ones that do not fit")


func test_tracker_shows_only_in_the_town_halls_town() -> void:
	var tr := _tracker()
	var up := [false]
	tr.online = func() -> bool: return bool(up[0])
	tr.sync()
	assert_false(tr.visible, "an offline town, after the Town Hall closed")
	up[0] = true
	tr.sync()
	assert_true(tr.visible)


func test_the_fold_is_a_setting_that_loads() -> void:
	assert_true(Settings.DEFAULTS.has(TaskTracker.FOLD_SETTING), "Settings loads only the keys it knows")
	assert_eq(Settings.DEFAULTS[TaskTracker.FOLD_SETTING], false)


func test_tasks_already_over_and_sub_tasks_are_left_out() -> void:
	_new_task("tsk_old", Protocol.TaskState.ACCEPTED, "2026-01-01T00:00:00Z")
	_new_task("tsk_sub", Protocol.TaskState.RUNNING, "2026-01-01T00:00:00Z", {"parent_task_id": "tsk_login"})
	var tr := _tracker()
	assert_false("tsk_old" in _ids(tr), "a task that ended before the tracker saw it")
	assert_false("tsk_sub" in _ids(tr), "a party member's sub-task")


func test_tracker_shows_at_most_max_rows() -> void:
	for i in 6:
		_new_task("tsk_extra%d" % i, Protocol.TaskState.IN_TRANSIT, "2026-02-0%dT00:00:00Z" % (i + 1))
	var tr := _tracker()
	assert_eq(_ids(tr).size(), TaskTracker.MAX_ROWS)
	assert_true(tr._more.visible)
	assert_string_contains(tr._more_label.text, "4 MORE TASKS")
	assert_string_contains(tr._header_label.text, "9")


func test_tracker_folds_and_hides() -> void:
	var tr := _tracker()
	tr.folded = true
	tr.sync()
	assert_eq(_ids(tr).size(), 0, "folded: only the header")
	assert_true(tr.visible)
	tr.folded = false
	tr.sync()
	tr.enabled = false
	assert_false(tr.visible, "the HUD turned it off")
	tr.enabled = true
	Realm.clear()
	Realm.reset.emit()
	assert_false(tr.visible, "nothing to track")


func test_hud_places_the_tracker_under_the_top_bar() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1600, 900)
	add_child_autofree(sv)
	var hud := Hud.new()
	sv.add_child(hud)
	await wait_process_frames(3)
	hud.use_layout(Hud.Layout.DESKTOP, true)
	hud.tracker.online = func() -> bool: return true
	hud.tracker.folded = false
	hud.tracker.sync()
	await wait_process_frames(3)
	var tr := hud.tracker
	assert_true(tr.visible)
	var r := tr.get_global_rect()
	assert_gte(r.position.y, hud.top_bar.get_global_rect().end.y, "under the top bar")
	assert_lt(r.position.x, 40.0, "at the left")
	assert_false(r.intersects(hud.approval_tray.get_global_rect()), "clear of the petitions")
	assert_lt(r.end.y, hud.bottom.get_global_rect().position.y, "above the bottom panel")
	hud.use_layout(Hud.Layout.PHONE, true)
	assert_false(tr.visible, "not on phones")
	hud.use_layout(Hud.Layout.DESKTOP, false)
	assert_false(tr.visible, "not without a Town Hall")


# --- the agent sigils -----------------------------------------------------------------------------

func test_agent_panel_shows_the_mood_sigil() -> void:
	var host := Control.new()
	add_child_autofree(host)
	var mira := AgentPanel.new()
	host.add_child(mira)
	mira.setup("agt_mira")
	assert_eq(mira._status_sigil.state, "waiting", "Mira's petitions come before her work")
	var corvin := AgentPanel.new()
	host.add_child(corvin)
	corvin.setup("agt_corvin")
	assert_eq(corvin._status_sigil.state, "review", "Corvin's result waits")


func test_what_needs_you_comes_before_the_work() -> void:
	assert_eq(_status("agt_mira")["mood"], "waiting", "two petitions before her work")
	assert_eq(_status("agt_mira")["caption"], "NEEDS YOUR APPROVAL")
	var s := AgentUiDemo.state()
	s["approvals"] = []
	Realm.apply_state(s)
	assert_eq(_status("agt_mira")["mood"], "working", "answered, she is back at work")
	assert_eq(_status("agt_mira")["caption"], "WORKING")
	# Corvin starts a new task while his result still waits: the review stays first.
	_new_task("tsk_next", Protocol.TaskState.RUNNING, "2026-02-01T00:00:00Z", {"agent_id": "agt_corvin"})
	_agent_event("agt_corvin", {"activity": Protocol.AgentActivity.WORKING, "current_task_id": "tsk_next"})
	assert_eq(_status("agt_corvin")["mood"], "review")
	assert_eq(_status("agt_corvin")["task_id"], "tsk_docs", "a click opens the result that waits")
	# Then a failed task and a paused one, before the work, as in the task tracker.
	_task_event("tsk_tests", Protocol.TaskState.FAILED)
	assert_eq(_status("agt_mira")["caption"], "TASK FAILED")
	assert_eq(_status("agt_mira")["mood"], "blocked")
	_task_event("tsk_tests", Protocol.TaskState.PAUSED)
	assert_eq(_status("agt_mira")["caption"], "PAUSED")
	assert_eq(_status("agt_mira")["mood"], "blocked")
	# Her task done and the next one queued: she is about to start it.
	_task_event("tsk_login", Protocol.TaskState.ACCEPTED)
	_task_event("tsk_tests", Protocol.TaskState.QUEUED)
	_agent_event("agt_mira", {"activity": Protocol.AgentActivity.IDLE, "current_task_id": null})
	assert_eq(_status("agt_mira")["caption"], "STARTING")
	assert_eq(_status("agt_mira")["mood"], "working")
	_task_event("tsk_tests", Protocol.TaskState.CANCELLED)
	assert_eq(_status("agt_mira")["mood"], "idle")
	assert_eq(_status("agt_mira")["caption"], "", "idle, the plate shows the role and rank")


func test_the_name_plate_and_the_panel_agree() -> void:
	var host := Control.new()
	add_child_autofree(host)
	var homes := {}
	for id: String in ["agt_mira", "agt_corvin"]:
		var panel := AgentPanel.new()
		host.add_child(panel)
		panel.setup(id)
		var home := _home(id, host)
		assert_eq(home._plate.mood(), panel._status_sigil.state, "%s: one mood" % id)
		homes[id] = home
	var mira: HomeStatusView = homes["agt_mira"]
	var corvin: HomeStatusView = homes["agt_corvin"]
	assert_eq(mira._plate._caption.text, "NEEDS YOUR APPROVAL")
	assert_eq(corvin._plate._caption.text, "RESULT READY")
	# At work on the next task, Corvin's plate keeps the review first, as his panel does.
	_new_task("tsk_next", Protocol.TaskState.RUNNING, "2026-02-01T00:00:00Z", {"agent_id": "agt_corvin"})
	_agent_event("agt_corvin", {"activity": Protocol.AgentActivity.WORKING, "current_task_id": "tsk_next"})
	corvin.refresh()
	assert_eq(corvin._plate.mood(), "review")
	assert_eq(corvin._plate._caption.text, "RESULT READY")
	var plate := NamePlate.new()
	add_child_autofree(plate)
	plate.set_mood("waiting")
	assert_eq(plate.mood(), "waiting")


func test_a_settling_agent_is_settling_on_the_plate_too() -> void:
	# Corvin's home stands and his add-ons go up: the Town Hall reports him blocked (they are
	# missing), but the player has nothing to do yet.
	_agent_event("agt_corvin", {"lifecycle": Protocol.AgentLifecycle.SETTLING,
		"activity": Protocol.AgentActivity.BLOCKED, "blocked_reason": "missing_tools"})
	assert_eq(_status("agt_corvin")["mood"], "settling")
	var host := Control.new()
	add_child_autofree(host)
	var home := _home("agt_corvin", host)
	assert_eq(home._plate.mood(), "settling")
	assert_eq(home._plate._caption.text, "SETTLING IN")
	assert_false(home._mark.visible, "no red mark while the add-ons go up")
	# Short of resources for an add-on, he needs the player.
	var link := WaitLink.new()
	link.waiting_tools = {"agt_corvin": {"tool": "forge", "missing": {"wood": 40}}}
	home.link = link
	home.refresh()
	assert_eq(home._plate.mood(), "blocked")
	assert_eq(home._plate._caption.text, "NEEDS RESOURCES")
	assert_true(home._mark.visible)
	assert_eq(_status("agt_corvin", link)["mood"], "blocked", "the panel says the same")
