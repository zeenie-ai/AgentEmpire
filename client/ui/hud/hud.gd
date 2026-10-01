class_name Hud
extends CanvasLayer
## The HUD: top resource bar, bottom panel (minimap, selection, command card), toasts, the
## drag box, the placement hint and an optional FPS readout. Built in code on the AgentEmpire
## theme (ThemeBuilder).
##
## Agents: the approval tray (top right), and modal windows opened over a dimmed town
## (open_window, stacked: the Summoning Font opens its folder browser on top of itself): the
## summoning dialog, the task composer, the review window and the Mana budget
## (res://ui/agents/).

var root: Control
var top_bar: TopBar
var bottom: BottomPanel
var toasts: ToastLayer
var box_overlay: SelectionBoxOverlay
var hint: CursorHint
var fps_label: Label
## Modal windows over a dimmed town, the newest on top.
var modal_root: Control
var approval_tray: ApprovalTray

var _input: RtsInput
var _windows: Array[Control] = []
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

	approval_tray = ApprovalTray.new()
	approval_tray.name = "ApprovalTray"
	root.add_child(approval_tray)
	approval_tray.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	approval_tray.offset_top = UiTokens.TOP_BAR_HEIGHT + 12
	approval_tray.offset_right = -16
	approval_tray.offset_left = -16 - ApprovalTray.WIDTH
	approval_tray.focus_requested.connect(_on_focus_requested)

	modal_root = Control.new()
	modal_root.name = "Modal"
	modal_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(modal_root)
	modal_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	top_bar.budget_requested.connect(open_budget)
	top_bar.town_hall_mode_requested.connect(_on_town_hall_mode_requested)
	top_bar.town_hall_close_requested.connect(_on_town_hall_close_requested)


func setup(view: WorldView, camera: RtsCamera, selection: Selection, input: RtsInput) -> void:
	_input = input
	top_bar.input = input
	bottom.minimap.camera = camera
	bottom.minimap.input = input
	bottom.minimap.selection = selection
	bottom.selection_panel.bind(selection, input)
	bottom.selection_panel.agent_review_requested.connect(open_review)
	bottom.selection_panel.agent_approvals_requested.connect(focus_approvals)
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

## True while a modal window is open (the world ignores clicks and hotkeys meanwhile).
func has_window() -> bool:
	_prune_windows()
	return not _windows.is_empty() or WindowFrame.any_open()


## Shows `w` over a dimmed town, above any window already open. Agent windows (WindowFrame)
## centre themselves; other controls are centred here. A window closes itself (`closed`, or
## being freed); windows it asks for (open_window_requested) open on top of it.
func open_window(w: Control) -> void:
	_prune_windows()
	if _dim == null:
		_dim = ColorRect.new()
		_dim.color = Color(0.03, 0.02, 0.01, 0.55)
		_dim.mouse_filter = Control.MOUSE_FILTER_STOP
		modal_root.add_child(_dim)
		_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_windows.append(w)
	modal_root.add_child(w)
	if not w is WindowFrame:
		w.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
		w.grow_horizontal = Control.GROW_DIRECTION_BOTH
		w.grow_vertical = Control.GROW_DIRECTION_BOTH
	if w.has_signal("open_window_requested"):
		w.connect("open_window_requested", open_window)
	w.tree_exited.connect(_on_window_gone.bind(w))


## Closes the topmost window.
func close_window() -> void:
	_prune_windows()
	if _windows.is_empty():
		return
	var w: Control = _windows.pop_back()
	if w is WindowFrame:
		(w as WindowFrame).close()
	else:
		w.queue_free()
	_update_dim()


func _on_window_gone(w: Control) -> void:
	_windows.erase(w)
	_update_dim()


func _prune_windows() -> void:
	for i in range(_windows.size() - 1, -1, -1):
		if not is_instance_valid(_windows[i]) or _windows[i].is_queued_for_deletion():
			_windows.remove_at(i)


## The dim sits just under the topmost window; it goes when the last window closes.
func _update_dim() -> void:
	_prune_windows()
	if _dim == null or not is_instance_valid(_dim):
		_dim = null
		return
	if _windows.is_empty():
		_dim.queue_free()
		_dim = null
		return
	modal_root.move_child(_dim, maxi(_windows.back().get_index() - 1, 0))


## A small parchment question with Yes and No; `on_yes` runs on Yes.
## The Town Hall chip's menu: switching between practice and real agents, after a confirmation.
func _on_town_hall_mode_requested(mode: String) -> void:
	if mode == TownHallLauncher.MODE_REAL:
		confirm("Use real agents?",
			"Real agents work in your folders on your own Claude Code, Codex or pi sign-in, and what they use is real (your Mana budget caps it). The practice Town Hall closes and your real town opens.",
			_switch_town_hall.bind(TownHallLauncher.MODE_REAL))
	else:
		confirm("Use practice agents?",
			"Practice agents are a stand-in: nothing real runs and nothing is spent. The real Town Hall closes, so its agents pause until it runs again, and the practice town opens.",
			_switch_town_hall.bind(TownHallLauncher.MODE_FAKE))


func _switch_town_hall(mode: String) -> void:
	Game.switch_town_hall_mode(mode)


func _on_town_hall_close_requested() -> void:
	confirm("Close the Town Hall?",
		"Agents stop until the Town Hall runs again, then pick up where they left off. This town is saved, and you keep playing offline.",
		_close_town_hall)


func _close_town_hall() -> void:
	Game.close_town_hall()


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
	no.pressed.connect(panel.queue_free)
	row.add_child(no)
	var yes := Button.new()
	yes.text = "Yes"
	yes.custom_minimum_size = Vector2(96, 34)
	yes.pressed.connect(func() -> void:
		panel.queue_free()
		on_yes.call())
	row.add_child(yes)
	open_window(panel)
	yes.grab_focus()


func _needs_town_hall() -> bool:
	if Game.link.is_live():
		return false
	Notify.push("The Town Hall is not connected.", "warn", "no_hall", 1500)
	return true


func open_summon() -> void:
	if _needs_town_hall():
		return
	var w := SummonDialog.new()
	w.summoned.connect(func(_agent_id: String) -> void: Audio.play("summon"))
	open_window(w)


func open_task_composer(agent_id: String) -> void:
	if agent_id == "" or _needs_town_hall():
		return
	open_window(TaskComposer.new().setup(agent_id))


## The review window for the agent's oldest result waiting for review.
func open_review_for_agent(agent_id: String) -> void:
	for t in Realm.tasks_awaiting_review():
		if J.gs(t, "agent_id") == agent_id:
			open_review(J.gs(t, "id"))
			return
	Notify.push("Nothing waits for review.", "info", "no_review", 1200)


func open_review(task_id: String) -> void:
	if task_id == "" or _needs_town_hall():
		return
	var w := ReviewWindow.new().setup(task_id)
	w.accepted.connect(func(_task_id: String, _rewards: Dictionary) -> void: Audio.play("reward"))
	open_window(w)


func open_budget() -> void:
	if _needs_town_hall():
		return
	var w := BudgetDialog.new()
	w.saved.connect(func(_mana: Dictionary) -> void: Notify.push("Mana budget saved.", "good", "budget", 1000))
	open_window(w)


## Opens the agent's oldest waiting approval in the tray.
func focus_approvals(agent_id: String) -> void:
	for ap in Realm.approvals_for(agent_id):
		approval_tray.open(J.gs(ap, "id"))
		return


func _on_focus_requested(agent_id: String) -> void:
	if _input != null:
		_input.focus_agent(agent_id)
