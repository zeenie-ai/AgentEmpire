extends SceneTree
## Renders the agent windows and panels (client/ui/agents) over a running demo town, from a fake
## Town Hall state (AgentUiDemo) and a fake TownLink, and saves each as out/ui_<name>.png.
## Needs a real window, so do not pass --headless:
##   .tools/godot/Godot_v4.7.2-stable_win64_console.exe --path client -s res://tools/ui_preview.gd
## Options after "--":
##   --out=<dir>        where the PNGs go (default: <repo>/out)
##   --size=1600x900    the window size (1280x720 checks the smallest supported screen)
##   --only=a,b         only these shots
##   --bg=town|plain    the game behind the windows (default), or a plain backdrop (faster)
##   --tag=<suffix>     appended to each file name: ui_summon_<suffix>.png
## Shots: summon, summon_lower, summon_modes, summon_grace, folder, composer, composer_warn,
## approvals, review, review_chronicle, review_reward, review_blocked, agent_panel, agent_states,
## budget, budget_confirm, chronicle.
##
## A script run with -s compiles before the autoloads exist, so everything that uses them (the
## windows, Realm, Economy, Game) is loaded at run time and kept untyped here.

const DEFAULT_SIZE := Vector2i(1600, 900)
const SHOTS := ["summon", "summon_lower", "summon_modes", "summon_grace", "folder", "composer", "composer_warn",
	"approvals", "review", "review_chronicle", "review_reward", "review_blocked", "agent_panel", "agent_states",
	"budget", "budget_confirm", "chronicle"]
const UI := "res://ui/agents/%s.gd"

var _args: PackedStringArray
var _size: Vector2i = DEFAULT_SIZE
var _out: String = ""
var _tag: String = ""
var _demo: GDScript
var _link: PreviewLink
var _layer: CanvasLayer
var _stage: Control
var _main: Node
var _open_nodes: Array[Node] = []


## The fake TownLink: every command succeeds at once with a canned reply.
class PreviewLink:
	extends RefCounted
	var waiting_tools: Dictionary = {}
	var courier: Object = null
	var training: Dictionary = {}
	var detail: Dictionary = {}
	var accept_reply: Dictionary = {}
	var budget_conflict: bool = false
	var request_script: GDScript = load("res://net/net_request.gd")

	func reply(type: String, payload: Variant, ok: bool = true, code: String = "", message: String = "") -> Object:
		var r: Object = request_script.new(type, "preview", {})
		if ok:
			r.call("finish", true, payload)
		else:
			r.call("fail", code, message, false)
		return r

	func summon(_spec: Dictionary) -> Object:
		return reply("create_agent", {"agent_id": "agt_preview", "cost": {}, "free": false, "training": {"duration_ms": 40000}})

	func assign_task(_agent_id: String, _spec: Dictionary) -> Object:
		return reply("assign_task", {"task_id": "tsk_preview"})

	func respond_approval(_id: String, _decision: String, _scope: String, _message: String = "") -> Object:
		return reply("respond_approval", {})

	func task_detail(_task_id: String, _include: Array = []) -> Object:
		return reply("get_task_detail", detail)

	func accept_result(_task_id: String, _integrate: String) -> Object:
		return reply("accept_result", accept_reply)

	func send_back(_task_id: String, _feedback: String) -> Object:
		return reply("send_back", {})

	func abandon_task(_task_id: String) -> Object:
		return reply("abandon_task", {})

	func set_budget(_period: String, _pool: float, _billing: Dictionary, confirm_raise: bool = false) -> Object:
		if budget_conflict and not confirm_raise:
			return reply("set_budget", null, false, "CONFLICT", "raising the Mana pool in the middle of a period requires confirm_raise")
		return reply("set_budget", {"mana": {}})

	func pick_courier() -> Object:
		return courier

	func training_left_s(agent_id: String) -> float:
		return float(training.get(agent_id, 0.0))


