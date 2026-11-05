class_name Hud
extends CanvasLayer
## The HUD: top resource bar, bottom panel (minimap, selection, command card), toasts, the
## drag box, the placement hint and an optional FPS readout. Built in code on the AgentEmpire
## theme (ThemeBuilder).
##
## Three layouts (Layout), picked from Platform: the desktop's; a tablet's on touch, the same
## with a Menu button in the top bar and the Select toggle (RtsInput.drag_selects) above the bottom
## panel's left end; and a phone's (a safe area under 1200 dp wide):
## - a slim top bar: resources, population, Idle, Map and Menu;
## - the phone column at the bottom right: the compact selection details over the command card,
##   shown while something is selected;
## - the minimap in an overlay under the Map button;
## - the Select toggle at the bottom left.
## Everything but the dim, the drag box and the cursor hint sits in `safe`, inset to the
## display's safe area (clear of camera cutouts), read again when the window resizes and when the
## app comes back; on phones and tablets the layout follows its width. Without a Town Hall
## (Platform.has_town_hall()) the Town Hall chip, the Mana orb and the approval tray are hidden.
##
## Agents: the task tracker (top left: every live task with its Rive seal, TaskTracker; not on
## phones), the approval tray (top right), and modal windows opened over a dimmed town
## (open_window, stacked: the Summoning Font opens its folder browser on top of itself): the
## summoning dialog, the task composer, the review window and the Mana budget
## (res://ui/agents/).

enum Layout { DESKTOP, TABLET, PHONE }

## Phones: the space between the safe area's edges and the HUD's parts, and between the parts.
const PHONE_GAP := 8

var root: Control
## The display's safe area: holds the bars, the phone column, the toasts and the approval tray.
var safe: Control
var top_bar: TopBar
var bottom: BottomPanel
## Phones: the selection details over the command card, at the bottom right. It keeps the
## card's width when they hide, so the world band beside it never moves.
var column: VBoxContainer
## Phones: the minimap opened from the Map button, top right under the bar. It catches the taps
## around the minimap, which close it.
var map_overlay: Control
## Phones and tablets: the Select toggle, bottom left (on tablets above the bottom panel).
var select_toggle: SelectToggle
var toasts: ToastLayer
var box_overlay: SelectionBoxOverlay
var hint: CursorHint
var fps_label: Label
## Modal windows over a dimmed town, the newest on top.
var modal_root: Control
var approval_tray: ApprovalTray
## The live tasks with their seals, top left under the top bar.
var tracker: TaskTracker
## Phones and tablets: what Android's Back button does (BackChain).
var back_chain: BackChain
## The layout in use; Platform picks it, use_layout() changes it.
var layout: Layout = Layout.DESKTOP
## Whether the Town Hall's parts show (the chip, the Mana orb, the approval tray).
var town_hall: bool = true
## Returns the display's safe area (Rect2, viewport coordinates) when set; else the HUD asks
## Platform.safe_rect(). Tests stand in for a camera cutout with it.
var safe_area_provider: Callable = Callable()

var _input: RtsInput
var _selection: Selection
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

	safe = Control.new()
	safe.name = "Safe"
	safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(safe)
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	top_bar = TopBar.new()
	safe.add_child(top_bar)
	top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE, Control.PRESET_MODE_MINSIZE)

	bottom = BottomPanel.new()
	safe.add_child(bottom)
	bottom.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE, Control.PRESET_MODE_MINSIZE)

	column = VBoxContainer.new()
	column.name = "Column"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", PHONE_GAP)
	safe.add_child(column)
	column.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, PHONE_GAP)
	column.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	column.grow_vertical = Control.GROW_DIRECTION_BEGIN

	select_toggle = SelectToggle.new()
	select_toggle.name = "SelectToggle"
	safe.add_child(select_toggle)

	toasts = ToastLayer.new()
	safe.add_child(toasts)

	fps_label = Label.new()
	fps_label.theme_type_variation = "MutedLabel"
	fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	safe.add_child(fps_label)
	fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fps_label.visible = bool(Settings.get_value("display/show_fps", false))

	hint = CursorHint.new()
	root.add_child(hint)

	approval_tray = ApprovalTray.new()
	approval_tray.name = "ApprovalTray"
	safe.add_child(approval_tray)
	approval_tray.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	approval_tray.offset_right = -16
	approval_tray.offset_left = -16 - ApprovalTray.WIDTH
	approval_tray.focus_requested.connect(_on_focus_requested)

	tracker = TaskTracker.new()
	tracker.name = "TaskTracker"
	safe.add_child(tracker)
	# Under the toasts: a long one draws over the tracker, not under it.
	safe.move_child(tracker, toasts.get_index())
	tracker.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	tracker.offset_left = 16
	tracker.review_requested.connect(open_review)
	tracker.approvals_requested.connect(_on_tracker_approvals)
	tracker.focus_requested.connect(_on_focus_requested)

	map_overlay = Control.new()
	map_overlay.name = "MapOverlay"
	map_overlay.visible = false
	safe.add_child(map_overlay)
	map_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	map_overlay.gui_input.connect(_on_map_overlay_input)

	modal_root = Control.new()
	modal_root.name = "Modal"
	modal_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(modal_root)
	modal_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	top_bar.budget_requested.connect(open_budget)
	top_bar.town_hall_mode_requested.connect(_on_town_hall_mode_requested)
	top_bar.town_hall_close_requested.connect(_on_town_hall_close_requested)
	top_bar.menu_requested.connect(open_game_menu)
	top_bar.map_requested.connect(_toggle_map)

	for c: Control in [safe, top_bar, bottom, column]:
		c.item_rect_changed.connect(_place)
	town_hall = Platform.has_town_hall()
	layout = platform_layout(get_viewport())
	get_viewport().size_changed.connect(_read_safe_area)
	_read_safe_area()
	_apply_layout()


