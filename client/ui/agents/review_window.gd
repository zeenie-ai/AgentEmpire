class_name ReviewWindow
extends WindowFrame
## Reviews a finished task (awaiting_review, or accepting after a blocked merge) on parchment:
## the title, agent, attempt and size; the agent's summary and the acceptance criteria; the files
## changed (added and removed lines), the Rite (passed or failed, with its output), the Mana used
## against the seal ("≈" when estimated); the changed files and a patch viewer (from
## Game.link.task_detail); and the Chronicle, collapsed.
##
## Decisions, in the tray above the footer:
## - Accept, integrating by Merge (the default for git work folders), Keep branch or Export
##   (plain folders). Rewards come back in a banner (RP, XP and resources). When the merge is
##   blocked (rewards null, merge.blocked_reason), the reason is explained and "Keep branch
##   instead" offered.
## - Send back, with feedback (required).
## - Abandon, after a confirmation.
## Emits accepted(task_id, rewards), sent_back(task_id) or abandoned(task_id). Live from Realm.

signal accepted(task_id: String, rewards: Dictionary)
signal sent_back(task_id: String)
signal abandoned(task_id: String)

const Protocol = preload("res://net/protocol.gd")
const FEEDBACK_MAX := 16000

var task_id: String = ""
var detail: Dictionary = {}
var integrate: String = Protocol.Integrate.MERGE
## "decide", "send_back", "abandon", "busy", "blocked", "done" or "gone".
var mode: String = "decide"

var feedback_edit: TextEdit

var _portrait: AgentPortrait
var _title: Label
var _meta: Label
var _state_pill: PanelContainer
var _summary: Label
var _no_deliverable: PanelContainer
var _criteria_box: VBoxContainer
var _files_value: Label
var _added_value: Label
var _removed_value: Label
var _rite_pill: PanelContainer
var _rite_cmd: Label
var _mana_bar: ManaBar
var _mana_usd: Label
var _rite_toggle: Button
var _rite_output: PanelContainer
var _rite_text: Label
var _files_list: VBoxContainer
var _files_group: ButtonGroup
var _patch: PatchView
var _changes_note: Label
var _chronicle_toggle: Button
var _chronicle: ChronicleView
var _merge_note: PanelContainer
var _integrate_row: HBoxContainer
var _integrate_buttons: Dictionary = {}
var _integrate_hint: Label
var _tray_box: VBoxContainer
var _blocked_reason: String = ""


func _init() -> void:
	super()
	configure("Review", "A finished task", AgentTheme.DOCUMENT, 1140)
	set_title_icon(Glyph.new("seal", UiTokens.BTN, 30))
	_build_head()
	_build_body()
	_build_tray()


## Reviews `id`. Returns the window, so the host can open it in one line.
func setup(id: String, link_override: Object = null) -> ReviewWindow:
	task_id = id
	if link_override != null:
		link = link_override
	var t := Realm.task(id)
	integrate = default_integrate()
	_refresh()
	_set_mode("decide")
	if J.gs(t, "state") == Protocol.TaskState.ACCEPTING:
		_show_merge_incident()
	_chronicle.setup(id)
	set_status("Look over the work, then accept it, send it back or set it aside.")
	return self


func _window_opened() -> void:
	listen(Realm.task_changed, _on_task_changed)
	listen(Realm.changed, _on_realm_changed)
	if detail.is_empty() and task_id != "":
		_load_detail()


# --- building ----------------------------------------------------------------------------------------

func _build_head() -> void:
	var row := AgentUi.hbox(16, head)
	_portrait = AgentPortrait.new(64)
	row.add_child(_portrait)
	var col := AgentUi.vbox(2, row)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title = AgentUi.label("", "Display", col)
	_title.add_theme_font_size_override("font_size", 28)
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_meta = AgentUi.label("", "MonoSmall", col)
	var pcol := AgentUi.vbox(0, row)
	pcol.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_state_pill = AgentUi.pill("", AgentTheme.c(look, "accent2"), true, pcol)
	show_head(true)


