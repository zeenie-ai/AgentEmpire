class_name ApprovalCard
extends PanelContainer
## One petition (a pending approval) in the approval tray, as an anime status window whose trim
## and left edge take the category's colour:
## - who asks: the agent's portrait (click: focus_requested) and name, what it wants to do;
## - the category badge (read, write, command, network, outside workspace, MCP), the risk and
##   the harness tool;
## - the summary in bold and the agent's reason in italics;
## - the request itself, expandable, in monospace;
## - how long it has waited; past economy incidents.approval_louder_after_s the age turns amber
##   and the border pulses;
## - a note when the task's Mana seal is spent (seal_exhausted).
## Answers go through Game.link.respond_approval: Allow once, Allow for this task, Always for this
## agent, or Deny, which first asks for an optional word to the agent. The approval_resolved
## event removes the card (ApprovalTray).
## A collapsed card (the tray keeps one card open) shows one line: who, what and how long; a
## click asks to open it (expand_requested).

signal focus_requested(agent_id: String)
## The Town Hall took the answer.
signal answered(approval_id: String, decision: String, scope: String)
## The collapsed card was clicked.
signal expand_requested(approval_id: String)

const Protocol = preload("res://net/protocol.gd")

var approval: Dictionary = {}
var approval_id: String = ""
var agent_id: String = ""
var link: Object = null

var allow_once_button: Button
var allow_task_button: Button
var allow_agent_button: Button
var deny_button: Button
var confirm_deny_button: Button
var deny_edit: LineEdit

var expanded: bool = true:
	set(value):
		expanded = value
		if _full != null:
			_full.visible = value
			_compact.visible = not value
			mouse_default_cursor_shape = Control.CURSOR_ARROW if value else Control.CURSOR_POINTING_HAND
			tooltip_text = "" if value else "Open this petition"

var _color: Color = Color.WHITE
var _full: VBoxContainer
var _compact: HBoxContainer
var _portrait: AgentPortrait
var _name: Label
var _age: Label
var _age_compact: Label
var _details: PanelContainer
var _details_toggle: Button
var _buttons: VBoxContainer
var _deny_box: VBoxContainer
var _result: Label
var _error: Label
var _overlay: Control
var _busy: bool = false
var _louder: bool = false
var _t: float = 0.0
var _tick: float = 0.0


func _init() -> void:
	theme = AgentTheme.theme(AgentTheme.STATUS)
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(ApprovalTray.WIDTH, 0)
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	resized.connect(func() -> void: pivot_offset = Vector2(size.x, 0))


## Fills the card from an Approval object.
func setup(a: Dictionary, link_override: Object = null) -> ApprovalCard:
	approval = a
	approval_id = J.gs(a, "id")
	agent_id = J.gs(a, "agent_id")
	if link_override != null:
		link = link_override
	_color = AgentUi.category_color(J.gs(a, "category"))
	add_theme_stylebox_override("panel", AgentTheme.petition_box(_color))
	_build()
	_refresh_age()
	return self


func _link() -> Object:
	return link if link != null else Game.link