## A townsperson for the courier preview.
class FakeUnit:
	extends RefCounted
	var id: int = 0

	func _init(unit_id: int) -> void:
		id = unit_id


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
		printerr("ui_preview needs a real window: run it without --headless.")
		quit(2)
		return
	var sz := _arg("size", "%dx%d" % [DEFAULT_SIZE.x, DEFAULT_SIZE.y]).split("x")
	_size = Vector2i(int(sz[0]), int(sz[1]))
	_tag = _arg("tag", "")
	_out = _arg("out", ProjectSettings.globalize_path("res://").path_join("../out").simplify_path())
	DirAccess.make_dir_recursive_absolute(_out)
	await _fix_window()
	_demo = load(UI % "agent_ui_demo")
	_link = PreviewLink.new()
	_link.detail = _demo.task_detail("tsk_docs")
	if _arg("bg", "town") == "town":
		await _start_town()
	else:
		_plain_backdrop()
	_layer = CanvasLayer.new()
	_layer.layer = 50
	root.add_child(_layer)
	_stage = Control.new()
	_stage.theme = load("res://ui/theme/theme_builder.gd").theme()
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_stage)
	_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_set_treasury({"food": 460, "wood": 385, "stone": 240, "gold": 175})
	for shot: String in SHOTS:
		if _wanted(shot):
			await _take(shot)
			await _clear()
	quit(0)


func _take(shot: String) -> void:
	match shot:
		"summon":
			await _shot_summon()
		"summon_lower":
			await _shot_summon_lower()
		"summon_modes":
			await _shot_summon_modes()
		"summon_grace":
			await _shot_summon_grace()
		"folder":
			await _shot_folder()
		"composer":
			await _shot_composer()
		"composer_warn":
			await _shot_composer_warn()
		"approvals":
			await _shot_approvals()
		"review":
			await _shot_review()
		"review_chronicle":
			await _shot_review_chronicle()
		"review_reward":
			await _shot_review_reward()
		"review_blocked":
			await _shot_review_blocked()
		"agent_panel":
			await _shot_agent_panel()
		"agent_states":
			await _shot_agent_states()
		"budget":
			await _shot_budget()
		"budget_confirm":
			await _shot_budget_confirm()
		"chronicle":
			await _shot_chronicle()


# --- the scene -------------------------------------------------------------------------------------

func _start_town() -> void:
	_main = load("res://game/main.tscn").instantiate()
	_main.set("autostart", false)
	root.add_child(_main)
	await process_frame
	var game := root.get_node("Game")
	game.set("paused", true)
	var w: Variant = game.call("new_town", 4127, "preview")
	load("res://tools/demo_town.gd").call("build", w, 12, 70.0)
	var camera: Variant = _main.get("camera")
	camera.set("input_enabled", false)
	var k: Variant = w.call("keep")
	var c: Vector2 = k.call("center")
	camera.call("set_view", Vector3(c.x + 2.0, 0.0, c.y + 2.5), 29.0, deg_to_rad(-20.0))
	game.set("paused", false)
	for i in 20:
		await process_frame


func _plain_backdrop() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1
	root.add_child(layer)
	var bg := TextureRect.new()
	var g := GradientTexture2D.new()
	var grad := Gradient.new()
	grad.set_color(0, Color("#6f8a4a"))
	grad.set_color(1, Color("#3d4d2a"))
	g.gradient = grad
	g.fill_to = Vector2(0, 1)
	bg.texture = g
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	layer.add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _set_treasury(t: Dictionary) -> void:
	var economy := root.get_node("Economy")
	var ledger: Object = load("res://game/economy/local_ledger.gd").new(economy.get("data"), t, 1)
	economy.call("set_ledger", ledger)


func _realm() -> Node:
	return root.get_node("Realm")


func _apply(state: Dictionary) -> void:
	_realm().call("apply_state", state)


## The window host, as the HUD's open_window would be: a dimmed backdrop, the window centred.
func _open(w: Control, dim: bool = true) -> Control:
	if dim:
		var d := ColorRect.new()
		d.color = Color(0.03, 0.02, 0.04, 0.55)
		_stage.add_child(d)
		d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_open_nodes.append(d)
	_stage.add_child(w)
	_open_nodes.append(w)
	return w


