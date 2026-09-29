class_name WindowFrame
extends PanelContainer
## The shared modal frame of the agent windows:
##   title bar   Cinzel title, a mono subtitle, an optional icon and the close button;
##   head        fixed controls under the title (optional);
##   body | side the scrolling content, with an optional fixed column on the right;
##   tray        fixed controls above the footer: inline confirmations and banners (optional);
##   footer      a status line on the left and the buttons on the right.
## Two looks: parchment (AgentTheme.DOCUMENT) and the anime status window (AgentTheme.STATUS).
##
## The frame keeps inside the viewport (MARGIN from every edge, so it fits 1280x720): the body
## scrolls when the content is taller. The host centres it: grow directions are both ways, and
## while its parent is not a Container it re-centres itself whenever its size changes. Esc closes
## the topmost window; close() emits `closed` and frees the window.
##
## `link` is the TownLink the window acts through (Game.link unless a test injects a fake);
## `requester` replaces Net.request for the window's own queries (list_models, browse_folder).
## Another window it opens (the folder browser) goes out through `open_window_requested`; with
## nothing connected it is placed beside this one.

signal closed()
## A window this one wants shown (the host opens it like any other).
signal open_window_requested(window: Control)

const MARGIN := 20.0

static var _stack: Array[WindowFrame] = []

var look: int = AgentTheme.STATUS
var link: Object = null
var requester: Callable = Callable()
## Preferred width; shrinks to fit the viewport.
var preferred_width: float = 880.0
## A fixed body height (list windows), or -1 to follow the content.
var body_height: float = -1.0
## Re-centre in the parent after every fit (ignored inside a Container).
var auto_center: bool = true

var title_label: Label
var subtitle_label: Label
var close_button: Button
var head: VBoxContainer
var body: VBoxContainer
var side: VBoxContainer
var tray: VBoxContainer
var footer: HBoxContainer
var status_label: Label

var _outer: VBoxContainer
var _title_bar: HBoxContainer
var _title_icon: Control
var _middle: HBoxContainer
var _scroll: ScrollContainer
var _side_scroll: ScrollContainer
var _footer_row: HBoxContainer
var _fit_queued: bool = false
var _closing: bool = false
var _listeners: Array = []


func _init() -> void:
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	mouse_filter = Control.MOUSE_FILTER_STOP
	# A modal window keeps working (and animating) even if the game pauses the tree.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_outer = VBoxContainer.new()
	_outer.add_theme_constant_override("separation", 14)
	add_child(_outer)

	_title_bar = HBoxContainer.new()
	_title_bar.add_theme_constant_override("separation", 14)
	_outer.add_child(_title_bar)
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", 3)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title_bar.add_child(titles)
	title_label = AgentUi.label("", "WinTitle", titles)
	subtitle_label = AgentUi.label("", "WinSubtitle", titles)
	subtitle_label.visible = false
	close_button = Button.new()
	close_button.theme_type_variation = "IconButton"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.custom_minimum_size = Vector2(34, 34)
	close_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	close_button.tooltip_text = "Close (Esc)"
	close_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_button.pressed.connect(close)
	close_button.draw.connect(_draw_close)
	_title_bar.add_child(close_button)

	head = VBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.visible = false
	_outer.add_child(head)

	_middle = HBoxContainer.new()
	_middle.add_theme_constant_override("separation", 20)
	_middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_outer.add_child(_middle)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.follow_focus = true
	_middle.add_child(_scroll)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 16)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(body)
	# The side column scrolls too, on screens too short for it.
	_side_scroll = ScrollContainer.new()
	_side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_side_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_side_scroll.visible = false
	_middle.add_child(_side_scroll)
	side = VBoxContainer.new()
	side.add_theme_constant_override("separation", 12)
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_side_scroll.add_child(side)

	tray = VBoxContainer.new()
	tray.add_theme_constant_override("separation", 10)
	tray.visible = false
	_outer.add_child(tray)

	_footer_row = HBoxContainer.new()
	_footer_row.add_theme_constant_override("separation", 12)
	_outer.add_child(_footer_row)
	status_label = AgentUi.label("", "Hint", _footer_row)
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	footer = HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	footer.alignment = BoxContainer.ALIGNMENT_END
	_footer_row.add_child(footer)

	for c: Control in [body, side, head, tray, _footer_row]:
		c.minimum_size_changed.connect(_queue_fit)
	resized.connect(_on_resized)
	set_look(AgentTheme.STATUS)