func _build() -> void:
	for c in get_children():
		if c != _overlay:
			remove_child(c)
			c.queue_free()
	var look := AgentTheme.STATUS
	var agent := Realm.agent(agent_id)
	var who := J.gs(agent, "name", "An agent")
	var category := J.gs(approval, "category")
	_build_compact(agent, who, category)
	var col := AgentUi.vbox(7, self)
	_full = col

	var top := AgentUi.hbox(12, col)
	_portrait = AgentPortrait.new(50)
	_portrait.set_agent(agent, "waiting")
	_portrait.clickable = true
	_portrait.tooltip_text = "Show %s in town" % who
	_portrait.pressed.connect(func() -> void: focus_requested.emit(agent_id))
	top.add_child(_portrait)
	var tcol := AgentUi.vbox(1, top)
	tcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tcol.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var nrow := AgentUi.hbox(8, tcol)
	_name = AgentUi.label(who.to_upper(), "CardTitle", nrow)
	_name.add_theme_font_size_override("font_size", 15)
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.clip_text = true
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_age = AgentUi.label("", "MonoSmall", nrow)
	_age.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var verb := AgentUi.label(AgentUi.category_verb(category).to_upper(), "MonoSmall", tcol)
	verb.add_theme_color_override("font_color", _color.lightened(0.1))

	var tags := AgentUi.hbox(6, col)
	AgentUi.pill(AgentUi.category_name(category), _color, true, tags)
	var risk := J.gs(approval, "risk", Protocol.Risk.MEDIUM)
	AgentUi.pill("%s risk" % risk, AgentUi.risk_color(risk), false, tags)
	var tool := J.gs(approval, "tool")
	if tool != "":
		var tl := AgentUi.label(tool, "MonoSmall", tags)
		tl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tl.add_theme_color_override("font_color", AgentTheme.c(look, "soft"))

	var summary := AgentUi.para(J.gs(approval, "summary", "Asks for permission."), "BodyStrong", col)
	summary.add_theme_color_override("font_color", Color("#f4f8ff"))
	var reason := J.gs(approval, "reason")
	if reason.strip_edges() != "":
		var r := AgentUi.para("“%s”" % reason.strip_edges(), "BodyItalic", col)
		r.add_theme_font_size_override("font_size", 14)
		r.add_theme_color_override("font_color", AgentTheme.c(look, "soft"))

	if J.b(approval.get("seal_exhausted"), false):
		var note := AgentUi.callout(look, AgentTheme.c(look, "warn"),
			"This task has spent its whole Mana seal. Allowing lets it keep spending past the seal.", "", "mana", col)
		(AgentUi.callout_text(note)).add_theme_font_size_override("font_size", 13)

	var preview := J.gs(approval, "input_preview")
	if preview.strip_edges() != "":
		_details_toggle = Button.new()
		_details_toggle.theme_type_variation = "ChipButton"
		_details_toggle.toggle_mode = true
		_details_toggle.focus_mode = Control.FOCUS_NONE
		_details_toggle.text = "SHOW THE REQUEST"
		_details_toggle.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		_details_toggle.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_details_toggle.toggled.connect(_on_details_toggled)
		col.add_child(_details_toggle)
		_details = PanelContainer.new()
		_details.add_theme_stylebox_override("panel", AgentTheme.slate_box(look))
		_details.visible = false
		col.add_child(_details)
		var sc := ScrollContainer.new()
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		# About 46 monospace characters fit a line; long requests scroll past eight lines.
		var lines := 0
		for line in preview.split("\n"):
			lines += maxi(1, ceili(float(line.length()) / 46.0))
		sc.custom_minimum_size = Vector2(0, mini(160, 18 * lines + 6))
		_details.add_child(sc)
		var code := AgentUi.para(preview, "Mono", sc)
		code.add_theme_font_size_override("font_size", 12)
		code.add_theme_color_override("font_color", Color("#cfe3ff"))
		code.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY

	_error = AgentUi.para("", "BodyItalic", col)
	_error.add_theme_color_override("font_color", AgentTheme.c(look, "bad"))
	_error.visible = false

	_buttons = AgentUi.vbox(6, col)
	var scopes := J.a(approval.get("scopes"))
	if scopes.is_empty():
		scopes = [Protocol.ApprovalScope.ONCE]
	var reach := AgentUi.approval_reach(approval)
	var row_a := AgentUi.hbox(6, _buttons)
	allow_once_button = _button("Allow once", "", "Allow once\nLet %s do just this, this one time." % who, row_a)
	allow_once_button.pressed.connect(answer.bind(Protocol.ApprovalDecision.ALLOW, Protocol.ApprovalScope.ONCE))
	if Protocol.ApprovalScope.TASK in scopes:
		allow_task_button = _button("Allow for this task", "GhostButton", "Allow for this task\nAllow %s without asking until this task ends." % reach, row_a)
		allow_task_button.pressed.connect(answer.bind(Protocol.ApprovalDecision.ALLOW, Protocol.ApprovalScope.TASK))
	var row_b := AgentUi.hbox(6, _buttons)
	if Protocol.ApprovalScope.AGENT in scopes:
		var label_text := "Always for %s" % who if who.length() <= 10 else "Always for this agent"
		allow_agent_button = _button(label_text, "GhostButton", "Always for %s\nAllow %s without asking, on every task from now on." % [who, reach], row_b)
		allow_agent_button.pressed.connect(answer.bind(Protocol.ApprovalDecision.ALLOW, Protocol.ApprovalScope.AGENT))
	elif scopes.size() == 1:
		var note := AgentUi.label("HIGH RISK: ONLY ONE AT A TIME", "MonoSmall", row_b)
		note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		note.add_theme_color_override("font_color", AgentUi.risk_color(Protocol.Risk.HIGH))
		note.tooltip_text = "High-risk requests cannot be allowed for a whole task or for the agent."
		note.mouse_filter = Control.MOUSE_FILTER_PASS
	deny_button = _button("Deny", "DangerButton", "Refuse; you can tell the agent why.", row_b)
	deny_button.pressed.connect(_ask_deny)

	_deny_box = AgentUi.vbox(6, col)
	_deny_box.visible = false
	deny_edit = LineEdit.new()
	deny_edit.placeholder_text = "Tell %s why (optional)" % who
	deny_edit.max_length = 4000
	deny_edit.text_submitted.connect(func(_t: String) -> void: _confirm_deny())
	_deny_box.add_child(deny_edit)
	var drow := AgentUi.hbox(6, _deny_box)
	var back := _button("Back", "GhostButton", "", drow)
	back.pressed.connect(_cancel_deny)
	confirm_deny_button = _button("Deny", "DangerButton", "Refuse the request.", drow)
	confirm_deny_button.pressed.connect(_confirm_deny)

	_result = AgentUi.label("", "Section", col)
	_result.visible = false
	_result.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	if _overlay.get_parent() == null:
		add_child(_overlay)
	else:
		move_child(_overlay, get_child_count() - 1)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	expanded = expanded