func _build_body() -> void:
	AgentUi.section("The result", look, "", body)
	_summary = AgentUi.para("", "Body", body)
	_summary.add_theme_font_size_override("font_size", 16)
	_summary.add_theme_color_override("font_color", AgentTheme.c(look, "text"))
	_no_deliverable = AgentUi.callout(look, AgentTheme.c(look, "warn"),
		"The agent reports nothing to integrate. Accepting it pays no reward; sending it back with notes usually works better.", "Nothing delivered", "warning", body)
	_no_deliverable.visible = false
	_criteria_box = AgentUi.vbox(4, body)

	var stats := AgentUi.hbox(12, body)
	var t1 := _tile(stats, "Changes")
	var crow := AgentUi.hbox(10, t1)
	_files_value = AgentUi.label("", "Value", crow)
	_added_value = AgentUi.label("", "Value", crow)
	_added_value.add_theme_color_override("font_color", AgentTheme.c(look, "good"))
	_removed_value = AgentUi.label("", "Value", crow)
	_removed_value.add_theme_color_override("font_color", AgentTheme.c(look, "bad"))
	var t2 := _tile(stats, "Rite")
	var rrow := AgentUi.hbox(8, t2)
	_rite_pill = AgentUi.pill("", AgentTheme.c(look, "good"), true, rrow)
	_rite_cmd = AgentUi.label("", "Mono", rrow)
	_rite_cmd.clip_text = true
	_rite_cmd.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_rite_cmd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var t3 := _tile(stats, "Mana")
	_mana_bar = ManaBar.new(220, 18)
	_mana_bar.look = AgentTheme.DOCUMENT
	_mana_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t3.add_child(_mana_bar)
	_mana_usd = AgentUi.label("", "MonoSmall", t3)

	var rite_row := AgentUi.hbox(10, body)
	_rite_toggle = _chip("Show the Rite's output", rite_row)
	_rite_toggle.toggle_mode = true
	_rite_toggle.toggled.connect(_on_rite_toggled)
	_rite_output = PanelContainer.new()
	_rite_output.add_theme_stylebox_override("panel", AgentTheme.slate_box(look))
	_rite_output.visible = false
	body.add_child(_rite_output)
	_rite_text = AgentUi.para("", "Mono", _rite_output)
	_rite_text.add_theme_font_size_override("font_size", 12)
	_rite_text.add_theme_color_override("font_color", Color("#d8dfea"))
	_rite_text.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY

	AgentUi.section("Changes", look, "", body)
	_changes_note = AgentUi.para("Fetching the changes from the Town Hall...", "Hint", body)
	var split := AgentUi.hbox(12, body)
	var list_panel := PanelContainer.new()
	list_panel.add_theme_stylebox_override("panel", AgentTheme.group_box(look))
	list_panel.custom_minimum_size = Vector2(320, 380)
	split.add_child(list_panel)
	var list_scroll := ScrollContainer.new()
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_panel.add_child(list_scroll)
	_files_list = AgentUi.vbox(2, list_scroll)
	_files_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_files_group = ButtonGroup.new()
	_patch = PatchView.new(look)
	_patch.custom_minimum_size = Vector2(0, 380)
	_patch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(_patch)

	var chron_row := AgentUi.hbox(10, body)
	_chronicle_toggle = _chip("Show the Chronicle", chron_row)
	_chronicle_toggle.toggle_mode = true
	_chronicle_toggle.toggled.connect(_on_chronicle_toggled)
	var hint := AgentUi.label("Everything the agent said and did on this task.", "Hint", chron_row)
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_chronicle = ChronicleView.new(look)
	_chronicle.custom_minimum_size = Vector2(0, 240)
	_chronicle.visible = false
	body.add_child(_chronicle)


func _tile(parent: Control, title: String) -> VBoxContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", AgentTheme.group_box(look))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(p)
	var col := AgentUi.vbox(6, p)
	AgentUi.label(title.to_upper(), "Section", col)
	return col


func _chip(text: String, parent: Control) -> Button:
	var b := Button.new()
	b.theme_type_variation = "ChipButton"
	b.text = text.to_upper()
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(b)
	return b


