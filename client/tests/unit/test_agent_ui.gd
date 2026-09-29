extends GutTest
## The agent windows and panels (client/ui/agents), built from AgentUiDemo's fake Town Hall
## state, acting through a fake TownLink that records every call and a fake requester for the
## windows' own queries (list_models, browse_folder).

const Protocol = preload("res://net/protocol.gd")


## Stands in for Game.link: records calls, returns requests the test finishes.
class FakeLink:
	extends RefCounted
	var calls: Array[Dictionary] = []
	var waiting_tools: Dictionary = {}
	var courier: Object = null
	var training_s: float = 0.0

	func _req(type: String, args: Dictionary) -> NetRequest:
		var r := NetRequest.new(type, "fake-%d" % calls.size(), args)
		calls.append({"type": type, "args": args, "req": r})
		return r

	func last(type: String) -> Dictionary:
		for i in range(calls.size() - 1, -1, -1):
			if String(calls[i]["type"]) == type:
				return calls[i]
		return {}

	func count(type: String) -> int:
		var n := 0
		for c in calls:
			if String(c["type"]) == type:
				n += 1
		return n

	func summon(spec: Dictionary) -> NetRequest:
		return _req("summon", {"spec": spec})

	func assign_task(agent_id: String, spec: Dictionary) -> NetRequest:
		return _req("assign_task", {"agent_id": agent_id, "spec": spec})

	func respond_approval(approval_id: String, decision: String, scope: String, message: String = "") -> NetRequest:
		return _req("respond_approval", {"approval_id": approval_id, "decision": decision, "scope": scope, "message": message})

	func task_detail(task_id: String, include: Array = ["activity", "diff"]) -> NetRequest:
		return _req("task_detail", {"task_id": task_id, "include": include})

	func accept_result(task_id: String, integrate: String) -> NetRequest:
		return _req("accept_result", {"task_id": task_id, "integrate": integrate})

	func send_back(task_id: String, feedback: String) -> NetRequest:
		return _req("send_back", {"task_id": task_id, "feedback": feedback})

	func abandon_task(task_id: String) -> NetRequest:
		return _req("abandon_task", {"task_id": task_id})

	func set_budget(period: String, pool_usd: float, billing: Dictionary, confirm_raise: bool = false) -> NetRequest:
		return _req("set_budget", {"period": period, "pool_usd": pool_usd, "billing": billing, "confirm_raise": confirm_raise})

	func pick_courier() -> Object:
		return courier

	func training_left_s(_agent_id: String) -> float:
		return training_s


var link: FakeLink
var asked: Array[Dictionary] = []


## The fake Net.request: records the query; the test finishes it (or it stays pending).
func _requester(type: String, payload: Dictionary = {}) -> NetRequest:
	var r := NetRequest.new(type, "q-%d" % asked.size(), payload)
	asked.append({"type": type, "payload": payload, "req": r})
	return r


func _asked(type: String) -> Dictionary:
	for i in range(asked.size() - 1, -1, -1):
		if String(asked[i]["type"]) == type:
			return asked[i]
	return {}


func before_each() -> void:
	link = FakeLink.new()
	asked.clear()
	Realm.apply_state(AgentUiDemo.state())
	Economy.reset_local_ledger()


func after_each() -> void:
	Realm.clear()
	Economy.reset_local_ledger()
	# Let nodes the windows replaced (queue_free) go before GUT counts orphans.
	await wait_process_frames(2)


func _host(look: int = AgentTheme.STATUS) -> Control:
	var host := Control.new()
	host.theme = AgentTheme.theme(look)
	host.size = Vector2(1600, 900)
	add_child_autofree(host)
	return host


func _open(w: WindowFrame) -> WindowFrame:
	w.link = link
	w.requester = _requester
	_host().add_child(w)
	return w


