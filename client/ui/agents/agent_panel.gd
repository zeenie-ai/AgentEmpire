class_name AgentPanel
extends HBoxContainer
## The selection panel's block for one agent (setup(agent_id)), made for a ~720x190 area of the
## dark wood HUD:
## - the portrait, its ring coloured by what the agent does, with the rank badge;
## - the name, rank, level and an XP bar to the next level (level L needs 50*L*(L-1) XP, from
##   economy.json levels);
## - role, harness and model;
## - a status line: training at the Keep (seconds left), settling (building its home or
##   add-ons), working (phase and tool from Realm.progress), waiting for your approval, result
##   ready for review, blocked (why) or idle; plus how many petitions wait;
## - the current task's title with a Mana bar (spent against the seal);
## - the home's queue, and the add-ons: built, being built, planned, or waiting for resources
##   (Game.link.waiting_tools).
## Clicking the status line asks for the review (review_requested) or the petitions
## (approvals_requested). Live from Realm; the training countdown ticks twice a second.

signal review_requested(task_id: String)
signal approvals_requested(agent_id: String)

const Protocol = preload("res://net/protocol.gd")
const TICK_S := 0.5
## The widest the name may grow before it ends in an ellipsis.
const NAME_MAX_PX := 250.0

var agent_id: String = ""
var link: Object = null

var _portrait: AgentPortrait
var _name: Label
var _rank: RankBadge
var _level: Label
var _xp: ManaBar
var _role: Label
var _status_row: HBoxContainer
var _status_dot: Glyph
var _status: Label
var _petitions: PanelContainer
var _task_row: HBoxContainer
var _task_title: Label
var _task_mana: ManaBar
var _queue: Label
var _addons: HBoxContainer
var _status_info: Dictionary = {}
var _tick: float = 0.0


func _init() -> void:
	theme = AgentTheme.theme(AgentTheme.HUD)
	add_theme_constant_override("separation", 18)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(0, 150)
	_portrait = AgentPortrait.new(108)
	add_child(_portrait)
	var col := AgentUi.vbox(5, self)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var top := AgentUi.hbox(10, col)
	_name = AgentUi.label("", "TitleLabel", top)
	_name.add_theme_font_size_override("font_size", 18)
	_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name.clip_text = true
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name.mouse_filter = Control.MOUSE_FILTER_PASS
	_rank = RankBadge.new(22)
	top.add_child(_rank)
	_level = AgentUi.label("", "Mono", top)
	_level.add_theme_color_override("font_color", UiTokens.GOLD_BRIGHT)
	_level.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_xp = ManaBar.new(200, 16)
	_xp.unit = "XP"
	_xp.warn_colors = false
	_xp.bar_height = 7.0
	_xp.fill_top = Color("#c9b8ff")
	_xp.fill_bottom = Color("#6b4fd0")
	_xp.look = AgentTheme.HUD
	top.add_child(_xp)

	_role = AgentUi.label("", "MutedLabel", col)
	_role.clip_text = true
	_role.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

	_status_row = AgentUi.hbox(8, col)
	_status_row.mouse_filter = Control.MOUSE_FILTER_STOP
	_status_row.gui_input.connect(_on_status_input)
	_status_dot = Glyph.new("dot", UiTokens.MINT, 10)
	_status_row.add_child(_status_dot)
	_status = AgentUi.label("", "BodyLabel", _status_row)
	_status.add_theme_font_size_override("font_size", 15)
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_petitions = AgentUi.pill("", UiTokens.WARN, true, _status_row)
	_petitions.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_task_row = AgentUi.hbox(12, col)
	_task_title = AgentUi.label("", "BodyLabel", _task_row)
	_task_title.add_theme_font_override("font", UiFonts.spectral("Italic"))
	_task_title.add_theme_font_size_override("font_size", 14)
	_task_title.add_theme_color_override("font_color", UiTokens.HUD_TEXT)
	_task_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_task_title.clip_text = true
	_task_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_task_mana = ManaBar.new(230, 16)
	_task_mana.look = AgentTheme.HUD
	_task_row.add_child(_task_mana)

	var bottom := AgentUi.hbox(10, col)
	var qbox := PanelContainer.new()
	var qs := AgentTheme.pill_box(UiTokens.HUD_BORDER)
	qs.bg_color = Color(0, 0, 0, 0.35)
	qs.content_margin_top = 3
	qs.content_margin_bottom = 3
	qbox.add_theme_stylebox_override("panel", qs)
	qbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bottom.add_child(qbox)
	_queue = AgentUi.label("", "MutedLabel", qbox)
	_queue.add_theme_color_override("font_color", UiTokens.HUD_SUBTLE)
	var sep := VSeparator.new()
	sep.custom_minimum_size = Vector2(2, 24)
	bottom.add_child(sep)
	var al := AgentUi.label("ADD-ONS", "MutedLabel", bottom)
	al.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_addons = AgentUi.hbox(5, bottom)


