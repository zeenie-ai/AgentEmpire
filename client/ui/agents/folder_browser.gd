class_name FolderBrowser
extends WindowFrame
## Picks an agent's work folder through the Town Hall (browse_folder {path?} ->
## {path, parent, entries:[{name, path, is_git_repo}], roots}): the current path with Up, the
## allowed roots, and the sub-folders, where git repositories wear a badge. A click selects, a
## double-click opens; "Choose this folder" takes the selected folder, or the open one when
## nothing is selected. Keys: Enter chooses, Backspace goes up, arrows move the selection.
## Emits chosen(path) and closes; chosen_git tells whether it is a git repository (-1 unknown).

signal chosen(path: String)

const Protocol = preload("res://net/protocol.gd")

## The folder to open first ("" lists the roots).
var start_path: String = ""
## The open folder ("" while the roots are listed).
var current_path: String = ""
var parent_path: String = ""
var roots: Array = []
var entries: Array = []
var selected_path: String = ""
## 1 when the chosen folder is a git repository, 0 when it is not, -1 when unknown.
var chosen_git: int = -1

var _path_label: Label
var _up_button: Button
var _roots_row: HBoxContainer
var _list: VBoxContainer
var _rows: Dictionary = {}
var _group: ButtonGroup
var _choose: Button
var _started: bool = false
var _git_of: Dictionary = {}


func _init() -> void:
	super()
	configure("Choose a work folder", "The agent works only inside this folder", AgentTheme.STATUS, 720)
	set_title_icon(Glyph.new("folder", UiTokens.GOLD_BRIGHT, 30))
	body_height = 360.0

	var bar := AgentUi.hbox(8, head)
	_up_button = Button.new()
	_up_button.theme_type_variation = "GhostButton"
	_up_button.focus_mode = Control.FOCUS_NONE
	_up_button.custom_minimum_size = Vector2(76, 36)
	_up_button.text = "UP"
	_up_button.tooltip_text = "The folder above (Backspace)"
	_up_button.pressed.connect(go_up)
	bar.add_child(_up_button)
	var path_box := PanelContainer.new()
	path_box.add_theme_stylebox_override("panel", AgentTheme.field_box(look))
	path_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(path_box)
	var path_row := AgentUi.hbox(8, path_box)
	path_row.add_child(Glyph.new("folder", Color(UiTokens.GOLD_BRIGHT, 0.85), 16))
	_path_label = AgentUi.label("", "Mono", path_row)
	_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_label.clip_text = true
	_path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_roots_row = AgentUi.hbox(6, head)
	show_head(true)

	_list = AgentUi.vbox(2, body)
	_group = ButtonGroup.new()
	_group.allow_unpress = true

	var cancel := add_button("Cancel", "ghost")
	cancel.pressed.connect(close)
	add_key_hint("ENTER")
	_choose = add_button("Choose this folder", "primary")
	_choose.custom_minimum_size.x = 200
	_choose.pressed.connect(choose)
	_refresh_controls()


func _window_opened() -> void:
	if not _started:
		_started = true
		browse(start_path)


## Lists `path` ("" lists the allowed roots).
func browse(path: String) -> void:
	set_status("Looking inside %s ..." % path if path != "" else "Listing the folders you allowed...", "busy")
	var req := request(Protocol.CMD_BROWSE_FOLDER, {"path": path} if path != "" else {})
	req.done.connect(_on_listing.bind(path))


func _on_listing(req: NetRequest, asked: String) -> void:
	if not req.ok:
		set_status(req.error_message(), "error")
		# A remembered folder that is gone: fall back to the roots once.
		if asked != "" and asked == start_path and current_path == "" and entries.is_empty():
			start_path = ""
			browse("")
		return
	apply_listing(req.payload_dict())


## Shows a browse_folder reply.
func apply_listing(d: Dictionary) -> void:
	current_path = J.gs(d, "path")
	parent_path = J.gs(d, "parent")
	roots = J.a(d.get("roots"))
	entries = J.a(d.get("entries"))
	selected_path = ""
	for e: Variant in entries:
		var ed := J.d(e)
		_git_of[J.gs(ed, "path")] = J.b(ed.get("is_git_repo"), false)
	_rebuild()
	set_status("")
	_refresh_controls()