func _window(script_name: String) -> Control:
	var w: Control = load(UI % script_name).new()
	w.set("link", _link)
	w.set("requester", _request)
	return w


func _clear() -> void:
	for n in _open_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_open_nodes.clear()
	await process_frame
	await process_frame


## The windows' own queries (list_models, browse_folder, check_providers), answered at once.
func _request(type: String, payload: Dictionary = {}) -> Object:
	match type:
		"list_models":
			return _link.reply(type, {"models": _demo.models(String(payload.get("provider", "")))})
		"browse_folder":
			var p: Variant = payload.get("path")
			return _link.reply(type, _demo.browse(String(p) if p != null else ""))
		"check_providers":
			return _link.reply(type, {"providers": _demo.providers()})
	return _link.reply(type, {})


func _frames(n: int) -> void:
	for i in n:
		_hold_window()
		await process_frame


func _snap(name: String, frames: int = 30) -> void:
	var img: Image = null
	for attempt in 4:
		await _frames(frames)
		img = root.get_viewport().get_texture().get_image()
		if img.get_size() == _size:
			break
		frames = 12
	var path := _out.path_join("ui_%s%s.png" % [name, ("_" + _tag) if _tag != "" else ""])
	var err := img.save_png(path)
	print("ui_preview: %s %dx%d %s" % [path, img.get_width(), img.get_height(), "ok" if err == OK else "error %d" % err])


func _fix_window() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(_size)
	for i in 3:
		await process_frame


func _hold_window() -> void:
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if DisplayServer.window_get_size() != _size:
		DisplayServer.window_set_size(_size)


# --- states --------------------------------------------------------------------------------------------

func _state_one_agent() -> Dictionary:
	var s: Dictionary = _demo.state()
	s["agents"] = [_demo.mira()]
	var tools: Array = []
	for t: Dictionary in _demo.tools():
		if String(t["agent_id"]) == "agt_mira":
			tools.append(t)
	s["tools"] = tools
	s["tasks"] = [_demo.task_login(), _demo.task_tests()]
	var providers: Array = _demo.providers()
	providers.append({"id": "pi", "installed": false, "logged_in": false, "billing_hint": "unknown",
		"message": "pi was not found on this machine."})
	s["providers"] = providers
	return s


func _state_empty() -> Dictionary:
	var s: Dictionary = _demo.state()
	s["agents"] = []
	s["tools"] = []
	s["tasks"] = []
	s["approvals"] = []
	return s


# --- shots ------------------------------------------------------------------------------------------------

func _shot_summon() -> void:
	_apply(_state_one_agent())
	var d := _window("summon_dialog")
	_open(d)
	await _frames(3)
	d.call("set_workspace", "D:/work/aurelhaven-web", 1)
	var name_edit: LineEdit = d.get("_name_edit")
	name_edit.text = "Seraphine"
	d.call("_on_name_changed", "Seraphine")
	await _snap("summon")


func _shot_summon_lower() -> void:
	_apply(_state_one_agent())
	var d := _window("summon_dialog")
	_open(d)
	await _frames(3)
	d.call("set_workspace", "D:/work/aurelhaven-web", 1)
	var adv: Button = d.get("_adv_toggle")
	adv.button_pressed = true
	await _frames(4)
	var sc: ScrollContainer = d.get("_scroll")
	sc.scroll_vertical = 100000
	await _snap("summon_lower")


## The approval modes, as the dropdown lists them (with the ones this agent cannot have yet).
func _shot_summon_modes() -> void:
	_apply(_state_one_agent())
	var d := _window("summon_dialog")
	_open(d)
	await _frames(3)
	d.call("set_workspace", "D:/work/aurelhaven-web", 1)
	var mode: OptionButton = d.get("_mode_select")
	var sc: ScrollContainer = d.get("_scroll")
	sc.ensure_control_visible(mode)
	await _frames(3)
	mode.show_popup()
	await _snap("summon_modes")
	mode.get_popup().hide()