## Shows agent `id`. `link_override` stands in for Game.link (tests, previews).
func setup(id: String, link_override: Object = null) -> AgentPanel:
	agent_id = id
	if link_override != null:
		link = link_override
	refresh()
	return self


func _link() -> Object:
	return link if link != null else Game.link


func _enter_tree() -> void:
	for pair: Array in _signals():
		var sig: Signal = pair[0]
		var fn: Callable = pair[1]
		if not sig.is_connected(fn):
			sig.connect(fn)
	refresh()


func _exit_tree() -> void:
	for pair: Array in _signals():
		var sig: Signal = pair[0]
		var fn: Callable = pair[1]
		if sig.is_connected(fn):
			sig.disconnect(fn)


func _signals() -> Array:
	return [[Realm.changed, _on_changed], [Realm.task_progress, _on_progress]]


func _on_changed(kind: String, id: String) -> void:
	if kind == "agent" and id != agent_id:
		return
	refresh()


func _on_progress(task_id: String, _p: Dictionary) -> void:
	if task_id == J.gs(Realm.current_task(agent_id), "id"):
		_refresh_status()
		_refresh_task()


func _process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = TICK_S
	var lc := J.gs(Realm.agent(agent_id), "lifecycle")
	if lc == Protocol.AgentLifecycle.TRAINING or lc == Protocol.AgentLifecycle.SETTLING:
		_refresh_status()
		_refresh_addons()