func test_widgets_build() -> void:
	var host := _host()
	host.add_child(Glyph.new("close"))
	host.add_child(RankBadge.new())
	host.add_child(AgentPortrait.new(64))
	host.add_child(ManaBar.new())
	host.add_child(ChoiceCard.new())
	host.add_child(CheckToggle.new("Express"))
	host.add_child(FormDropdown.new())
	host.add_child(NumberField.new("Mana"))
	var pv := PatchView.new()
	host.add_child(pv)
	pv.set_patch(AgentUiDemo.patch())
	assert_true(pv.file_lines.has("docs/save-format.md"))
	assert_true(pv.file_lines.has("README.md"))
	var cv := ChronicleView.new().setup("tsk_docs", AgentUiDemo.activity())
	host.add_child(cv)
	assert_eq(cv.entry_count(), AgentUiDemo.activity().size())
	cv.add_entries(AgentUiDemo.activity())
	assert_eq(cv.entry_count(), AgentUiDemo.activity().size(), "entries it already shows are ignored")
	await wait_process_frames(2)


# --- Summoning Font -------------------------------------------------------------------------------

func test_summon_dialog_builds_and_loads_models() -> void:
	var d := _open(SummonDialog.new()) as SummonDialog
	await wait_process_frames(2)
	assert_eq(d.provider, "claude", "the first ready harness is chosen")
	var q := _asked(Protocol.CMD_LIST_MODELS)
	assert_false(q.is_empty(), "asks for the models")
	assert_eq(String((q["payload"] as Dictionary).get("provider", "")), "claude")
	(q["req"] as NetRequest).finish(true, {"models": AgentUiDemo.models("claude")})
	await wait_process_frames(2)
	assert_eq(d.model, "claude-opus-5-5", "the default model is picked")
	assert_false(d.grace_active(), "two agents in town: no Font's Grace")


func test_summon_is_disabled_until_workspace_and_model_are_set() -> void:
	var d := _open(SummonDialog.new()) as SummonDialog
	await wait_process_frames(1)
	Realm.apply_state(_state_without_agents())
	await wait_process_frames(1)
	assert_false(d.can_summon(), "no model and no folder yet")
	assert_true(d._summon_button.disabled)
	d.set_workspace("D:/work/aurelhaven-web", 1)
	assert_false(d.can_summon(), "still no model")
	d.apply_models("claude", AgentUiDemo.models("claude"))
	assert_true(d.can_summon(), "model and folder set")
	assert_false(d._summon_button.disabled)
	d.set_workspace("")
	assert_false(d.can_summon(), "the folder is required")
	assert_true(d._summon_button.disabled)


func test_summon_spec_shape() -> void:
	var d := _open(SummonDialog.new()) as SummonDialog
	await wait_process_frames(1)
	Realm.apply_state(_state_without_agents())
	d.apply_models("claude", AgentUiDemo.models("claude"))
	d.set_workspace("D:/work/app", 1)
	var spec := d.build_spec()
	for key in ["name", "provider", "model", "role", "instructions", "approval_mode", "workspace", "starting_tools"]:
		assert_true(spec.has(key), "spec has %s" % key)
	assert_eq(String(spec["provider"]), "claude")
	assert_eq(String(spec["model"]), "claude-opus-5-5")
	assert_eq(String(spec["role"]), "artificer")
	assert_eq(String((spec["workspace"] as Dictionary)["path"]), "D:/work/app")
	assert_eq(String(spec["approval_mode"]), Economy.data.default_approval_mode())
	var tools: Array = spec["starting_tools"]
	for t in Economy.data.role_tools("artificer", "required"):
		assert_true(t in tools, "required add-on %s is a starting tool" % t)
	assert_false("waygate" in tools)
	assert_false(spec.has("seals"), "default seals are left out")
	assert_false(spec.has("billing"), "no billing override by default")
	assert_true(String(spec["name"]).length() > 0 and String(spec["name"]).length() <= 40)
	assert_true(String(spec["instructions"]).contains(String(spec["name"])), "the oath names the agent")
	(d._seal_fields["M"] as NumberField).set_value(200.0, true)
	spec = d.build_spec()
	assert_eq(int((spec["seals"] as Dictionary)["M"]), 200, "a changed seal is sent")
	assert_true(d.grace_active(), "no agents: Font's Grace")
	d.summon()
	var call := link.last("summon")
	assert_false(call.is_empty(), "summon goes through the link")
	var got_id := [""]
	d.summoned.connect(func(id: String) -> void: got_id[0] = id)
	(call["req"] as NetRequest).finish(true, {"agent_id": "agt_new", "cost": {}, "free": true, "training": {"duration_ms": 40000}})
	await wait_process_frames(3)
	assert_eq(String(got_id[0]), "agt_new")
	assert_true(d.is_closing(), "closes after summoning")


