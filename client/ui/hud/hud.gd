class_name Hud
extends CanvasLayer
## The HUD: top resource bar, bottom panel (minimap, selection, command card), toasts, the
## drag box, the placement hint and an optional FPS readout. Built in code on the Aurelhaven
## theme (ThemeBuilder).
##
## Agents: the approval tray (top right), and modal windows opened over a dimmed town
## (open_window): the summoning dialog, the task composer, the review window and the Mana
## budget. Those windows live in res://ui/agents/ and are loaded by path, so the HUD still
## runs when one is missing.

var root: Control
var top_bar: TopBar
var bottom: BottomPanel
var toasts: ToastLayer
var box_overlay: SelectionBoxOverlay
var hint: CursorHint
var fps_label: Label
## Modal windows (one at a time) over a dimmed town.
var modal_root: Control
var approval_tray: Control

var _input: RtsInput
var _modal: Control
var _dim: ColorRect


func _ready() -> void:
	layer = 10
	root = Control.new()
	root.name = "HudRoot"
	root.theme = ThemeBuilder.theme()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	box_overlay = SelectionBoxOverlay.new()
	root.add_child(box_overlay)
	box_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	top_bar = TopBar.new()
	root.add_child(top_bar)
	top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE, Control.PRESET_MODE_MINSIZE)

	bottom = BottomPanel.new()
	root.add_child(bottom)
	bottom.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE, Control.PRESET_MODE_MINSIZE)

	toasts = ToastLayer.new()
	root.add_child(toasts)
	toasts.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	toasts.offset_top = UiTokens.TOP_BAR_HEIGHT + 12
	toasts.grow_horizontal = Control.GROW_DIRECTION_BOTH

	fps_label = Label.new()
	fps_label.theme_type_variation = "MutedLabel"
	fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fps_label)
	fps_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	fps_label.offset_top = UiTokens.TOP_BAR_HEIGHT + 8
	fps_label.offset_left = -140
	fps_label.offset_right = -16
	fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fps_label.visible = bool(Settings.get_value("display/show_fps", false))

	hint = CursorHint.new()
	root.add_child(hint)

	approval_tray = _ui("approval_tray")
	if approval_tray != null:
		root.add_child(approval_tray)
		approval_tray.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE)
		approval_tray.offset_top = UiTokens.TOP_BAR_HEIGHT + 10
		approval_tray.offset_right = -12
		approval_tray.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		if approval_tray.has_signal("focus_requested"):
			approval_tray.connect("focus_requested", _on_focus_requested)

	modal_root = Control.new()
	modal_root.name = "Modal"
	modal_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(modal_root)
	modal_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	top_bar.budget_requested.connect(open_budget)


func setup(view: WorldView, camera: RtsCamera, selection: Selection, input: RtsInput) -> void:
	_input = input
	top_bar.input = input
	bottom.minimap.camera = camera
	bottom.minimap.input = input
	bottom.minimap.selection = selection
	bottom.selection_panel.bind(selection, input)
	bottom.command_card.bind(selection, input)
	input.hint_changed.connect(hint.set_hint)


func bind_world(w: SimWorld) -> void:
	bottom.minimap.bind(w)
	bottom.selection_panel.rebuild()
	bottom.command_card.refresh()


func set_box(r: Rect2) -> void:
	box_overlay.set_box(r)


func toggle_fps() -> void:
	fps_label.visible = not fps_label.visible
	Settings.set_value("display/show_fps", fps_label.visible)


func _process(_delta: float) -> void:
	if fps_label.visible:
		fps_label.text = "%d FPS" % Engine.get_frames_per_second()


# --- windows -----------------------------------------------------------------------------------

## True while a modal window is open (the world ignores clicks meanwhile).
func has_window() -> bool:
	return _modal != null and is_instance_valid(_modal)