func _build_tray() -> void:
	_tray_box = AgentUi.vbox(10, tray)
	_merge_note = AgentUi.callout(look, AgentTheme.c(look, "bad"), "", "The merge was blocked", "warning", tray)
	_merge_note.visible = false
	_integrate_row = AgentUi.hbox(8, tray)
	var il := AgentUi.label("INTEGRATE", "Section", _integrate_row)
	il.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	il.custom_minimum_size.x = 96
	var group := ButtonGroup.new()
	for opt: Array in [[Protocol.Integrate.MERGE, "Merge", "merge"], [Protocol.Integrate.KEEP_BRANCH, "Keep branch", "git"], [Protocol.Integrate.EXPORT, "Export", "export"]]:
		var b := Button.new()
		b.theme_type_variation = "ChipButton"
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.text = String(opt[1]).to_upper()
		b.custom_minimum_size = Vector2(118, 30)
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.toggled.connect(_on_integrate_toggled.bind(String(opt[0])))
		_integrate_row.add_child(b)
		_integrate_buttons[String(opt[0])] = b
	_integrate_hint = AgentUi.para("", "Hint", _integrate_row)
	_integrate_hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	show_tray(true)


# --- data --------------------------------------------------------------------------------------------

func task() -> Dictionary:
	var t := J.gd(detail, "task")
	var live := Realm.task(task_id)
	return live if not live.is_empty() else t


func workspace_is_git() -> bool:
	var a := Realm.agent(J.gs(task(), "agent_id"))
	return J.gs(J.gd(a, "workspace"), "mode", Protocol.WorkspaceMode.GIT_WORKTREE) == Protocol.WorkspaceMode.GIT_WORKTREE


func default_integrate() -> String:
	return Protocol.Integrate.MERGE if workspace_is_git() else Protocol.Integrate.EXPORT


func _load_detail() -> void:
	var req: NetRequest = the_link().task_detail(task_id)
	if req == null:
		return
	req.done.connect(_on_detail)


func _on_detail(req: NetRequest) -> void:
	if not req.ok:
		_changes_note.text = "Could not fetch the changes: %s" % req.error_message()
		_changes_note.add_theme_color_override("font_color", AgentTheme.c(look, "bad"))
		return
	apply_detail(req.payload_dict())


## Shows a get_task_detail reply: {task, activity, diff?:{files, patch?}}.
func apply_detail(d: Dictionary) -> void:
	detail = d
	var diff := J.gd(d, "diff")
	var files := J.a(diff.get("files"))
	clear_box(_files_list)
	for f: Variant in files:
		_files_list.add_child(_file_row(J.d(f)))
	var patch := J.gs(diff, "patch")
	_patch.set_patch(patch)
	if files.is_empty() and patch == "":
		_changes_note.text = "The agent changed no files."
	elif patch == "":
		_changes_note.text = "The patch is too large to show here; the file list is complete."
	else:
		_changes_note.text = "Click a file to jump to its changes."
	_changes_note.remove_theme_color_override("font_color")
	_chronicle.add_entries(J.a(d.get("activity")))
	_chronicle_toggle.text = "SHOW THE CHRONICLE (%d)" % _chronicle.entry_count() if not _chronicle.visible else "HIDE THE CHRONICLE"
	_refresh()