func test_summon_shows_errors_inline() -> void:
	var d := _open(SummonDialog.new()) as SummonDialog
	await wait_process_frames(1)
	Realm.apply_state(_state_without_agents())
	d.apply_models("claude", AgentUiDemo.models("claude"))
	d.set_workspace("C:/Windows", 0)
	d.summon()
	(link.last("summon")["req"] as NetRequest).fail(Protocol.ERR_WORKSPACE_DENIED, "system folders cannot be used", false)
	await wait_process_frames(3)
	assert_false(d.is_closing())
	assert_string_contains(d.status_label.text, "system folders cannot be used")
	assert_true(d.can_summon(), "can try again")


func test_plan_first_is_claude_only() -> void:
	var d := _open(SummonDialog.new()) as SummonDialog
	await wait_process_frames(1)
	assert_eq(d.mode_block("plan_first"), "")
	d._set_provider("codex")
	assert_ne(d.mode_block("plan_first"), "", "plan_first is closed to Codex")
	assert_ne(d.mode_block("free_hand"), "", "free_hand needs a later age and rank")


func test_folder_browser_lists_and_chooses() -> void:
	var fb := _open(FolderBrowser.new()) as FolderBrowser
	await wait_process_frames(1)
	var q := _asked(Protocol.CMD_BROWSE_FOLDER)
	assert_false(q.is_empty(), "lists the roots")
	(q["req"] as NetRequest).finish(true, AgentUiDemo.browse("D:/work"))
	await wait_process_frames(2)
	assert_eq(fb.current_path, "D:/work")
	assert_eq(fb.entries.size(), 7)
	var got := [""]
	fb.chosen.connect(func(p: String) -> void: got[0] = p)
	(fb._rows["D:/work/aurelhaven-web"] as Button).button_pressed = true
	fb.choose()
	assert_eq(String(got[0]), "D:/work/aurelhaven-web")
	assert_eq(fb.chosen_git, 1)


# --- Quest scroll ------------------------------------------------------------------------------------

func test_task_composer_builds_the_spec() -> void:
	var w := TaskComposer.new().setup("agt_corvin", link)
	_host(AgentTheme.DOCUMENT).add_child(w)
	await wait_process_frames(1)
	assert_false(w.can_send(), "title and quest are required")
	w.title_edit.text = "  Document the ledger  "
	w.title_edit.text_changed.emit(w.title_edit.text)
	assert_false(w.can_send(), "the quest is still empty")
	w.prompt_edit.text = "Explain every ledger entry kind."
	w.prompt_edit.text_changed.emit()
	assert_true(w.can_send())
	var spec := w.build_spec()
	assert_eq(spec, {"title": "Document the ledger", "prompt": "Explain every ledger entry kind.", "size": "M"}, "optional fields are left out")
	w.select_size("L")
	w.add_criterion("Each kind has an example")
	w.add_criterion("   ")
	w.rite_edit.text = "npm run docs:check"
	w.express_check.button_pressed = true
	spec = w.build_spec()
	assert_eq(String(spec["size"]), "L")
	assert_eq(spec["acceptance"], ["Each kind has an example"], "blank criteria are dropped")
	assert_eq(String(spec["rite"]), "npm run docs:check")
	assert_true(bool(spec["express"]))
	w.send()
	var call := link.last("assign_task")
	assert_eq(String((call["args"] as Dictionary)["agent_id"]), "agt_corvin")
	assert_eq((call["args"] as Dictionary)["spec"], spec)
	var sent := [""]
	w.sent.connect(func(id: String) -> void: sent[0] = id)
	(call["req"] as NetRequest).finish(true, {"task_id": "tsk_new"})
	await wait_process_frames(3)
	assert_eq(String(sent[0]), "tsk_new")