func _shot_summon_grace() -> void:
	_apply(_state_empty())
	var d := _window("summon_dialog")
	_open(d)
	await _frames(3)
	d.call("set_workspace", "D:/work/aurelhaven-web", 1)
	var name_edit: LineEdit = d.get("_name_edit")
	name_edit.text = "Mira"
	d.call("_on_name_changed", "Mira")
	await _snap("summon_grace")


func _shot_folder() -> void:
	_apply(_demo.state())
	var fb := _window("folder_browser")
	fb.set("start_path", "D:/work")
	_open(fb)
	await _frames(4)
	var rows: Dictionary = fb.get("_rows")
	if rows.has("D:/work/aurelhaven-web"):
		(rows["D:/work/aurelhaven-web"] as Button).button_pressed = true
	await _snap("folder")


func _composer(size_key: String) -> Control:
	_apply(_demo.state())
	_link.courier = FakeUnit.new(3)
	var w: Control = load(UI % "task_composer").new().call("setup", "agt_corvin", _link)
	_open(w)
	var title: LineEdit = w.get("title_edit")
	title.text = "Document the ledger entries"
	title.text_changed.emit(title.text)
	var prompt: TextEdit = w.get("prompt_edit")
	prompt.text = "The ledger has grown seven entry kinds (spend, refund, gather, reward, trade, grace and adjust) and nobody remembers which carries what.\n\nWrite docs/ledger.md: one section per kind, with the fields it fills, a real example from a save, and how the Town Hall and the client each use it. Link it from the README."
	prompt.text_changed.emit()
	w.call("select_size", size_key)
	w.call("add_criterion", "Every entry kind has a section with a real example")
	w.call("add_criterion", "The README links the new page")
	var rite: LineEdit = w.get("rite_edit")
	rite.text = "npm run docs:check"
	return w


func _shot_composer() -> void:
	_composer("L")
	await _snap("composer")


func _shot_composer_warn() -> void:
	var w := _composer("XL")
	await _frames(3)
	var sc: ScrollContainer = w.get("_scroll")
	sc.scroll_vertical = 100000
	await _snap("composer_warn")


func _shot_approvals() -> void:
	var s: Dictionary = _demo.state()
	var list: Array = _demo.approvals()
	list.append({"id": "apv_write", "task_id": "tsk_login", "agent_id": "agt_mira", "tool": "Edit", "category": "write", "risk": "low",
		"summary": "Edit src/auth/session.ts", "input_preview": "{\"file_path\": \"src/auth/session.ts\"}", "reason": null, "status": "pending",
		"scopes": ["once", "task", "agent"], "seal_exhausted": false, "created_at": _demo.iso(20.0)})
	list.append({"id": "apv_out", "task_id": "tsk_docs", "agent_id": "agt_corvin", "tool": "Read", "category": "outside_workspace", "risk": "high",
		"summary": "Read C:/Users/Tobin/.ssh/config", "input_preview": "{\"file_path\": \"C:/Users/Tobin/.ssh/config\"}",
		"reason": "Looking for the deploy host name.", "status": "pending", "scopes": ["once"], "seal_exhausted": false, "created_at": _demo.iso(8.0)})
	list.append({"id": "apv_mcp", "task_id": "tsk_login", "agent_id": "agt_mira", "tool": "mcp__github__create_issue", "category": "mcp", "risk": "medium",
		"summary": "Open a GitHub issue: Session refresh races the redirect", "input_preview": "{}", "reason": null, "status": "pending",
		"scopes": ["once", "task", "agent"], "seal_exhausted": false, "created_at": _demo.iso(4.0)})
	s["approvals"] = list
	_apply(s)
	var tray: Control = load(UI % "approval_tray").new()
	tray.set("link", _link)
	_stage.add_child(tray)
	_open_nodes.append(tray)
	tray.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	tray.offset_top = 46 + 12
	tray.offset_right = -16
	tray.offset_left = -16 - 420
	await _frames(3)
	var card: Variant = tray.call("card_for", String(tray.get("open_id")))
	if card != null:
		var toggle: Button = card.get("_details_toggle")
		if toggle != null:
			toggle.button_pressed = true
	await _snap("approvals", 40)