func _file_row(f: Dictionary) -> Button:
	var path := J.gs(f, "path")
	var b := Button.new()
	b.theme_type_variation = "RowButton"
	b.toggle_mode = true
	b.button_group = _files_group
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 44)
	b.tooltip_text = path
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var row := AgentUi.hbox(8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 10
	row.offset_right = -8
	var status := J.gs(f, "status", "modified")
	var letter := String({"added": "A", "modified": "M", "deleted": "D", "renamed": "R", "copied": "C", "type_changed": "T"}.get(status, "?"))
	var col: Color = {"added": AgentTheme.c(look, "good"), "deleted": AgentTheme.c(look, "bad"), "renamed": AgentTheme.c(look, "info")}.get(status, AgentTheme.c(look, "accent2"))
	var badge := AgentUi.pill(letter, col, true, row)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.tooltip_text = status
	var names := AgentUi.vbox(0, row)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	names.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fname := AgentUi.label(path.get_file(), "Mono", names)
	fname.clip_text = true
	fname.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var dir := AgentUi.label(path.get_base_dir() if path.get_base_dir() != "" else "(top level)", "MonoSmall", names)
	dir.clip_text = true
	dir.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var plus := AgentUi.label("+%d" % J.gi(f, "added"), "MonoSmall", row)
	plus.add_theme_color_override("font_color", AgentTheme.c(look, "good"))
	plus.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var minus := AgentUi.label("-%d" % J.gi(f, "removed"), "MonoSmall", row)
	minus.add_theme_color_override("font_color", AgentTheme.c(look, "bad"))
	minus.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	b.pressed.connect(func() -> void: _patch.jump_to_file(path))
	return b


func _refresh() -> void:
	var t := task()
	if t.is_empty():
		return
	var a := Realm.agent(J.gs(t, "agent_id"))
	var sz := J.gs(t, "size", "M")
	_portrait.set_agent(a, "review")
	_title.text = J.gs(t, "title", "Untitled task")
	_title.tooltip_text = _title.text
	_meta.text = "%s  ·  %s  ·  %s  ·  %s" % [J.gs(a, "name", "Unknown agent").to_upper(), Economy.data.role_name(J.gs(a, "role")).to_upper(),
		AgentUi.harness_name(J.gs(a, "provider")).to_upper(), J.gs(a, "model").to_upper()]
	set_title("Review", "Attempt %d  ·  %s  ·  %s" % [J.gi(t, "attempt", 1), AgentUi.size_label(sz), J.gs(a, "name", "Unknown agent")])
	var state := J.gs(t, "state")
	AgentUi.set_pill(_state_pill, AgentUi.state_text(state), _state_color(state), true)

	var result := J.gd(t, "result")
	_summary.text = J.gs(result, "summary", "The agent left no summary.")
	_no_deliverable.visible = not result.is_empty() and not J.b(result.get("deliverable"), true)
	clear_box(_criteria_box)
	var acc := J.a(t.get("acceptance"))
	if not acc.is_empty():
		AgentUi.label("ACCEPTANCE CRITERIA", "MonoSmall", _criteria_box)
		for c: Variant in acc:
			var row := AgentUi.hbox(8, _criteria_box)
			row.add_child(Glyph.new("diamond", AgentTheme.c(look, "accent"), 9))
			AgentUi.para(J.s(c), "Body", row)

	var stat := J.gd(result, "diff_stat")
	var files := J.gi(stat, "files")
	_files_value.text = "%d file%s" % [files, "" if files == 1 else "s"]
	_added_value.text = "+%s" % AgentUi.group(J.gi(stat, "added"))
	_removed_value.text = "-%s" % AgentUi.group(J.gi(stat, "removed"))

	var rite := J.gd(result, "rite")
	var cmd := J.gs(t, "rite")
	if rite.is_empty():
		AgentUi.set_pill(_rite_pill, "No Rite" if cmd == "" else "Not run", AgentTheme.c(look, "faint"), false)
		_rite_cmd.text = cmd if cmd != "" else "none set"
		_rite_toggle.visible = false
	else:
		var passed := J.b(rite.get("passed"), false)
		AgentUi.set_pill(_rite_pill, "Passed" if passed else "Failed", AgentTheme.c(look, "good") if passed else AgentTheme.c(look, "bad"), true)
		_rite_cmd.text = cmd
		var tail := J.gs(rite, "output_tail")
		_rite_text.text = tail if tail != "" else "(no output)"
		_rite_toggle.visible = true
		if not passed and not _rite_toggle.button_pressed:
			_rite_toggle.button_pressed = true

	var mpm := float(AgentUi.micros_per_mana())
	var spent := float(J.gi(t, "spent_micros")) / mpm
	var seal := float(J.gi(t, "seal_micros")) / mpm
	var estimate := J.b(t.get("spent_is_estimate"), false)
	_mana_bar.set_values(spent, seal, 0.0, estimate)
	_mana_usd.text = "%s%s OF A %s SEAL" % ["ABOUT " if estimate else "", AgentUi.usd_text(J.gi(t, "spent_micros")), AgentUi.usd_text(J.gi(t, "seal_micros"))]
	_refresh_integrate()


func _state_color(state: String) -> Color:
	match state:
		Protocol.TaskState.ACCEPTED:
			return AgentTheme.c(look, "good")
		Protocol.TaskState.ACCEPTING:
			return AgentTheme.c(look, "warn")
		Protocol.TaskState.AWAITING_REVIEW:
			return AgentTheme.c(look, "accent2")
	return AgentTheme.c(look, "faint")


## Git work folders merge or keep the branch; plain folders export (the Town Hall refuses the
## other combinations).
func _refresh_integrate() -> void:
	var git := workspace_is_git()
	if (integrate == Protocol.Integrate.EXPORT) == git:
		integrate = default_integrate()
	for key: String in _integrate_buttons:
		var b: Button = _integrate_buttons[key]
		var for_git := key != Protocol.Integrate.EXPORT
		b.disabled = for_git != git
		var why := ""
		if b.disabled:
			why = "\nOnly for work folders that are git repositories." if for_git else "\nOnly for plain work folders; a git repository merges or keeps its branch."
		b.tooltip_text = _integrate_text(key) + why
		b.set_pressed_no_signal(key == integrate)
	_integrate_hint.text = _integrate_text(integrate)


func _integrate_text(key: String) -> String:
	match key:
		Protocol.Integrate.MERGE:
			return "Merge the agent's branch into your checkout (which must be clean)."
		Protocol.Integrate.KEEP_BRANCH:
			return "Accept, but leave the work on its branch for you to merge later."
	return "Write the changed files back into your work folder, all or nothing."


func _on_integrate_toggled(on: bool, key: String) -> void:
	if on:
		integrate = key
		_integrate_hint.text = _integrate_text(key)


func _on_rite_toggled(on: bool) -> void:
	_rite_output.visible = on
	_rite_toggle.text = "HIDE THE RITE'S OUTPUT" if on else "SHOW THE RITE'S OUTPUT"


func _on_chronicle_toggled(on: bool) -> void:
	_chronicle.visible = on
	_chronicle_toggle.text = "HIDE THE CHRONICLE" if on else "SHOW THE CHRONICLE (%d)" % _chronicle.entry_count()


func _show_merge_incident() -> void:
	for i: Dictionary in Realm.incidents.values():
		if J.gs(i, "kind") == Protocol.IncidentKind.MERGE_BLOCKED and J.gs(J.gd(i, "subject"), "task_id") == task_id:
			AgentUi.callout_text(_merge_note).text = J.gs(i, "message", "The last merge was blocked.") + " Fix the cause and accept again, or keep the work on its branch."
			_merge_note.visible = true
			return


# --- modes ----------------------------------------------------------------------------------------------

func _set_mode(m: String) -> void:
	mode = m
	clear_footer()
	clear_box(_tray_box)
	_integrate_row.visible = m == "decide" or m == "blocked" or m == "busy"
	match m:
		"decide", "busy":
			var abandon := add_button("Abandon", "danger", "Set the task aside with no reward.")
			abandon.pressed.connect(_set_mode.bind("abandon"))
			var back := add_button("Send back", "ghost", "Return it to the agent with your notes.")
			back.pressed.connect(_set_mode.bind("send_back"))
			var accept_button := add_button("Accept", "primary", "Accept the work and collect the reward.")
			accept_button.custom_minimum_size.x = 150
			accept_button.pressed.connect(accept)
			for b in footer.get_children():
				if b is Button:
					(b as Button).disabled = m == "busy"
		"send_back":
			var box := AgentUi.vbox(6, _tray_box)
			AgentUi.label("NOTES FOR %s" % J.gs(Realm.agent(J.gs(task(), "agent_id")), "name", "the agent").to_upper(), "Section", box)
			feedback_edit = TextEdit.new()
			feedback_edit.custom_minimum_size = Vector2(0, 96)
			feedback_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			feedback_edit.placeholder_text = "What should change? Be specific: the agent starts a new attempt from your notes."
			feedback_edit.text_changed.connect(_on_feedback_changed)
			box.add_child(feedback_edit)
			feedback_edit.grab_focus.call_deferred()
			var cancel := add_button("Back", "ghost")
			cancel.pressed.connect(_set_mode.bind("decide"))
			var send := add_button("Send back", "primary", "Send the task back with these notes.")
			send.custom_minimum_size.x = 150
			send.disabled = true
			send.name = "SendBack"
			send.pressed.connect(send_back)
			set_status("The agent starts attempt %d from your notes; Mana already spent still counts against the seal." % (J.gi(task(), "attempt", 1) + 1))
		"abandon":
			AgentUi.callout(look, AgentTheme.c(look, "bad"),
				"The agent earns nothing for this task. Its workspace is kept until you discard it, so nothing is lost yet.", "Abandon this task?", "warning", _tray_box)
			var cancel2 := add_button("Back", "ghost")
			cancel2.pressed.connect(_set_mode.bind("decide"))
			var go := add_button("Abandon task", "danger")
			go.custom_minimum_size.x = 150
			go.pressed.connect(abandon)
			set_status("")
		"blocked":
			AgentUi.callout(look, AgentTheme.c(look, "bad"), AgentUi.merge_blocked_text(_blocked_reason), "The merge was blocked", "warning", _tray_box)
			var close_b := add_button("Close", "ghost")
			close_b.pressed.connect(close)
			var retry := add_button("Try again", "ghost", "Accept again with the choice above.")
			retry.pressed.connect(accept)
			var keep := add_button("Keep branch instead", "primary", "Accept and leave the work on its branch.")
			keep.custom_minimum_size.x = 210
			keep.pressed.connect(accept.bind(Protocol.Integrate.KEEP_BRANCH))
			keep.visible = workspace_is_git()
		"done":
			var close_d := add_button("Close", "primary")
			close_d.custom_minimum_size.x = 150
			close_d.pressed.connect(close)
		"gone":
			AgentUi.callout(look, AgentTheme.c(look, "info"), "This task was answered elsewhere and no longer waits for review.", "", "info", _tray_box)
			var close_g := add_button("Close", "primary")
			close_g.pressed.connect(close)
	_tray_box.visible = _tray_box.get_child_count() > 0
	_queue_fit()


func _on_feedback_changed() -> void:
	if feedback_edit.text.length() > FEEDBACK_MAX:
		feedback_edit.text = feedback_edit.text.substr(0, FEEDBACK_MAX)
	var send := footer.get_node_or_null("SendBack") as Button
	if send != null:
		send.disabled = feedback_edit.text.strip_edges() == ""


func _on_escape() -> void:
	if mode == "send_back" or mode == "abandon":
		_set_mode("decide")
	else:
		close()


# --- decisions ----------------------------------------------------------------------------------------------

## Accepts the result, integrating by `how` (the chosen integrate option when "").
func accept(how: String = "") -> void:
	if mode == "busy":
		return
	var choice := how if how != "" else integrate
	_set_mode("busy")
	set_status(String({"merge": "Merging the work into your checkout...", "keep_branch": "Accepting; the work stays on its branch...",
		"export": "Exporting the files..."}.get(choice, "Accepting...")), "busy")
	var req: NetRequest = the_link().accept_result(task_id, choice)
	if req == null:
		_set_mode("decide")
		return
	req.done.connect(_on_accepted.bind(choice))


func _on_accepted(req: NetRequest, choice: String) -> void:
	if not req.ok:
		_set_mode("decide")
		set_status(req.error_message(), "error")
		return
	var p := req.payload_dict()
	var rewards: Variant = p.get("rewards")
	var merge := J.gd(p, "merge")
	if typeof(rewards) == TYPE_DICTIONARY:
		_show_rewards(rewards, merge, choice)
		accepted.emit(task_id, rewards)
		return
	_blocked_reason = J.gs(merge, "blocked_reason")
	if _blocked_reason != "":
		_set_mode("blocked")
		set_status("Nothing was changed. The task waits, still accepting.", "warn")
		return
	_show_rewards({}, merge, choice)
	accepted.emit(task_id, {})


func _show_rewards(rewards: Dictionary, merge: Dictionary, choice: String) -> void:
	_set_mode("done")
	_merge_note.visible = false
	var who := J.gs(Realm.agent(J.gs(task(), "agent_id")), "name", "The agent")
	var how := ""
	match choice:
		Protocol.Integrate.MERGE:
			var commit := J.gs(merge, "commit")
			how = ("Merged as %s." % commit.left(8)) if commit != "" else "Merged into your checkout."
		Protocol.Integrate.KEEP_BRANCH:
			how = "The work stays on its branch."
		Protocol.Integrate.EXPORT:
			how = "The files were exported."
	var banner := PanelContainer.new()
	_tray_box.visible = true
	var box := AgentTheme.callout_box(look, UiTokens.GOLD_DEEP)
	box.bg_color = Color(UiTokens.GOLD_BRIGHT, 0.22)
	box.content_margin_top = 12
	box.content_margin_bottom = 12
	banner.add_theme_stylebox_override("panel", box)
	_tray_box.add_child(banner)
	var row := AgentUi.hbox(16, banner)
	row.add_child(Glyph.new("star", UiTokens.GOLD_DEEP, 40))
	var col := AgentUi.vbox(6, row)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := AgentUi.label("ACCEPTED", "WinTitle", col)
	title.add_theme_color_override("font_color", UiTokens.BTN)
	var zero := J.gs(J.gd(rewards, "breakdown"), "zero_reason")
	var line := "%s's work joins the town. %s" % [who, how]
	if zero != "":
		line += " " + AgentUi.zero_reward_text(zero)
	AgentUi.para(line.strip_edges(), "Body", col)
	var chips := AgentUi.hbox(14, col)
	if not rewards.is_empty():
		_reward_chip(chips, "coin", UiTokens.GOLD_DEEP, "%s RP" % AgentUi.group(J.gi(rewards, "rp")))
		_reward_chip(chips, "star", Color("#6fa0d8"), "%s XP" % AgentUi.group(J.gi(rewards, "xp")))
		var res := J.gd(rewards, "resources")
		for r in Economy.data.resource_names():
			var n := J.gi(res, r)
			if n > 0:
				var chip := AgentUi.hbox(5, chips)
				chip.add_child(IconView.new(r, 22))
				var v := AgentUi.label("+%s" % AgentUi.group(n), "Value", chip)
				v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				v.add_theme_color_override("font_color", AgentTheme.c(look, "good"))
		var bd := J.gd(rewards, "breakdown")
		if not bd.is_empty():
			chips.tooltip_text = "Reward\nBase %d, quality +%d%%, efficiency +%d%%, practice +%d%%, daily %d%%, capped at %d." % [
				J.gi(bd, "base"), roundi(J.f(bd.get("q")) * 100.0), roundi(J.f(bd.get("e")) * 100.0), roundi(J.f(bd.get("p")) * 100.0),
				roundi(J.f(bd.get("d"), 1.0) * 100.0), J.gi(bd, "ceiling")]
			chips.mouse_filter = Control.MOUSE_FILTER_PASS
	_integrate_row.visible = false
	set_status("Accepted.", "good")
	# A little flourish.
	banner.modulate.a = 0.0
	banner.scale = Vector2(0.96, 0.96)
	var tw := banner.create_tween().set_parallel(true).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(banner, "modulate:a", 1.0, 0.25)
	tw.tween_property(banner, "scale", Vector2.ONE, 0.35)
	_queue_fit()


func _reward_chip(parent: Control, glyph: String, color: Color, text: String) -> void:
	var chip := AgentUi.hbox(6, parent)
	chip.add_child(Glyph.new(glyph, color, 20))
	var v := AgentUi.label(text, "Value", chip)
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER


func send_back() -> void:
	var fb := feedback_edit.text.strip_edges() if feedback_edit != null else ""
	if fb == "":
		set_status("Write what should change first.", "warn")
		return
	var req: NetRequest = the_link().send_back(task_id, fb)
	if req == null:
		return
	_disable_footer()
	set_status("Sending it back...", "busy")
	req.done.connect(_on_sent_back)


func _on_sent_back(req: NetRequest) -> void:
	if req.ok:
		sent_back.emit(task_id)
		close()
		return
	_enable_footer()
	set_status(req.error_message(), "error")


func abandon() -> void:
	var req: NetRequest = the_link().abandon_task(task_id)
	if req == null:
		return
	_disable_footer()
	set_status("Setting it aside...", "busy")
	req.done.connect(_on_abandoned)


func _on_abandoned(req: NetRequest) -> void:
	if req.ok:
		abandoned.emit(task_id)
		close()
		return
	_enable_footer()
	set_status(req.error_message(), "error")


func _disable_footer() -> void:
	for b in footer.get_children():
		if b is Button:
			(b as Button).disabled = true


func _enable_footer() -> void:
	for b in footer.get_children():
		if b is Button:
			(b as Button).disabled = false
	if mode == "send_back":
		_on_feedback_changed()


# --- events ---------------------------------------------------------------------------------------------------

func _on_task_changed(t: Dictionary, _before: String) -> void:
	if J.gs(t, "id") != task_id:
		return
	_refresh()
	var state := J.gs(t, "state")
	if state == Protocol.TaskState.ACCEPTED and mode != "done" and mode != "busy":
		var rewards := J.gd(t, "rewards")
		_show_rewards(rewards, {}, integrate)
	elif not state in [Protocol.TaskState.AWAITING_REVIEW, Protocol.TaskState.ACCEPTING, Protocol.TaskState.ACCEPTED] and mode in ["decide", "blocked"]:
		_set_mode("gone")


func _on_realm_changed(kind: String, _id: String) -> void:
	if kind == "all" or kind == "agent":
		_refresh()