func _build_compact(agent: Dictionary, who: String, category: String) -> void:
	_compact = AgentUi.hbox(10, self)
	_compact.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var p := AgentPortrait.new(36)
	p.show_rank = false
	p.set_agent(agent, "waiting")
	_compact.add_child(p)
	var col := AgentUi.vbox(0, _compact)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := AgentUi.hbox(8, col)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var n := AgentUi.label(who.to_upper(), "CardTitle", row)
	n.add_theme_font_size_override("font_size", 13)
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_age_compact = AgentUi.label("", "MonoSmall", row)
	var s := AgentUi.label(J.gs(approval, "summary", "Asks for permission."), "Body", col)
	s.add_theme_font_size_override("font_size", 14)
	s.add_theme_color_override("font_color", Color("#e8eef8"))
	s.clip_text = true
	s.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var tag := AgentUi.pill(AgentUi.category_name(category), _color, true, _compact)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _gui_input(event: InputEvent) -> void:
	if expanded:
		return
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		accept_event()
		expand_requested.emit(approval_id)


func _button(text: String, variation: String, tip: String, parent: Control) -> Button:
	var b := AgentUi.TipButton.new()
	b.text = text.to_upper()
	if variation != "":
		b.theme_type_variation = variation
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 34)
	b.add_theme_font_size_override("font_size", 12)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.clip_text = true
	if tip != "":
		b.tooltip_text = tip
	parent.add_child(b)
	return b


func _on_details_toggled(on: bool) -> void:
	_details.visible = on
	_details_toggle.text = "HIDE THE REQUEST" if on else "SHOW THE REQUEST"


# --- answering -------------------------------------------------------------------------------------