func _review() -> Control:
	_apply(_demo.state())
	var w: Control = load(UI % "review_window").new().call("setup", "tsk_docs", _link)
	_open(w)
	return w


func _shot_review() -> void:
	var w := _review()
	await _frames(4)
	var list: VBoxContainer = w.get("_files_list")
	if list.get_child_count() > 1:
		var row := list.get_child(1) as Button
		row.button_pressed = true
		row.pressed.emit()
	await _snap("review")


func _shot_review_chronicle() -> void:
	var w := _review()
	await _frames(3)
	var toggle: Button = w.get("_chronicle_toggle")
	toggle.button_pressed = true
	await _frames(3)
	var sc: ScrollContainer = w.get("_scroll")
	sc.scroll_vertical = 100000
	await _snap("review_chronicle")


func _shot_review_reward() -> void:
	_link.accept_reply = {"rewards": {"rp": 351, "xp": 351, "resources": {"food": 53, "wood": 53, "stone": 123, "gold": 123},
		"breakdown": {"base": 450, "q": 0.2, "e": 0.1, "p": 0.1, "d": 1.0, "ceiling": 9000}}, "merge": {"commit": "1a2b3c4d5e6f"}}
	var w := _review()
	await _frames(3)
	w.call("accept")
	await _snap("review_reward")


func _shot_review_blocked() -> void:
	_link.accept_reply = {"rewards": null, "merge": {"blocked_reason": "checkout_dirty"}}
	var w := _review()
	await _frames(3)
	w.call("accept")
	await _snap("review_blocked")


## Mira in the bottom panel's selection area, where the HUD shows the selected agent.
func _shot_agent_panel() -> void:
	_apply(_demo.state())
	var rect := Rect2(Vector2(230, 690), Vector2(1005, 196))
	if _main != null:
		var hud: Variant = _main.get("hud")
		var sp: Variant = hud.get("bottom").get("selection_panel") if hud != null else null
		if sp is Control:
			rect = (sp as Control).get_global_rect()
	var frame := PanelContainer.new()
	frame.theme_type_variation = "InsetPanel"
	_stage.add_child(frame)
	_open_nodes.append(frame)
	frame.position = rect.position
	frame.size = rect.size
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	frame.add_child(margin)
	var p: Control = load(UI % "agent_panel").new().call("setup", "agt_mira", _link)
	margin.add_child(p)
	await _snap("agent_panel")