func test_task_composer_respects_the_home_queue() -> void:
	var w := TaskComposer.new().setup("agt_mira", link)
	_host(AgentTheme.DOCUMENT).add_child(w)
	await wait_process_frames(1)
	w.title_edit.text = "More tests"
	w.prompt_edit.text = "Cover the refresh path."
	assert_true(w.queue_full(), "Mira's one queue slot holds a scroll")
	assert_false(w.can_send())
	assert_string_contains(w.validation_problem(), "home holds")


func test_task_composer_courier_preview() -> void:
	var w := TaskComposer.new().setup("agt_corvin", link)
	_host(AgentTheme.DOCUMENT).add_child(w)
	await wait_process_frames(1)
	assert_eq(String(w.courier_preview()["mode"]), "wisp", "nobody free: a Font Wisp")
	link.courier = Carrier.new(7)
	assert_eq(String(w.courier_preview()["mode"]), "human")
	w.express_check.button_pressed = true
	assert_eq(String(w.courier_preview()["mode"]), "express")


class Carrier:
	extends RefCounted
	var id: int = 0

	func _init(unit_id: int) -> void:
		id = unit_id


# --- petitions -------------------------------------------------------------------------------------------

func test_approval_tray_shows_pending_oldest_first() -> void:
	var tray := ApprovalTray.new()
	tray.link = link
	_host().add_child(tray)
	await wait_process_frames(1)
	assert_eq(tray.card_count(), 2)
	assert_eq(tray.get_child(1), tray.card_for("apv_fetch"), "the oldest petition is on top")
	assert_true(tray.card_for("apv_fetch").is_louder(), "past two minutes it gets louder")
	assert_false(tray.card_for("apv_npm").is_louder())
	Realm.apply_event({"type": Protocol.EVT_APPROVAL_RESOLVED, "payload": {"approval_id": "apv_fetch", "decision": "allow", "scope": "once", "by": "player"}})
	assert_eq(tray.card_count(), 1, "answered petitions leave")


func test_approval_tray_caps_the_stack() -> void:
	var s := AgentUiDemo.state()
	var list: Array = []
	for i in 6:
		var a: Dictionary = (AgentUiDemo.approvals()[0] as Dictionary).duplicate()
		a["id"] = "apv_%d" % i
		a["created_at"] = AgentUiDemo.iso(600.0 - i * 10.0)
		list.append(a)
	s["approvals"] = list
	Realm.apply_state(s)
	var tray := ApprovalTray.new()
	_host().add_child(tray)
	await wait_process_frames(1)
	assert_eq(tray.card_count(), ApprovalTray.MAX_VISIBLE)
	assert_true(tray._more.visible)
	assert_string_contains(tray._more_label.text, "2 MORE")


func _card(approval_index: int) -> ApprovalCard:
	var a: Dictionary = AgentUiDemo.approvals()[approval_index]
	var c := ApprovalCard.new().setup(a, link)
	_host().add_child(c)
	return c


func test_approval_buttons_answer_with_decision_and_scope() -> void:
	var expected := [
		["allow_once_button", "allow", "once"],
		["allow_task_button", "allow", "task"],
		["allow_agent_button", "allow", "agent"],
	]
	for e: Array in expected:
		link.calls.clear()
		var c := _card(0)
		(c.get(String(e[0])) as Button).pressed.emit()
		var call := link.last("respond_approval")
		assert_false(call.is_empty(), "%s answers" % e[0])
		var args: Dictionary = call["args"]
		assert_eq(String(args["approval_id"]), "apv_npm")
		assert_eq(String(args["decision"]), String(e[1]))
		assert_eq(String(args["scope"]), String(e[2]))