func _rebuild() -> void:
	_path_label.text = current_path if current_path != "" else "Allowed work roots"
	clear_box(_roots_row)
	var tag := AgentUi.label("ROOTS", "MonoSmall", _roots_row)
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	for r: Variant in roots:
		var root := J.s(r)
		var chip := Button.new()
		chip.theme_type_variation = "ChipButton"
		chip.text = root
		chip.toggle_mode = true
		chip.focus_mode = Control.FOCUS_NONE
		chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		chip.set_pressed_no_signal(current_path != "" and current_path.begins_with(root))
		chip.pressed.connect(browse.bind(root))
		_roots_row.add_child(chip)
	clear_box(_list)
	_rows.clear()
	if entries.is_empty():
		AgentUi.label("No sub-folders here." if current_path != "" else "No work roots are allowed. Check the Town Hall's settings.", "Hint", _list)
		return
	for e: Variant in entries:
		var ed := J.d(e)
		_list.add_child(_row(J.gs(ed, "name"), J.gs(ed, "path"), J.b(ed.get("is_git_repo"), false)))


func _row(folder_name: String, path: String, git: bool) -> Button:
	var b := Button.new()
	b.theme_type_variation = "RowButton"
	b.toggle_mode = true
	b.button_group = _group
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 38)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.tooltip_text = path
	var row := AgentUi.hbox(10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 14
	row.offset_right = -12
	row.add_child(Glyph.new("folder", UiTokens.GOLD_BRIGHT if git else Color(UiTokens.GOLD, 0.7), 18))
	var n := AgentUi.label(folder_name, "", row)
	n.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.clip_text = true
	n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if git:
		var badge := AgentUi.hbox(5, row)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		badge.add_child(Glyph.new("git", UiTokens.MINT, 14))
		var p := AgentUi.pill("Git repo", UiTokens.MINT, false, badge)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var open := Glyph.new("chevron_right", AgentTheme.c(look, "faint"), 12)
	row.add_child(open)
	b.toggled.connect(_on_row_toggled.bind(path))
	b.gui_input.connect(_on_row_input.bind(path))
	_rows[path] = b
	return b


func _on_row_toggled(on: bool, path: String) -> void:
	if on:
		selected_path = path
	elif selected_path == path:
		selected_path = ""
	_refresh_controls()


func _on_row_input(event: InputEvent, path: String) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT:
		browse(path)


func go_up() -> void:
	if current_path == "":
		return
	browse(parent_path)


## Takes the selected folder, or the open one.
func choose() -> void:
	var p := chosen_path()
	if p == "":
		return
	chosen_git = (1 if bool(_git_of[p]) else 0) if _git_of.has(p) else -1
	chosen.emit(p)
	close()


func chosen_path() -> String:
	return selected_path if selected_path != "" else current_path


func _refresh_controls() -> void:
	var p := chosen_path()
	_choose.disabled = p == ""
	_up_button.disabled = current_path == ""
	if p == "":
		_choose.tooltip_text = "Open a folder or select one first."
		return
	_choose.tooltip_text = p
	if status_label.text == "" or selected_path != "":
		var what := "a folder"
		if _git_of.has(p):
			what = "a git repository: the agent works on its own branch" if bool(_git_of[p]) else "a plain folder: results are copied back as files"
		set_status("%s is %s." % [p.get_file() if p.get_file() != "" else p, what])


func _window_key(event: InputEventKey) -> bool:
	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			choose()
			return true
		KEY_BACKSPACE:
			go_up()
			return true
		KEY_DOWN, KEY_UP:
			_move_selection(1 if event.keycode == KEY_DOWN else -1)
			return true
	return false


func _move_selection(step: int) -> void:
	var paths: Array = _rows.keys()
	if paths.is_empty():
		return
	var i := paths.find(selected_path)
	i = clampi(i + step, 0, paths.size() - 1) if i >= 0 else 0
	var b: Button = _rows[paths[i]]
	b.button_pressed = true
	_scroll.ensure_control_visible(b)