## Every status an agent can show, each in a 720x190 cell.
func _shot_agent_states() -> void:
	var s: Dictionary = _demo.state()
	var agents: Array = s["agents"]
	var wren: Dictionary = _demo.mira().duplicate(true)
	wren.merge({"id": "agt_wren", "name": "Wren", "role": "scholar", "lifecycle": "training", "activity": "idle", "home": null,
		"tool_ids": [], "starting_tools": ["lectern", "rookery", "archive"], "current_task_id": null, "queue": [], "xp": 0, "level": 1, "rank": "F",
		"created_at": _demo.iso(30.0)}, true)
	var brisa: Dictionary = _demo.corvin().duplicate(true)
	brisa.merge({"id": "agt_brisa", "name": "Brisa", "role": "artificer", "provider": "claude", "model": "claude-sonnet-5",
		"lifecycle": "settling", "activity": "idle", "home": {"tile": {"x": 70, "y": 60}, "built": true}, "tool_ids": ["tl_b_lectern"],
		"starting_tools": ["lectern", "quillworks", "forge"], "current_task_id": null, "queue": [], "xp": 0, "level": 1, "rank": "F",
		"created_at": _demo.iso(600.0)}, true)
	var osric: Dictionary = _demo.corvin().duplicate(true)
	osric.merge({"id": "agt_osric", "name": "Osric", "role": "scribe", "activity": "blocked", "blocked_reason": "no_mana",
		"current_task_id": null, "xp": 980, "level": 5, "rank": "D", "created_at": _demo.iso(9000.0)}, true)
	var elowen: Dictionary = _demo.corvin().duplicate(true)
	elowen.merge({"id": "agt_elowen", "name": "Elowen", "role": "scholar", "provider": "claude", "model": "claude-opus-5-5",
		"xp": 2400, "level": 7, "rank": "C", "created_at": _demo.iso(20000.0)}, true)
	agents.append_array([wren, brisa, osric, elowen])
	var tools: Array = s["tools"]
	tools.append({"id": "tl_b_lectern", "agent_id": "agt_brisa", "type": "lectern", "status": "building", "tile": {"x": 68, "y": 58}, "config_summary": null, "health": null})
	for t in ["lectern", "quillworks"]:
		tools.append({"id": "tl_o_" + t, "agent_id": "agt_osric", "type": t, "status": "active", "tile": {"x": 0, "y": 0}, "config_summary": null, "health": null})
	for t in ["lectern", "rookery", "archive"]:
		tools.append({"id": "tl_e_" + t, "agent_id": "agt_elowen", "type": t, "status": "active", "tile": {"x": 0, "y": 0}, "config_summary": null, "health": null})
	_apply(s)
	var progress: Dictionary = _realm().get("progress")
	progress["tsk_login"] = {"task_id": "tsk_login", "phase": "tool", "current_tool": "Bash", "files_touched": 3, "spent_micros": 640000}
	_link.training = {"agt_wren": 23.0}
	_link.waiting_tools = {"agt_brisa": {"tool": "quillworks", "missing": {"wood": 20, "stone": 10}}}
	var bg := PanelContainer.new()
	bg.theme_type_variation = "HudPanel"
	_stage.add_child(bg)
	_open_nodes.append(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 14)
	bg.add_child(grid)
	for id in ["agt_mira", "agt_corvin", "agt_wren", "agt_brisa", "agt_osric", "agt_elowen"]:
		var cell := PanelContainer.new()
		cell.theme_type_variation = "InsetPanel"
		cell.custom_minimum_size = Vector2(720, 190)
		grid.add_child(cell)
		var margin := MarginContainer.new()
		for side in ["left", "right", "top", "bottom"]:
			margin.add_theme_constant_override("margin_" + side, 10)
		cell.add_child(margin)
		margin.add_child(load(UI % "agent_panel").new().call("setup", id, _link))
	await _snap("agent_states")
	_link.training = {}
	_link.waiting_tools = {}


func _shot_budget() -> void:
	_apply(_demo.state())
	_open(_window("budget_dialog"))
	await _snap("budget")


func _shot_budget_confirm() -> void:
	_apply(_demo.state())
	_link.budget_conflict = true
	var d := _window("budget_dialog")
	_open(d)
	await _frames(3)
	var field: Variant = d.get("pool_field")
	field.call("set_value", 8.0, true)
	d.call("save")
	await _snap("budget_confirm")
	_link.budget_conflict = false


func _shot_chronicle() -> void:
	_apply(_demo.state())
	var wf: Control = load(UI % "window_frame").new()
	wf.call("configure", "Chronicle", "Document the town save format  ·  Corvin", 1, 820.0)
	var cv: Control = load(UI % "chronicle_view").new(1).call("setup", "tsk_docs", _demo.activity())
	cv.custom_minimum_size = Vector2(0, 360)
	wf.get("body").add_child(cv)
	_open(wf)
	await _frames(4)
	_realm().call("apply_event", {"type": "task_activity", "payload": {"task_id": "tsk_docs",
		"entry": {"time": _demo.iso(0.0), "kind": "system", "text": "Mana check: 286 of 450 spent."}}})
	await _snap("chronicle")
