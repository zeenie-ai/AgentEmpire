class_name TaskTracker
extends VBoxContainer
## The task tracker: the town's live tasks at a glance, top left under the top bar. Each row
## carries the task's seal from the Rive state tracker (a RiveSprite of the "task_seal" set),
## which follows the task's state machine: the scroll on its way, queued, the cogs of preparing,
## the hammer at work, the bell of a petition, the chest of a result to review, the stamp of an
## acceptance, and the check, cross or struck ring once it is over. Under the title: the agent
## and the state, in the state's colour.
##
## A task that ends stays LINGER_S seconds at the top with its final seal, then goes. The live
## rows follow by what needs the player most (petitions, results, failures, pauses, then work and
## what waits), oldest first within a state, up to MAX_ROWS in all; a plate says how many more
## live tasks there are, and the header counts the live ones. Sub-tasks of a party lead are left
## out: the lead's row stands for them. A row that goes fades where it stood, still catching
## clicks, while the others close up.
##
## A click asks for what the row needs: the review (review_requested), the petitions
## (approvals_requested) or the agent (focus_requested). The header folds the list away; the fold
## is kept in Settings ("hud/tracker_folded"). The HUD shows the tracker with a Town Hall, except
## on phones (`enabled`); it shows only while the town is the Town Hall's (an offline town after
## the Town Hall closed has no tasks), and hides itself while nothing is tracked. Live from Realm.

signal review_requested(task_id: String)
signal approvals_requested(agent_id: String)
signal focus_requested(agent_id: String)

const Protocol = preload("res://net/protocol.gd")
const WIDTH := 330.0
const MAX_ROWS := 5
const LINGER_S := 6.0
const SEAL_PX := 46.0
const FOLD_SETTING := "hud/tracker_folded"
## The order rows go in: what needs the player first.
const ORDER := ["awaiting_approval", "awaiting_review", "accepting", "failed", "paused", "running", "preparing",
	"queued", "in_transit", "accepted", "rejected", "cancelled"]

## Whether the tracker may show at all (the HUD's call: a Town Hall, not a phone).
var enabled: bool = true:
	set(value):
		enabled = value
		_update_visible()
## Whether only the header shows.
var folded: bool = false
## Seconds now, for the lingering rows; tests replace it.
var clock: Callable = Callable()
## Whether the town is the Town Hall's (Game.is_online_town()); tests replace it.
var online: Callable = Callable()

var _header: PanelContainer
var _header_label: Label
var _chevron: Glyph
var _rows: Dictionary = {}
var _more: PanelContainer
var _more_label: Label
## Task id -> the time (clock) its finished row goes.
var _lingering: Dictionary = {}
var _shown: int = 0


func _init() -> void:
	theme = AgentTheme.theme(AgentTheme.STATUS)
	custom_minimum_size = Vector2(WIDTH, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 6)
	folded = bool(Settings.get_value(FOLD_SETTING, false))
	_header = _plate(UiTokens.GOLD)
	_header.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_header.tooltip_text = "Fold or unfold the task list"
	_header.gui_input.connect(_on_header_input)
	var hrow := AgentUi.hbox(10, _header)
	hrow.add_child(Glyph.new("scroll", UiTokens.GOLD_BRIGHT, 16))
	_header_label = AgentUi.label("", "Section", hrow)
	_header_label.add_theme_color_override("font_color", UiTokens.GOLD_BRIGHT)
	_header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chevron = Glyph.new("chevron_up", UiTokens.GOLD, 12)
	hrow.add_child(_chevron)
	add_child(_header)
	_more = _plate(UiTokens.HUD_BORDER)
	_more.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mrow := AgentUi.hbox(8, _more)
	mrow.alignment = BoxContainer.ALIGNMENT_CENTER
	mrow.add_child(Glyph.new("plus", UiTokens.MINT, 12))
	_more_label = AgentUi.label("", "MonoSmall", mrow)
	add_child(_more)
	_more.visible = false
	visible = false