func test_deny_asks_why_then_answers() -> void:
	var c := _card(0)
	c.deny_button.pressed.emit()
	assert_eq(link.count("respond_approval"), 0, "deny first opens the note")
	assert_true(c.deny_edit.is_visible_in_tree())
	c.deny_edit.text = "Use the test runner we already have."
	c.confirm_deny_button.pressed.emit()
	var args: Dictionary = link.last("respond_approval")["args"]
	assert_eq(String(args["decision"]), "deny")
	assert_eq(String(args["scope"]), "once")
	assert_eq(String(args["message"]), "Use the test runner we already have.")
	var got := [""]
	c.answered.connect(func(_id: String, d: String, _s: String) -> void: got[0] = d)
	(link.last("respond_approval")["req"] as NetRequest).finish(true, {})
	await wait_process_frames(2)
	assert_eq(String(got[0]), "deny")


func test_scope_rules_are_explained_as_the_town_hall_matches_them() -> void:
	var approvals := AgentUiDemo.approvals()
	assert_eq(AgentUi.approval_reach(approvals[0]), "“npm install” commands", "commands match on two words")
	assert_eq(AgentUi.approval_reach(approvals[1]), "requests to developer.mozilla.org", "network matches on the host")
	var high: Dictionary = (approvals[0] as Dictionary).duplicate()
	high["risk"] = "high"
	high["scopes"] = ["once"]
	var c := ApprovalCard.new().setup(high, link)
	_host().add_child(c)
	assert_null(c.allow_task_button, "high risk: no task rule")
	assert_null(c.allow_agent_button, "high risk: no agent rule")
	assert_not_null(c.allow_once_button)


func test_portrait_click_asks_for_focus() -> void:
	var c := _card(1)
	var got := [""]
	c.focus_requested.connect(func(id: String) -> void: got[0] = id)
	c._portrait.pressed.emit()
	assert_eq(String(got[0]), "agt_mira")


# --- review ---------------------------------------------------------------------------------------------------

func test_review_window_accepts_with_merge() -> void:
	var w := ReviewWindow.new().setup("tsk_docs", link)
	_host(AgentTheme.DOCUMENT).add_child(w)
	await wait_process_frames(1)
	var q := link.last("task_detail")
	assert_false(q.is_empty(), "fetches the diff")
	(q["req"] as NetRequest).finish(true, AgentUiDemo.task_detail())
	await wait_process_frames(2)
	assert_eq(w._files_list.get_child_count(), 3)
	assert_true(w._patch.file_lines.has("client/sim/save/sim_serializer.gd"))
	assert_eq(w.integrate, "merge", "git work folders merge by default")
	w.accept()
	var call := link.last("accept_result")
	assert_eq(String((call["args"] as Dictionary)["integrate"]), "merge")
	var rewards := {"rp": 351, "xp": 351, "resources": {"food": 53, "wood": 53, "stone": 123, "gold": 123},
		"breakdown": {"base": 450, "q": 0.2, "e": 0.1, "p": 0.1, "d": 1.0, "ceiling": 9000}}
	(call["req"] as NetRequest).finish(true, {"rewards": rewards, "merge": {"commit": "1a2b3c4d5e"}})
	await wait_process_frames(2)
	assert_eq(w.mode, "done")


func test_review_window_offers_keep_branch_when_blocked() -> void:
	var w := ReviewWindow.new().setup("tsk_docs", link)
	_host(AgentTheme.DOCUMENT).add_child(w)
	await wait_process_frames(1)
	w.accept()
	(link.last("accept_result")["req"] as NetRequest).finish(true, {"rewards": null, "merge": {"blocked_reason": "checkout_dirty"}})
	await wait_process_frames(2)
	assert_eq(w.mode, "blocked")
	var keep: Button = null
	for b in w.footer.get_children():
		if b is Button and (b as Button).text == "KEEP BRANCH INSTEAD":
			keep = b
	assert_not_null(keep, "offers to keep the branch")
	keep.pressed.emit()
	assert_eq(String((link.last("accept_result")["args"] as Dictionary)["integrate"]), "keep_branch")


