class_name Hud
extends CanvasLayer
## The HUD: top resource bar, bottom panel (minimap, selection, command card), toasts, the
## drag box, the placement hint and an optional FPS readout. Built in code on the Aurelhaven
## theme (ThemeBuilder).

var root: Control
var top_bar: TopBar
var bottom: BottomPanel
var toasts: ToastLayer
var box_overlay: SelectionBoxOverlay
var hint: CursorHint
var fps_label: Label


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


func setup(view: WorldView, camera: RtsCamera, selection: Selection, input: RtsInput) -> void:
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