## Sends the answer. decision: "allow" or "deny"; scope: "once", "task" or "agent".
func answer(decision: String, scope: String, message: String = "") -> void:
	if _busy:
		return
	_busy = true
	_error.visible = false
	_set_enabled(false)
	var req: NetRequest = _link().respond_approval(approval_id, decision, scope, message)
	if req == null:
		_busy = false
		_set_enabled(true)
		return
	req.done.connect(_on_answered.bind(decision, scope))


func _on_answered(req: NetRequest, decision: String, scope: String) -> void:
	_busy = false
	if req.ok:
		_show_result(decision, scope)
		answered.emit(approval_id, decision, scope)
		return
	_set_enabled(true)
	_error.text = req.error_message()
	_error.visible = true


func _ask_deny() -> void:
	_buttons.visible = false
	_deny_box.visible = true
	deny_edit.grab_focus()


func _cancel_deny() -> void:
	_deny_box.visible = false
	_buttons.visible = true


func _confirm_deny() -> void:
	answer(Protocol.ApprovalDecision.DENY, Protocol.ApprovalScope.ONCE, deny_edit.text)


func _set_enabled(on: bool) -> void:
	for b: Button in [allow_once_button, allow_task_button, allow_agent_button, deny_button, confirm_deny_button]:
		if b != null:
			b.disabled = not on


func _show_result(decision: String, scope: String) -> void:
	_buttons.visible = false
	_deny_box.visible = false
	var text := "Denied"
	var col := AgentTheme.c(AgentTheme.STATUS, "bad")
	if decision == Protocol.ApprovalDecision.ALLOW:
		col = AgentTheme.c(AgentTheme.STATUS, "good")
		match scope:
			Protocol.ApprovalScope.TASK:
				text = "Allowed for this task"
			Protocol.ApprovalScope.AGENT:
				text = "Always allowed"
			_:
				text = "Allowed once"
	_result.text = text.to_upper()
	_result.add_theme_color_override("font_color", col)
	_result.visible = true


# --- age and pulse -----------------------------------------------------------------------------------

func louder_after_s() -> float:
	return float(Economy.data.section("incidents").get("approval_louder_after_s", 120))


func _refresh_age() -> void:
	var waited := AgentUi.seconds_since(J.gs(approval, "created_at"))
	_age.text = AgentUi.ago_text(waited).to_upper()
	_age_compact.text = _age.text
	var was := _louder
	_louder = waited >= louder_after_s()
	var age_color := AgentTheme.c(AgentTheme.STATUS, "warn") if _louder else AgentTheme.c(AgentTheme.STATUS, "muted")
	_age.add_theme_color_override("font_color", age_color)
	_age_compact.add_theme_color_override("font_color", age_color)
	if _louder:
		_age.tooltip_text = "Waiting a long time: the agent is paused until you answer."
	if _louder != was:
		_overlay.queue_redraw()


func is_louder() -> bool:
	return _louder


func _process(delta: float) -> void:
	_tick -= delta
	if _tick <= 0.0:
		_tick = 1.0
		_refresh_age()
	if _louder:
		_t += delta
		_overlay.queue_redraw()


func _draw() -> void:
	# The category's colour down the left edge.
	var r := Rect2(Vector2(3, 3), Vector2(4, size.y - 6))
	draw_rect(r, Color(_color, 0.85))
	draw_rect(Rect2(r.position + Vector2(4, 0), Vector2(1, r.size.y)), Color(0, 0, 0, 0.35))


func _draw_overlay() -> void:
	if not _louder:
		return
	var k := 0.5 + 0.5 * sin(_t * 4.2)
	var warn := AgentTheme.c(AgentTheme.STATUS, "warn")
	var rect := Rect2(Vector2.ZERO, _overlay.size)
	_overlay.draw_rect(rect.grow(1.0), Color(warn, 0.25 + 0.6 * k), false, 2.0)
	_overlay.draw_rect(rect.grow(4.0), Color(warn, 0.12 * k), false, 3.0)