func test_review_plain_folders_export() -> void:
	var s := AgentUiDemo.state()
	var corvin: Dictionary = (s["agents"] as Array)[1]
	corvin["workspace"] = {"path": "D:/notes", "mode": "plain_folder", "repo_root": null}
	Realm.apply_state(s)
	var w := ReviewWindow.new().setup("tsk_docs", link)
	_host(AgentTheme.DOCUMENT).add_child(w)
	await wait_process_frames(1)
	assert_eq(w.integrate, "export", "plain folders export")
	assert_true((w._integrate_buttons["merge"] as Button).disabled, "no merge without git")
	assert_true((w._integrate_buttons["keep_branch"] as Button).disabled)
	assert_false((w._integrate_buttons["export"] as Button).disabled)
	w.accept()
	assert_eq(String((link.last("accept_result")["args"] as Dictionary)["integrate"]), "export")


func test_review_git_folders_do_not_export() -> void:
	var w := ReviewWindow.new().setup("tsk_docs", link)
	_host(AgentTheme.DOCUMENT).add_child(w)
	await wait_process_frames(1)
	assert_true((w._integrate_buttons["export"] as Button).disabled, "the Town Hall refuses export for git work")
	assert_false((w._integrate_buttons["keep_branch"] as Button).disabled)


func test_review_send_back_needs_feedback() -> void:
	var w := ReviewWindow.new().setup("tsk_docs", link)
	_host(AgentTheme.DOCUMENT).add_child(w)
	await wait_process_frames(1)
	w._set_mode("send_back")
	w.send_back()
	assert_eq(link.count("send_back"), 0, "no feedback, nothing sent")
	w.feedback_edit.text = "Add a diagram of the save blocks."
	w.send_back()
	assert_eq(String((link.last("send_back")["args"] as Dictionary)["feedback"]), "Add a diagram of the save blocks.")


# --- agent panel and budget -----------------------------------------------------------------------------------

func test_agent_panel_shows_status() -> void:
	var host := _host(AgentTheme.HUD)
	var mira := AgentPanel.new().setup("agt_mira", link)
	host.add_child(mira)
	var corvin := AgentPanel.new().setup("agt_corvin", link)
	host.add_child(corvin)
	await wait_process_frames(1)
	assert_string_contains(mira._status.text, "Working")
	assert_true(mira._petitions.visible, "Mira has petitions waiting")
	assert_string_contains(corvin._status.text, "review")
	var got := [""]
	corvin.review_requested.connect(func(id: String) -> void: got[0] = id)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = false
	corvin._status_row.gui_input.emit(click)
	assert_eq(String(got[0]), "tsk_docs")
	assert_eq(AgentUi.xp_for_level(3), 300)
	assert_almost_eq(float(AgentUi.level_progress(420, 3)["ratio"]), 0.4, 0.001, "from level 3 (300 XP) to 4 (600 XP)")


func test_budget_dialog_saves_and_confirms_a_raise() -> void:
	var d := _open(BudgetDialog.new()) as BudgetDialog
	await wait_process_frames(1)
	assert_eq(d.period, "day")
	assert_almost_eq(d.pool_usd, 5.0, 0.001)
	d.pool_field.set_value(8.0, true)
	d.save()
	var call := link.last("set_budget")
	var args: Dictionary = call["args"]
	assert_almost_eq(float(args["pool_usd"]), 8.0, 0.001)
	assert_eq((args["billing"] as Dictionary).keys().size(), 2, "billing for every harness")
	assert_eq(String((args["billing"] as Dictionary)["codex"]), "api_key")
	assert_false(bool(args["confirm_raise"]))
	(call["req"] as NetRequest).fail(Protocol.ERR_CONFLICT, "raising the Mana pool in the middle of a period requires confirm_raise", false)
	await wait_process_frames(2)
	assert_true(d.confirm_check.is_visible_in_tree(), "asks to confirm the raise")
	d.confirm_check.button_pressed = true
	assert_eq(link.count("set_budget"), 2, "ticking the box saves again")
	assert_true(bool((link.last("set_budget")["args"] as Dictionary)["confirm_raise"]))