func refresh() -> void:
	var a := Realm.agent(agent_id)
	if a.is_empty():
		_name.text = "UNKNOWN AGENT"
		return
	_name.text = J.gs(a, "name").to_upper()
	_name.tooltip_text = J.gs(a, "name")
	# Short names show whole; long ones (up to 40 letters) end in an ellipsis.
	var w := UiFonts.cinzel(700, 2).get_string_size(_name.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	_name.custom_minimum_size.x = minf(ceilf(w) + 4.0, NAME_MAX_PX)
	_rank.rank = J.gs(a, "rank", "F")
	var level := J.gi(a, "level", 1)
	var xp := J.gi(a, "xp")
	var lp := AgentUi.level_progress(xp, level)
	_level.text = "LV %d" % level
	if bool(lp["max"]):
		_xp.unit = "XP  MAX"
		_xp.set_values(1.0, 1.0)
	else:
		_xp.unit = "XP"
		_xp.set_values(float(lp["into"]), float(lp["span"]))
	_xp.tooltip_text = "Level %d\n%s XP in all; %s more to reach level %d." % [level, AgentUi.group(xp),
		AgentUi.group(int(lp["span"]) - int(lp["into"])), level + 1] if not bool(lp["max"]) else "Level %d\nThe highest level." % level
	var role := J.gs(a, "role")
	_role.text = "%s  ·  %s  ·  %s" % [Economy.data.role_name(role).to_upper(), AgentUi.harness_name(J.gs(a, "provider")).to_upper(), J.gs(a, "model").to_upper()]
	_role.tooltip_text = "%s: %s\nHarness: %s\nModel: %s" % [Economy.data.role_name(role), Economy.data.role_plain(role),
		AgentUi.harness_name(J.gs(a, "provider")), J.gs(a, "model")]
	_refresh_status()
	_refresh_task()
	_refresh_queue()
	_refresh_addons()


func _refresh_status() -> void:
	var a := Realm.agent(agent_id)
	_status_info = AgentUi.agent_status(a, _link())
	var mood := String(_status_info.get("mood", "idle"))
	_portrait.set_agent(a, mood)
	var col := AgentUi.mood_color(mood, AgentTheme.HUD)
	_status.text = String(_status_info.get("text", ""))
	_status.add_theme_color_override("font_color", col if mood != "idle" else UiTokens.HUD_SUBTLE)
	_status_dot.color = col
	var petitions := Realm.approvals_for(agent_id).size()
	_petitions.visible = petitions > 0
	AgentUi.set_pill(_petitions, "%d petition%s" % [petitions, "" if petitions == 1 else "s"], UiTokens.WARN, true)
	var clickable := mood == "review" or petitions > 0
	_status_row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if clickable else Control.CURSOR_ARROW
	_status_row.tooltip_text = "Open the review" if mood == "review" else ("Show the petitions" if petitions > 0 else "")


func _refresh_task() -> void:
	var t := Realm.current_task(agent_id)
	if t.is_empty():
		t = Realm.headline_task(agent_id)
	_task_row.visible = not t.is_empty()
	if t.is_empty():
		return
	_task_title.text = "“%s”" % J.gs(t, "title", "Untitled task")
	_task_title.tooltip_text = "%s\n%s, %s" % [J.gs(t, "title"), AgentUi.size_label(J.gs(t, "size", "M")), AgentUi.state_text(J.gs(t, "state")).to_lower()]
	var mpm := float(AgentUi.micros_per_mana())
	var spent := J.gi(t, "spent_micros")
	var p: Dictionary = Realm.progress.get(J.gs(t, "id"), {})
	if not p.is_empty():
		spent = maxi(spent, J.gi(p, "spent_micros"))
	_task_mana.set_values(float(spent) / mpm, float(J.gi(t, "seal_micros")) / mpm, 0.0, J.b(t.get("spent_is_estimate"), false))
	_task_mana.tooltip_text = "Mana spent against the task's seal (1 Mana = $0.01)."


func _refresh_queue() -> void:
	var n := AgentUi.waiting_count(agent_id)
	var limit := Economy.data.home_task_queue(Realm.current_age())
	_queue.text = "QUEUE %d / %d" % [n, limit]
	_queue.add_theme_color_override("font_color", UiTokens.WARN if n >= limit else UiTokens.HUD_SUBTLE)
	_queue.tooltip_text = "Scrolls waiting at the home. The %s Age allows %d." % [Economy.data.age_name(Realm.current_age()), limit]


func _refresh_addons() -> void:
	for c in _addons.get_children():
		_addons.remove_child(c)
		c.queue_free()
	var a := Realm.agent(agent_id)
	var have: Array[String] = []
	for t in Realm.tools_of(agent_id):
		var type := J.gs(t, "type")
		have.append(type)
		var status := J.gs(t, "status")
		var state := "active"
		var tip := "%s\n%s." % [AgentUi.addon_name(type), AgentUi.addon_plain(type)]
		match status:
			Protocol.ToolStatus.BUILDING:
				state = "building"
				tip += "\nBeing built."
			Protocol.ToolStatus.ERROR:
				state = "error"
				tip += "\nSomething is wrong with it."
		_addons.add_child(AddonIcon.new(type, state, tip))
	var wait := AgentUi.waiting_tool(_link(), agent_id)
	var waiting_type := J.gs(wait, "tool")
	if waiting_type != "" and not waiting_type in have:
		have.append(waiting_type)
		_addons.add_child(AddonIcon.new(waiting_type, "waiting", "%s\nWaiting for %s to be built." % [AgentUi.addon_name(waiting_type),
			AgentUi.cost_text(J.gd(wait, "missing"))]))
	for v: Variant in J.a(a.get("starting_tools")):
		var type := J.s(v)
		if type != "" and not type in have:
			have.append(type)
			_addons.add_child(AddonIcon.new(type, "planned", "%s\nPlanned: built once the home stands." % AgentUi.addon_name(type)))
	if _addons.get_child_count() == 0:
		var none := AgentUi.label("none yet", "MutedLabel", _addons)
		none.vertical_alignment = VERTICAL_ALIGNMENT_CENTER


func _on_status_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if String(_status_info.get("mood", "")) == "review":
		review_requested.emit(String(_status_info.get("task_id", "")))
	elif not Realm.approvals_for(agent_id).is_empty():
		approvals_requested.emit(agent_id)


## One add-on in the row: its icon in a small slot, dimmed while planned, being built (an
## hourglass) or waiting for resources (a red mark).
class AddonIcon:
	extends Control
	var type: String = ""
	var state: String = "active"

	func _init(t: String = "", s: String = "active", tip: String = "") -> void:
		type = t
		state = s
		tooltip_text = tip
		custom_minimum_size = Vector2(30, 30)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_PASS

	func _make_custom_tooltip(for_text: String) -> Object:
		return CraftedTooltip.make(for_text) if for_text != "" else null

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var edge := UiTokens.HUD_BORDER
		match state:
			"active":
				edge = Color(UiTokens.GOLD, 0.8)
			"error", "waiting":
				edge = UiTokens.BAD
			"building":
				edge = Color(UiTokens.MINT, 0.7)
		draw_rect(r, Color(0, 0, 0, 0.45))
		draw_rect(r, Color(edge, 0.9 if state == "active" else 0.6), false, 1.0)
		IconDraw.draw(self, type, r.grow(-3.0), state != "active")
		if state == "planned":
			draw_rect(r.grow(-1.0), Color(0, 0, 0, 0.35))
		elif state == "building":
			Glyph.paint(self, "hourglass", Rect2(Vector2(size.x - 12, size.y - 12), Vector2(10, 10)), UiTokens.MINT)
		elif state == "waiting" or state == "error":
			draw_circle(Vector2(size.x - 5, 5), 4.0, UiTokens.BAD)
			draw_arc(Vector2(size.x - 5, 5), 4.0, 0.0, TAU, 12, Color(0, 0, 0, 0.6), 1.0, true)