static func _plate(trim: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var box := ThemeBuilder.status_box(trim)
	box.content_margin_top = 5
	box.content_margin_bottom = 5
	box.content_margin_left = 12
	box.content_margin_right = 12
	box.shadow_size = 6.0
	p.add_theme_stylebox_override("panel", box)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	return p


func _signals() -> Array:
	return [[Realm.changed, _on_changed], [Realm.task_changed, _on_task_changed], [Realm.reset, _on_reset],
		[Game.world_started, _on_world_started], [Net.connection_changed, _on_connection_changed]]


func _enter_tree() -> void:
	for pair: Array in _signals():
		var sig: Signal = pair[0]
		var fn: Callable = pair[1]
		if not sig.is_connected(fn):
			sig.connect(fn)
	sync()


func _exit_tree() -> void:
	for pair: Array in _signals():
		var sig: Signal = pair[0]
		var fn: Callable = pair[1]
		if sig.is_connected(fn):
			sig.disconnect(fn)


func _now() -> float:
	if clock.is_valid():
		return float(clock.call())
	return float(Time.get_ticks_msec()) / 1000.0


func _is_online() -> bool:
	if online.is_valid():
		return bool(online.call())
	return Game.is_online_town()


func _on_world_started(_w: SimWorld) -> void:
	sync()


func _on_connection_changed(_is_up: bool) -> void:
	sync()


func _on_changed(kind: String, _id: String) -> void:
	if kind == "all" or kind == "task" or kind == "agent":
		sync()


func _on_reset() -> void:
	_lingering.clear()
	sync()


## A task that just ended keeps its row for LINGER_S seconds.
func _on_task_changed(t: Dictionary, previous_state: String) -> void:
	if Realm.is_terminal(t) and previous_state != "" and not previous_state in Protocol.TERMINAL_TASK_STATES:
		_lingering[J.gs(t, "id")] = _now() + LINGER_S
	sync()


func _process(_delta: float) -> void:
	if _lingering.is_empty():
		return
	var now := _now()
	var gone := false
	for id: String in _lingering.keys():
		if float(_lingering[id]) <= now:
			_lingering.erase(id)
			gone = true
	if gone:
		sync()


## The tasks the tracker lists, in its order: those that just ended (the first to end first), then
## the live ones by need; never sub-tasks.
func tracked_tasks() -> Array[Dictionary]:
	var ended: Array[Dictionary] = []
	var live: Array[Dictionary] = []
	for t: Dictionary in Realm.tasks.values():
		if t.get("parent_task_id") != null:
			continue
		if not Realm.is_terminal(t):
			live.append(t)
		elif _lingering.has(J.gs(t, "id")):
			ended.append(t)
	ended.sort_custom(_ended_before)
	live.sort_custom(_before)
	ended.append_array(live)
	return ended


func _ended_before(x: Dictionary, y: Dictionary) -> bool:
	return float(_lingering.get(J.gs(x, "id"), 0.0)) < float(_lingering.get(J.gs(y, "id"), 0.0))


## Row order: by ORDER, then oldest first.
static func _before(x: Dictionary, y: Dictionary) -> bool:
	var rx := ORDER.find(J.gs(x, "state"))
	var ry := ORDER.find(J.gs(y, "state"))
	if rx != ry:
		return rx < ry
	return J.gs(x, "created_at") < J.gs(y, "created_at")


## Brings the rows in line with Realm.
func sync() -> void:
	var tasks := tracked_tasks()
	var shown: Array[String] = []
	if not folded:
		for t in tasks.slice(0, MAX_ROWS):
			shown.append(J.gs(t, "id"))
	for id: String in _rows.keys():
		if not id in shown:
			var gone: TrackerRow = _rows[id]
			_rows.erase(id)
			gone.leave()
	var index := 1
	for id in shown:
		var t := Realm.task(id)
		var row: TrackerRow = _rows.get(id)
		if row == null:
			row = TrackerRow.new(id)
			row.pressed.connect(_on_row_pressed)
			_rows[id] = row
			add_child(row)
			row.arrive()
		row.show_task(t)
		move_child(row, index)
		index += 1
	move_child(_more, get_child_count() - 1)
	var live := 0
	var extra := 0
	for i in tasks.size():
		if Realm.is_terminal(tasks[i]):
			continue
		live += 1
		if not folded and i >= MAX_ROWS:
			extra += 1
	_more.visible = extra > 0
	_more_label.text = "%d MORE TASK%s" % [extra, "" if extra == 1 else "S"]
	_shown = tasks.size()
	_header_label.text = "TASKS  %d" % live
	_chevron.glyph = "chevron_down" if folded else "chevron_up"
	_update_visible()


func _update_visible() -> void:
	visible = enabled and _shown > 0 and _is_online()


## The row of a task, or null.
func row_for(task_id: String) -> TrackerRow:
	return _rows.get(task_id)


func set_folded(value: bool) -> void:
	folded = value
	Settings.set_value(FOLD_SETTING, value)
	sync()


func _on_header_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		set_folded(not folded)
		accept_event()


func _on_row_pressed(task_id: String) -> void:
	var t := Realm.task(task_id)
	var agent_id := J.gs(t, "agent_id")
	match J.gs(t, "state"):
		Protocol.TaskState.AWAITING_REVIEW, Protocol.TaskState.ACCEPTING:
			review_requested.emit(task_id)
		Protocol.TaskState.AWAITING_APPROVAL:
			approvals_requested.emit(agent_id)
		_:
			focus_requested.emit(agent_id)


## The colour a state is written in (the tracker's STATUS look).
static func state_color(state: String) -> Color:
	var look := AgentTheme.STATUS
	match state:
		Protocol.TaskState.AWAITING_APPROVAL, Protocol.TaskState.PAUSED:
			return AgentTheme.c(look, "warn")
		Protocol.TaskState.AWAITING_REVIEW, Protocol.TaskState.ACCEPTING, Protocol.TaskState.ACCEPTED:
			return AgentTheme.c(look, "accent2")
		Protocol.TaskState.FAILED:
			return AgentTheme.c(look, "bad")
		Protocol.TaskState.RUNNING, Protocol.TaskState.PREPARING:
			return AgentTheme.c(look, "good")
		Protocol.TaskState.QUEUED, Protocol.TaskState.IN_TRANSIT:
			return AgentTheme.c(look, "info")
	return AgentTheme.c(look, "faint")


## What a click on a row of this state does, for its tooltip.
static func action_text(state: String, agent_name: String) -> String:
	match state:
		Protocol.TaskState.AWAITING_REVIEW, Protocol.TaskState.ACCEPTING:
			return "Click to open the review."
		Protocol.TaskState.AWAITING_APPROVAL:
			return "Click to answer the petition."
	return "Click to find %s." % agent_name


## A row's words and colour for task `t`: {state, title, sub, color, tooltip}.
static func row_text(t: Dictionary) -> Dictionary:
	var state := J.gs(t, "state")
	var agent_name := J.gs(Realm.agent(J.gs(t, "agent_id")), "name", "An agent")
	var what := AgentUi.state_text(state)
	if state == Protocol.TaskState.PAUSED:
		what = "Paused: %s" % AgentUi.pause_text(J.gs(t, "state_reason"))
	var title := J.gs(t, "title", "Untitled task")
	return {
		"state": state,
		"title": title,
		"sub": "%s  ·  %s" % [agent_name.to_upper(), what.to_upper()],
		"color": state_color(state),
		"tooltip": "%s\n%s, %s.\n%s" % [title, agent_name, what.to_lower(), action_text(state, agent_name)],
	}


## One task: its seal, title, agent and state. Clickable; fades in when it arrives and out when it
## leaves.
class TrackerRow:
	extends PanelContainer

	signal pressed(task_id: String)

	var task_id: String = ""
	var seal: RiveSprite
	var title: Label
	var sub: Label
	## Fading out: out of the list's layout, and its clicks do nothing.
	var leaving: bool = false
	var _box: CraftedBox
	var _trim: Color = UiTokens.HUD_BORDER
	var _hover: bool = false

	func _init(id: String = "") -> void:
		task_id = id
		_box = ThemeBuilder.status_box(_trim)
		_box.content_margin_left = 6
		_box.content_margin_right = 12
		_box.content_margin_top = 4
		_box.content_margin_bottom = 4
		_box.shadow_size = 6.0
		add_theme_stylebox_override("panel", _box)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var row := AgentUi.hbox(10, self)
		seal = RiveSprite.new("task_seal", "", TaskTracker.SEAL_PX)
		row.add_child(seal)
		var col := AgentUi.vbox(0, row)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		title = AgentUi.label("", "BodyItalic", col)
		title.add_theme_color_override("font_color", AgentTheme.c(AgentTheme.STATUS, "text"))
		title.clip_text = true
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		sub = AgentUi.label("", "MonoSmall", col)
		sub.clip_text = true
		sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		mouse_entered.connect(_set_hover.bind(true))
		mouse_exited.connect(_set_hover.bind(false))

	func show_task(t: Dictionary) -> void:
		var info := TaskTracker.row_text(t)
		seal.set_state(String(info["state"]))
		title.text = String(info["title"])
		sub.text = String(info["sub"])
		var col: Color = info["color"]
		sub.add_theme_color_override("font_color", col)
		_trim = col
		_restyle()
		tooltip_text = String(info["tooltip"])

	func _set_hover(on: bool) -> void:
		_hover = on
		_restyle()

	func _restyle() -> void:
		_box.trim_color = Color(_trim, 1.0 if _hover else 0.62)
		_box.top_color = Color(0.12, 0.15, 0.34, 0.96) if _hover else Color(0.09, 0.11, 0.27, 0.96)
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		# A leaving row still takes its clicks, so none lands in the town behind it.
		if not mb.pressed and not leaving:
			pressed.emit(task_id)
		accept_event()

	func _make_custom_tooltip(for_text: String) -> Object:
		return CraftedTooltip.make(for_text) if for_text != "" else null

	func arrive() -> void:
		modulate.a = 0.0
		var tw := create_tween()
		tw.tween_property(self, "modulate:a", 1.0, 0.22)

	## Fades out where it stands: as a top-level control it leaves the list's layout at once, so
	## the rows that stay close up instead of moving around it.
	func leave() -> void:
		leaving = true
		mouse_default_cursor_shape = Control.CURSOR_ARROW
		tooltip_text = ""
		var at := global_position
		var width := size.x
		top_level = true
		global_position = at
		size.x = width
		var tw := create_tween()
		tw.tween_property(self, "modulate:a", 0.0, 0.25)
		tw.tween_callback(queue_free)