## Shows `w` centred over a dimmed town. It closes itself by emitting `closed` (or being
## freed); opening another window closes the current one.
func open_window(w: Control) -> void:
	close_window()
	_dim = ColorRect.new()
	_dim.color = Color(0.03, 0.02, 0.01, 0.55)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	modal_root.add_child(_dim)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_modal = w
	modal_root.add_child(w)
	w.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	w.grow_horizontal = Control.GROW_DIRECTION_BOTH
	w.grow_vertical = Control.GROW_DIRECTION_BOTH
	if w.has_signal("closed"):
		w.connect("closed", _on_window_closed.bind(w))
	w.tree_exited.connect(_on_window_closed.bind(w))


func close_window() -> void:
	if has_window():
		var w := _modal
		_modal = null
		w.queue_free()
	if _dim != null and is_instance_valid(_dim):
		_dim.queue_free()
	_dim = null


func _on_window_closed(w: Control) -> void:
	if w == _modal or _modal == null:
		close_window()


## A small parchment question with Yes and No; `on_yes` runs on Yes.
func confirm(title: String, text: String, on_yes: Callable) -> void:
	var panel := PanelContainer.new()
	panel.theme_type_variation = "DocumentPanel"
	panel.custom_minimum_size = Vector2(440, 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var t := Label.new()
	t.text = title.to_upper()
	t.theme_type_variation = "TitleLabel"
	t.add_theme_color_override("font_color", UiTokens.SEPIA)
	box.add_child(t)
	var body := Label.new()
	body.text = text
	body.theme_type_variation = "DocumentLabel"
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(body)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var no := Button.new()
	no.text = "No"
	no.custom_minimum_size = Vector2(96, 34)
	no.pressed.connect(close_window)
	row.add_child(no)
	var yes := Button.new()
	yes.text = "Yes"
	yes.custom_minimum_size = Vector2(96, 34)
	yes.pressed.connect(func() -> void:
		close_window()
		on_yes.call())
	row.add_child(yes)
	open_window(panel)
	yes.grab_focus()


## A window from res://ui/agents/<name>.gd, or null (with a toast) when it is not there.
func _ui(name: String) -> Control:
	var path := "res://ui/agents/%s.gd" % name
	if not ResourceLoader.exists(path):
		return null
	var script := load(path) as GDScript
	return script.new() as Control if script != null else null


func _open(name: String, method: String, args: Array) -> Control:
	if not Game.link.is_live():
		Notify.push("The Town Hall is not connected.", "warn", "no_hall", 1500)
		return null
	var w := _ui(name)
	if w == null:
		Notify.push("That window is not available in this build.", "warn", "ui_missing", 2000)
		return null
	open_window(w)
	if method != "" and w.has_method(method):
		w.callv(method, args)
	return w


func open_summon() -> void:
	var w := _open("summon_dialog", "setup", [])
	if w != null and w.has_signal("summoned"):
		w.connect("summoned", func(_agent_id: String) -> void: Audio.play("summon"))


func open_task_composer(agent_id: String) -> void:
	if agent_id != "":
		_open("task_composer", "setup", [agent_id])


## The review window for the agent's oldest result waiting for review.
func open_review_for_agent(agent_id: String) -> void:
	for t in Realm.tasks_awaiting_review():
		if J.gs(t, "agent_id") == agent_id:
			open_review(J.gs(t, "id"))
			return
	Notify.push("Nothing waits for review.", "info", "no_review", 1200)


func open_review(task_id: String) -> void:
	_open("review_window", "setup", [task_id])


func open_budget() -> void:
	_open("budget_dialog", "setup", [])


## Brings the agent's approvals forward in the tray.
func focus_approvals(agent_id: String) -> void:
	if approval_tray != null and approval_tray.has_method("focus_agent"):
		approval_tray.call("focus_agent", agent_id)


func _on_focus_requested(agent_id: String) -> void:
	if _input != null:
		_input.focus_agent(agent_id)