## Title, subtitle, look and preferred width in one call (subclasses call it first).
func configure(title: String, subtitle: String, window_look: int, width: float) -> void:
	set_look(window_look)
	set_title(title, subtitle)
	preferred_width = width
	custom_minimum_size.x = width
	_queue_fit()


func set_look(window_look: int) -> void:
	look = window_look
	theme = AgentTheme.theme(look)
	add_theme_stylebox_override("panel", AgentTheme.window_box(look))
	queue_redraw()


func set_title(title: String, subtitle: String = "") -> void:
	title_label.text = title.to_upper()
	subtitle_label.text = subtitle.to_upper()
	subtitle_label.visible = subtitle != ""


## An icon (IconDraw name, or a Control) before the title.
func set_title_icon(icon: Variant, px: float = 40.0) -> void:
	if _title_icon != null:
		_title_icon.queue_free()
	if icon is Control:
		_title_icon = icon
	else:
		_title_icon = IconView.new(String(icon), px)
	_title_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title_bar.add_child(_title_icon)
	_title_bar.move_child(_title_icon, 0)


# --- content helpers -------------------------------------------------------------------------------

## A footer button. kind: "primary" (the terracotta call to action), "ghost" or "danger".
func add_button(text: String, kind: String = "ghost", tip: String = "") -> Button:
	var b := AgentUi.TipButton.new()
	b.text = text.to_upper()
	match kind:
		"ghost":
			b.theme_type_variation = "GhostButton"
		"danger":
			b.theme_type_variation = "DangerButton"
	b.custom_minimum_size = Vector2(118, 40)
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if tip != "":
		b.tooltip_text = tip
	footer.add_child(b)
	return b


## A key cap before the next footer control ("ENTER", "CTRL+ENTER").
func add_key_hint(key: String) -> Control:
	var k := AgentUi.keycap(key, look, footer)
	return k


func clear_footer() -> void:
	for c in footer.get_children():
		footer.remove_child(c)
		c.queue_free()


func clear_box(box: Control) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


## The footer's status line. kind: "" (hint), "busy", "good", "warn" or "error".
func set_status(text: String, kind: String = "") -> void:
	status_label.text = text
	var col := AgentTheme.c(look, "muted")
	match kind:
		"busy":
			col = AgentTheme.c(look, "info")
		"good":
			col = AgentTheme.c(look, "good")
		"warn":
			col = AgentTheme.c(look, "warn")
		"error":
			col = AgentTheme.c(look, "bad")
	status_label.add_theme_color_override("font_color", col)
	status_label.theme_type_variation = "Hint" if kind == "" else "BodyItalic"


func show_side(on: bool) -> void:
	_side_scroll.visible = on
	_queue_fit()


func show_tray(on: bool) -> void:
	tray.visible = on
	_queue_fit()


func show_head(on: bool) -> void:
	head.visible = on
	_queue_fit()


## The window's TownLink: the injected one, else Game.link.
func the_link() -> Object:
	return link if link != null else Game.link


## Sends one of the window's own queries (list_models, browse_folder, check_providers).
func request(type: String, payload: Dictionary = {}) -> NetRequest:
	if requester.is_valid():
		return requester.call(type, payload)
	return Net.request(type, payload)


## Connects `fn` to `sig` while the window is in the tree.
func listen(sig: Signal, fn: Callable) -> void:
	if not sig.is_connected(fn):
		sig.connect(fn)
	_listeners.append([sig, fn])


## Opens another window over this one (the host's job when it listens).
func open_window(w: Control) -> void:
	if open_window_requested.get_connections().is_empty():
		var p := get_parent()
		if p != null:
			p.add_child(w)
			if w is WindowFrame:
				(w as WindowFrame)._queue_fit()
	else:
		open_window_requested.emit(w)


# --- hooks for subclasses ------------------------------------------------------------------------------

## Called when the window enters the tree: connect to Realm here with listen().
func _window_opened() -> void:
	pass


## Esc: closes the window unless a subclass handles it (an inline confirmation, say).
func _on_escape() -> void:
	close()