func _notification(what: int) -> void:
	# Back from the background, the display may have turned or the cutout moved.
	if what == NOTIFICATION_APPLICATION_RESUMED:
		_read_safe_area()


## The layout Platform asks for in `vp`: the desktop's, or on touch the phone's below 1200 dp of
## safe width and the tablet's above.
static func platform_layout(vp: Viewport) -> Layout:
	if not Platform.is_mobile():
		return Layout.DESKTOP
	return Layout.PHONE if Platform.compact(vp) else Layout.TABLET


## Shows `which` layout, with or without the Town Hall's parts. The HUD starts with the one
## Platform asks for; tools and tests use this to see the others.
func use_layout(which: Layout, with_town_hall: bool) -> void:
	layout = which
	town_hall = with_town_hall
	_apply_layout()


## Fits the HUD to `layout`: the bars, and where the minimap, the selection details and the
## command card live (the bottom panel, or on phones the map overlay and the column).
func _apply_layout() -> void:
	var phone := layout == Layout.PHONE
	var touch := layout != Layout.DESKTOP
	top_bar.configure(phone, touch, town_hall)
	approval_tray.visible = town_hall
	tracker.enabled = town_hall and not phone
	if phone:
		_gather(column, [bottom.selection_panel, bottom.card_frame])
		column.custom_minimum_size.x = bottom.card_frame.get_combined_minimum_size().x
		_gather(map_overlay, [bottom.map_frame])
		bottom.minimap.custom_minimum_size = Vector2.ONE * Minimap.PHONE_SIZE
		bottom.map_frame.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, PHONE_GAP)
	else:
		close_overlay()
		bottom.minimap.custom_minimum_size = Vector2.ONE * Minimap.SIZE
		bottom.dock()
	bottom.selection_panel.set_look(phone, touch)
	# On their own over the town, the phone's frames float.
	for frame: Control in [bottom.card_frame, bottom.map_frame]:
		frame.theme_type_variation = "FloatPanel" if phone else "InsetPanel"
	bottom.visible = not phone
	column.visible = phone
	select_toggle.visible = touch
	toasts.compact = phone
	_update_column()
	_place()


## Moves `parts` into `parent`, in this order.
static func _gather(parent: Control, parts: Array[Control]) -> void:
	for i in parts.size():
		if parts[i].get_parent() != parent:
			parts[i].reparent(parent, false)
		parent.move_child(parts[i], i)


## On phones the selection details and the command card show while something is selected.
func _update_column() -> void:
	var shown := layout != Layout.PHONE or (_selection != null and not _selection.ids.is_empty())
	bottom.selection_panel.visible = shown
	bottom.card_frame.visible = shown


## The display's safe area in viewport coordinates: safe_area_provider's when set, else
## Platform.safe_rect() (the whole viewport on desktop).
func safe_area() -> Rect2:
	if safe_area_provider.is_valid():
		return safe_area_provider.call()
	return Platform.safe_rect(get_viewport())


## Insets `safe` to the display's safe area. On phones and tablets the layout follows its width
## (a foldable unfolding, a window resized).
func _read_safe_area() -> void:
	var full := get_viewport().get_visible_rect()
	var area := safe_area()
	safe.offset_left = area.position.x - full.position.x
	safe.offset_top = area.position.y - full.position.y
	safe.offset_right = area.end.x - full.end.x
	safe.offset_bottom = area.end.y - full.end.y
	if Platform.is_mobile():
		var which := Layout.PHONE if Platform.compact_at(area.size.x) else Layout.TABLET
		if which != layout:
			use_layout(which, town_hall)