# --- the frame --------------------------------------------------------------------------------------------------

func test_windows_fit_1280x720_and_scroll() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1280, 720)
	add_child_autofree(sv)
	var host := Control.new()
	host.size = Vector2(1280, 720)
	sv.add_child(host)
	var windows: Array[WindowFrame] = [SummonDialog.new(), TaskComposer.new().setup("agt_corvin", link),
		ReviewWindow.new().setup("tsk_docs", link), BudgetDialog.new()]
	for w in windows:
		w.link = link
		w.requester = _requester
		host.add_child(w)
		await wait_process_frames(4)
		var name := w.title_label.text
		assert_true(w.size.y <= 720.0 - 2.0 * WindowFrame.MARGIN + 1.0, "%s fits 720 high: %s" % [name, w.size])
		assert_true(w.size.x <= 1280.0 - 2.0 * WindowFrame.MARGIN + 1.0, "%s fits 1280 wide" % name)
		assert_true(w.position.x >= 0.0 and w.position.y >= 0.0, "%s is on screen" % name)
		if w is SummonDialog:
			assert_true(w.body.get_combined_minimum_size().y > w._scroll.size.y + 1.0, "the long form scrolls")
		w.queue_free()
		await wait_process_frames(1)


func _press_escape() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	ev.pressed = true
	get_viewport().push_input(ev)
	var up := ev.duplicate() as InputEventKey
	up.pressed = false
	get_viewport().push_input(up)


func test_escape_closes_the_topmost_window_only() -> void:
	var d := _open(SummonDialog.new()) as SummonDialog
	await wait_process_frames(1)
	var fb := FolderBrowser.new()
	fb.requester = _requester
	d.open_window(fb)
	await wait_process_frames(1)
	assert_true(fb.is_topmost())
	_press_escape()
	await wait_process_frames(1)
	assert_true(fb.is_closing(), "Esc closes the folder browser")
	assert_false(d.is_closing(), "and leaves the Summoning Font open")
	await wait_process_frames(12)
	_press_escape()
	await wait_process_frames(1)
	assert_true(d.is_closing())


func test_folder_browser_fills_the_summon_form() -> void:
	var d := _open(SummonDialog.new()) as SummonDialog
	await wait_process_frames(1)
	d.browse_folder()
	await wait_process_frames(1)
	var q := _asked(Protocol.CMD_BROWSE_FOLDER)
	(q["req"] as NetRequest).finish(true, AgentUiDemo.browse("D:/work"))
	await wait_process_frames(2)
	var fb: FolderBrowser = null
	for c in d.get_parent().get_children():
		if c is FolderBrowser:
			fb = c
	assert_not_null(fb, "the browser opens beside the form")
	(fb._rows["D:/work/notes"] as Button).button_pressed = true
	fb.choose()
	assert_eq(d.workspace_path, "D:/work/notes")
	assert_eq(d.workspace_git, 0, "notes is a plain folder")


func test_tray_keeps_one_petition_open() -> void:
	var tray := ApprovalTray.new()
	_host().add_child(tray)
	await wait_process_frames(1)
	assert_eq(tray.open_id, "apv_fetch", "the oldest is open")
	assert_true(tray.card_for("apv_fetch").expanded)
	assert_false(tray.card_for("apv_npm").expanded)
	tray.card_for("apv_npm").expand_requested.emit("apv_npm")
	assert_true(tray.card_for("apv_npm").expanded)
	assert_false(tray.card_for("apv_fetch").expanded)


func _state_without_agents() -> Dictionary:
	var s := AgentUiDemo.state()
	s["agents"] = []
	s["tools"] = []
	s["tasks"] = []
	s["approvals"] = []
	return s