## Called just before `closed` is emitted.
func _window_closing() -> void:
	pass


## A key the window may want (Enter, Ctrl+Enter). Return true when it was used.
func _window_key(_event: InputEventKey) -> bool:
	return false


# --- lifecycle -------------------------------------------------------------------------------------------

func _enter_tree() -> void:
	_stack.erase(self)
	_stack.append(self)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_queue_fit):
		vp.size_changed.connect(_queue_fit)
	_window_opened()
	_queue_fit()


func _exit_tree() -> void:
	_stack.erase(self)
	for pair: Array in _listeners:
		var sig: Signal = pair[0]
		var fn: Callable = pair[1]
		if sig.is_connected(fn):
			sig.disconnect(fn)
	_listeners.clear()
	var vp := get_viewport()
	if vp != null and vp.size_changed.is_connected(_queue_fit):
		vp.size_changed.disconnect(_queue_fit)


func _ready() -> void:
	_fit()
	# Open with a small rise and fade.
	pivot_offset = size * 0.5
	modulate.a = 0.0
	scale = Vector2.ONE * 0.97
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "modulate:a", 1.0, 0.16)
	tw.tween_property(self, "scale", Vector2.ONE, 0.2)


## True when this is the window on top.
func is_topmost() -> bool:
	return not _stack.is_empty() and _stack[_stack.size() - 1] == self


## True while any agent window is open (the HUD can hold back game hotkeys meanwhile).
static func any_open() -> bool:
	return not _stack.is_empty()


## The window on top, or null.
static func topmost() -> WindowFrame:
	return _stack[_stack.size() - 1] if not _stack.is_empty() else null


func _input(event: InputEvent) -> void:
	if _closing or not is_visible_in_tree() or not is_topmost():
		return
	if event.is_action_pressed("ui_cancel") and not event.is_echo():
		get_viewport().set_input_as_handled()
		_on_escape()
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and _window_key(key):
		get_viewport().set_input_as_handled()


## True when a multi-line text field has the keyboard (Enter types a new line there).
func typing_in_text_edit() -> bool:
	var vp := get_viewport()
	if vp == null:
		return false
	var f := vp.gui_get_focus_owner()
	return f is TextEdit and (f as TextEdit).editable


func close() -> void:
	if _closing:
		return
	_closing = true
	# The window below takes the keys at once, while this one fades out.
	_stack.erase(self)
	_window_closing()
	closed.emit()
	if not is_inside_tree():
		queue_free()
		return
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	pivot_offset = size * 0.5
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_property(self, "modulate:a", 0.0, 0.12)
	tw.tween_property(self, "scale", Vector2.ONE * 0.97, 0.12)
	tw.chain().tween_callback(queue_free)


func is_closing() -> bool:
	return _closing


# --- fitting -----------------------------------------------------------------------------------------------

func _queue_fit() -> void:
	if _fit_queued:
		return
	_fit_queued = true
	_fit.call_deferred()


## Sizes the frame to its content inside the viewport, then re-centres it.
func _fit() -> void:
	_fit_queued = false
	if not is_inside_tree():
		return
	var vp := get_viewport_rect().size
	var w := minf(preferred_width, maxf(vp.x - MARGIN * 2.0, 320.0))
	var sb := get_theme_stylebox("panel")
	var sep := float(_outer.get_theme_constant("separation"))
	var chrome := sb.get_margin(SIDE_TOP) + sb.get_margin(SIDE_BOTTOM)
	chrome += _title_bar.get_combined_minimum_size().y + sep
	if head.visible:
		chrome += head.get_combined_minimum_size().y + sep
	if tray.visible:
		chrome += tray.get_combined_minimum_size().y + sep
	chrome += _footer_row.get_combined_minimum_size().y + sep
	var max_body := maxf(vp.y - MARGIN * 2.0 - chrome, 96.0)
	var want := body_height if body_height >= 0.0 else body.get_combined_minimum_size().y
	if _side_scroll.visible:
		want = maxf(want, side.get_combined_minimum_size().y)
	var h := minf(want, max_body)
	if not is_equal_approx(_scroll.custom_minimum_size.y, h):
		_scroll.custom_minimum_size.y = h
	if _side_scroll.visible:
		_side_scroll.custom_minimum_size = Vector2(side.get_combined_minimum_size().x, h)
	if not is_equal_approx(custom_minimum_size.x, w):
		custom_minimum_size.x = w
	var p := get_parent()
	if p is Container:
		return
	reset_size()
	_center()