## Places what goes by the measured bars: the toasts, the FPS readout and the approval tray under
## the top bar, the phone's minimap under it, and the Select toggle. The toasts and the readout
## keep to the world band: the whole width, or left of the phone column.
func _place() -> void:
	var below := top_bar.get_rect().end.y
	var band_right := column.position.x if layout == Layout.PHONE else safe.size.x
	toasts.offset_left = 0.0
	toasts.offset_right = band_right
	toasts.offset_top = below + 12.0
	fps_label.offset_left = band_right - 140.0
	fps_label.offset_right = band_right - 16.0
	fps_label.offset_top = below + 8.0
	approval_tray.offset_top = below + 12.0
	tracker.offset_top = below + 12.0
	if layout == Layout.PHONE:
		bottom.map_frame.offset_top = below + PHONE_GAP
	# Bottom left: on phones in the corner, on tablets just above the bottom panel.
	var toggle_bottom := (bottom.get_rect().position.y if layout == Layout.TABLET else safe.size.y) - PHONE_GAP
	select_toggle.offset_left = PHONE_GAP
	select_toggle.offset_right = PHONE_GAP + SelectToggle.SIZE
	select_toggle.offset_top = toggle_bottom - SelectToggle.SIZE
	select_toggle.offset_bottom = toggle_bottom


func setup(view: WorldView, camera: RtsCamera, selection: Selection, input: RtsInput) -> void:
	_input = input
	_selection = selection
	selection.changed.connect(_update_column)
	select_toggle.bind(input)
	_update_column()
	top_bar.input = input
	bottom.minimap.camera = camera
	bottom.minimap.input = input
	bottom.minimap.selection = selection
	bottom.selection_panel.bind(selection, input)
	bottom.selection_panel.agent_review_requested.connect(open_review)
	bottom.selection_panel.agent_approvals_requested.connect(focus_approvals)
	bottom.command_card.bind(selection, input)
	input.hint_changed.connect(hint.set_hint)
	back_chain = BackChain.new()
	back_chain.name = "BackChain"
	add_child(back_chain)
	back_chain.setup(self, input)


## The part of the screen the world is seen through, in viewport coordinates: inside the safe
## area, below the top bar and above the bottom panel, and on phones left of the column (the
## whole window while the HUD is hidden).
func world_rect() -> Rect2:
	var full := get_viewport().get_visible_rect()
	if not visible or top_bar == null or bottom == null:
		return full
	var area := safe.get_global_rect()
	var top := area.position.y
	var bottom_y := area.end.y
	var right := area.end.x
	if top_bar.visible:
		top = maxf(top, top_bar.get_global_rect().end.y)
	if bottom.visible:
		bottom_y = minf(bottom_y, bottom.get_global_rect().position.y)
	if column.visible:
		right = column.get_global_rect().position.x
	if bottom_y - top < 64.0:
		return full
	return Rect2(area.position.x, top, right - area.position.x, bottom_y - top)


## The game menu (GameMenu): phones and tablets open it from the top bar and with Back.
func open_game_menu() -> void:
	open_window(GameMenu.new().setup(self, _input))


## Opens the phone's minimap overlay; false in the layouts without one.
func open_map() -> bool:
	if layout != Layout.PHONE:
		return false
	map_overlay.visible = true
	top_bar.set_map_open(true)
	var frame := bottom.map_frame
	frame.pivot_offset = Vector2(frame.size.x, 0.0)
	frame.scale = Vector2.ONE * 0.94
	frame.modulate.a = 0.0
	var tw := frame.create_tween().set_parallel(true)
	tw.tween_property(frame, "scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(frame, "modulate:a", 1.0, 0.1)
	return true


## Closes an overlay that is not a window (the phone's minimap). True when one was open.
func close_overlay() -> bool:
	if not map_overlay.visible:
		return false
	map_overlay.visible = false
	top_bar.set_map_open(false)
	return true


func _toggle_map() -> void:
	if not close_overlay():
		open_map()


## A press on the overlay beside the minimap closes it.
func _on_map_overlay_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed:
		close_overlay()
		map_overlay.accept_event()


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
		_center(w)
		w.minimum_size_changed.connect(_center.bind(w))
	if w.has_signal("open_window_requested"):
		w.connect("open_window_requested", open_window)
	w.tree_exited.connect(_on_window_gone.bind(w))


## Centres a plain window at its minimum size, again whenever that changes: wrapped text measures
## tall until it knows its width.
func _center(w: Control) -> void:
	w.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	w.grow_horizontal = Control.GROW_DIRECTION_BOTH
	w.grow_vertical = Control.GROW_DIRECTION_BOTH


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
			"Real agents work in your folders on your own Claude Code or Codex sign-in, and what they use is real (your Mana budget caps it). The practice Town Hall closes and your real town opens.",
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
	# On touch the buttons are whole touch targets.
	var button_size := Vector2(96, Platform.TOUCH_TARGET_DP if layout != Layout.DESKTOP else 34.0)
	var no := Button.new()
	no.text = "No"
	no.custom_minimum_size = button_size
	no.pressed.connect(panel.queue_free)
	row.add_child(no)
	var yes := Button.new()
	yes.text = "Yes"
	yes.custom_minimum_size = button_size
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


## A tracker row waiting on a petition: open it in the tray and find the agent.
func _on_tracker_approvals(agent_id: String) -> void:
	focus_approvals(agent_id)
	_on_focus_requested(agent_id)