func _on_resized() -> void:
	pivot_offset = size * 0.5
	if not _fit_queued:
		_center()


func _center() -> void:
	if not auto_center or not is_inside_tree():
		return
	var p := get_parent()
	if p is Container:
		return
	var area := get_viewport_rect().size
	if p is Control:
		area = (p as Control).size
	var target := ((area - size) * 0.5).floor()
	target.x = maxf(target.x, 0.0)
	target.y = maxf(target.y, 0.0)
	if position != target:
		position = target


# --- drawing -----------------------------------------------------------------------------------------------

func _draw() -> void:
	var sb := get_theme_stylebox("panel")
	var top := sb.get_margin(SIDE_TOP)
	var y := top + _title_bar.get_combined_minimum_size().y + 7.0
	var x0 := sb.get_margin(SIDE_LEFT)
	var x1 := size.x - sb.get_margin(SIDE_RIGHT)
	if look == AgentTheme.STATUS:
		# Glowing rule under the title with a gem at its start.
		var mint := UiTokens.MINT
		draw_polygon(PackedVector2Array([Vector2(x0, y - 0.5), Vector2(x1, y - 0.5), Vector2(x1, y + 0.5), Vector2(x0, y + 0.5)]),
			PackedColorArray([Color(mint, 0.85), Color(mint, 0.0), Color(mint, 0.0), Color(mint, 0.85)]))
		draw_rect(Rect2(Vector2(x0, y - 2.0), Vector2((x1 - x0) * 0.35, 4.0)), Color(mint, 0.05))
		_gem(Vector2(x0, y), 4.5, mint)
		# Corner brackets just outside the frame.
		var r := Rect2(Vector2.ZERO, size).grow(5.0)
		var k := 16.0
		var col := Color(mint, 0.55)
		for corner in [[r.position, Vector2(1, 1)], [Vector2(r.end.x, r.position.y), Vector2(-1, 1)],
				[r.end, Vector2(-1, -1)], [Vector2(r.position.x, r.end.y), Vector2(1, -1)]]:
			var p: Vector2 = corner[0]
			var d: Vector2 = corner[1]
			draw_line(p, p + Vector2(k * d.x, 0), col, 1.5)
			draw_line(p, p + Vector2(0, k * d.y), col, 1.5)
	elif look == AgentTheme.DOCUMENT:
		# An inked double rule with a lozenge in the middle.
		var ink := Color(UiTokens.SEPIA, 0.55)
		var mid := (x0 + x1) * 0.5
		draw_line(Vector2(x0, y), Vector2(mid - 12.0, y), ink, 1.0)
		draw_line(Vector2(mid + 12.0, y), Vector2(x1, y), ink, 1.0)
		draw_line(Vector2(x0 + 30.0, y + 3.0), Vector2(mid - 16.0, y + 3.0), Color(ink, 0.3), 1.0)
		draw_line(Vector2(mid + 16.0, y + 3.0), Vector2(x1 - 30.0, y + 3.0), Color(ink, 0.3), 1.0)
		_gem(Vector2(mid, y + 1.0), 5.0, UiTokens.BTN)
	else:
		draw_line(Vector2(x0, y), Vector2(x1, y), Color(UiTokens.HUD_BORDER, 0.9), 1.0)
		_gem(Vector2((x0 + x1) * 0.5, y), 4.5, UiTokens.GOLD)


func _gem(c: Vector2, r: float, col: Color) -> void:
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -r - 1.2), c + Vector2(r + 1.2, 0), c + Vector2(0, r + 1.2), c + Vector2(-r - 1.2, 0)]), Color(0, 0, 0, 0.55))
	draw_polygon(PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)]),
		PackedColorArray([col.lightened(0.45), col, col.darkened(0.35), col.lightened(0.1)]))


func _draw_close() -> void:
	var col := AgentTheme.c(look, "text") if close_button.is_hovered() else AgentTheme.c(look, "muted")
	var s := 12.0
	Glyph.paint(close_button, "close", Rect2((close_button.size - Vector2(s, s)) * 0.5, Vector2(s, s)), col, 1.0)
