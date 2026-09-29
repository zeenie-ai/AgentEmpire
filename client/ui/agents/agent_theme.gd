class_name AgentTheme
extends RefCounted
## Looks for the agent windows and panels, layered on the HUD theme (ThemeBuilder):
##   DOCUMENT  parchment and ink: the quest scroll and the review;
##   STATUS    the anime status window, navy with a mint trim: the Summoning Font, Mana, the
##             approval petitions;
##   HUD       dark wood with gold trim: the selection panel.
## theme(look) is the HUD theme plus look-aware labels, fields, dropdowns, scroll bars, pills and
## buttons; c(look, key) gives the look's colours to code that draws. Built once per look.
##
## Label variations: WinTitle, WinSubtitle, Section, Body, BodyStrong, BodyItalic, Hint, Mono,
## MonoSmall, CardTitle, Display, Value.
## Button variations: the default Button (terracotta call to action), GhostButton, DangerButton,
## ChipButton, IconButton, RowButton, CardChoice, CheckToggle.

const DOCUMENT := 0
const STATUS := 1
const HUD := 2

static var _themes: Dictionary = {}
static var _palettes: Dictionary = {}
static var _textures: Dictionary = {}


static func theme(look: int) -> Theme:
	if not _themes.has(look):
		_themes[look] = _build(look)
	return _themes[look]


# --- palette ------------------------------------------------------------------------------------

static func palette(look: int) -> Dictionary:
	if _palettes.is_empty():
		_palettes[DOCUMENT] = {
			"text": Color("#2a1d14"), "soft": Color("#3b2a1e"), "muted": Color("#7a5536"), "faint": Color("#a4855f"),
			"title": Color("#2a1d14"), "section": Color("#8a5a3a"),
			"accent": Color("#8f3b25"), "accent2": Color("#9a6a1c"), "line": Color(0.54, 0.35, 0.23, 0.36),
			"good": Color("#2f6b47"), "bad": Color("#a3321f"), "warn": Color("#9c5a14"), "info": Color("#2f5d8a"),
			"field": Color("#fcf7ec"), "field_hover": Color("#fffbf2"), "field_border": Color("#c6a37c"),
			"focus": Color("#8f3b25"),
			"card_top": Color("#f5ead4"), "card_bottom": Color("#e8d5b1"), "card_frame": Color("#8a6444"),
			"card_trim": Color(0.54, 0.35, 0.23, 0.35),
			"card_sel_top": Color("#fff7e6"), "card_sel_bottom": Color("#f2dfb8"), "card_sel_trim": Color("#8f3b25"),
			"slate_top": Color("#211913"), "slate_bottom": Color("#2b2119"), "slate_text": Color("#efe3c8"),
			"popup_top": Color("#f7ecd8"), "popup_bottom": Color("#eddcbc"),
		}
		_palettes[STATUS] = {
			"text": Color("#eef4ff"), "soft": Color("#c9d7ee"), "muted": Color("#8fa4c8"), "faint": Color("#62779e"),
			"title": Color("#f4f8ff"), "section": Color("#a9f0d0"),
			"accent": Color("#a9f0d0"), "accent2": Color("#ffd27a"), "line": Color(0.66, 0.94, 0.82, 0.2),
			"good": Color("#a9f0d0"), "bad": Color("#ff806c"), "warn": Color("#ffb85c"), "info": Color("#8cc8ff"),
			"field": Color(0.02, 0.035, 0.11, 0.78), "field_hover": Color(0.035, 0.06, 0.17, 0.85),
			"field_border": Color(0.62, 0.8, 1.0, 0.24), "focus": Color("#a9f0d0"),
			"card_top": Color(0.12, 0.155, 0.36, 0.92), "card_bottom": Color(0.055, 0.075, 0.2, 0.92),
			"card_frame": Color(0.01, 0.015, 0.05, 0.95), "card_trim": Color(0.6, 0.75, 1.0, 0.24),
			"card_sel_top": Color(0.12, 0.27, 0.43, 0.97), "card_sel_bottom": Color(0.05, 0.12, 0.25, 0.97),
			"card_sel_trim": Color("#a9f0d0"),
			"slate_top": Color(0.015, 0.025, 0.08, 0.92), "slate_bottom": Color(0.03, 0.04, 0.11, 0.92),
			"slate_text": Color("#dfe8f7"),
			"popup_top": Color(0.09, 0.11, 0.27, 0.98), "popup_bottom": Color(0.04, 0.05, 0.15, 0.98),
		}
		_palettes[HUD] = {
			"text": UiTokens.HUD_TEXT, "soft": UiTokens.HUD_SUBTLE, "muted": UiTokens.HUD_MUTED, "faint": Color("#8a7350"),
			"title": UiTokens.GOLD, "section": UiTokens.HUD_MUTED,
			"accent": UiTokens.GOLD, "accent2": UiTokens.GOLD_BRIGHT, "line": Color(0.42, 0.32, 0.19, 0.8),
			"good": UiTokens.MINT, "bad": UiTokens.BAD, "warn": UiTokens.WARN, "info": Color("#8cc8ff"),
			"field": Color("#120d09"), "field_hover": Color("#18110b"), "field_border": UiTokens.HUD_BORDER,
			"focus": UiTokens.GOLD,
			"card_top": Color("#2c2016"), "card_bottom": Color("#1a130d"), "card_frame": Color("#0b0805"),
			"card_trim": Color(0.42, 0.32, 0.19, 0.8),
			"card_sel_top": Color("#3b2b1c"), "card_sel_bottom": Color("#22170f"), "card_sel_trim": UiTokens.GOLD_BRIGHT,
			"slate_top": Color("#0f0b07"), "slate_bottom": Color("#18110b"), "slate_text": UiTokens.HUD_TEXT,
			"popup_top": Color("#2c2016"), "popup_bottom": Color("#140e09"),
		}
	return _palettes.get(look, _palettes[STATUS])


## One colour of a look ("text", "muted", "accent", "bad", ...).
static func c(look: int, key: String) -> Color:
	return palette(look).get(key, Color.MAGENTA)


# --- style boxes ----------------------------------------------------------------------------------

## The frame of a window in `look`.
static func window_box(look: int) -> CraftedBox:
	var s: CraftedBox
	match look:
		DOCUMENT:
			s = ThemeBuilder.document_box()
			s.inner_shadow = 18.0
			s.inner_shadow_alpha = 0.16
		STATUS:
			s = ThemeBuilder.status_box(UiTokens.MINT)
			s.top_color = Color(0.075, 0.095, 0.25, 0.975)
			s.bottom_color = Color(0.025, 0.035, 0.12, 0.975)
			s.inner_shadow = 16.0
			s.inner_shadow_alpha = 0.35
		_:
			s = ThemeBuilder.hud_box()
	s.shadow_size = 26.0
	s.shadow_alpha = 0.6
	s.shadow_offset = Vector2(0, 12)
	s.content_margin_left = 28
	s.content_margin_right = 28
	s.content_margin_top = 20
	s.content_margin_bottom = 20
	return s


## A petition card (approvals): the status window with its trim in `trim`.
static func petition_box(trim: Color) -> CraftedBox:
	var s := ThemeBuilder.status_box(trim)
	s.top_color = Color(0.085, 0.105, 0.27, 0.965)
	s.bottom_color = Color(0.03, 0.04, 0.13, 0.965)
	s.trim_color = Color(trim, 0.75)
	s.shadow_size = 12.0
	s.shadow_alpha = 0.5
	s.shadow_offset = Vector2(0, 5)
	s.content_margin_left = 18
	s.content_margin_right = 16
	s.content_margin_top = 12
	s.content_margin_bottom = 12
	return s


## A selectable card; `state` is "normal", "hover", "selected", "selected_hover" or "disabled".
static func card_box(look: int, state: String) -> CraftedBox:
	var s := CraftedBox.new()
	s.studs = false
	s.trim_inset = 2.0
	s.trim_width = 1.0
	s.bevel = 1.0
	s.inner_shadow = 8.0
	s.inner_shadow_alpha = 0.14 if look == DOCUMENT else 0.28
	s.shadow_size = 4.0
	s.shadow_alpha = 0.2 if look == DOCUMENT else 0.35
	s.shadow_offset = Vector2(0, 2)
	s.grain = 0.0 if look == STATUS else 0.045
	s.frame_color = c(look, "card_frame")
	s.top_color = c(look, "card_top")
	s.bottom_color = c(look, "card_bottom")
	s.trim_color = c(look, "card_trim")
	match state:
		"hover":
			s.top_color = s.top_color.lightened(0.06)
			s.bottom_color = s.bottom_color.lightened(0.04)
			s.trim_color = Color(c(look, "card_sel_trim"), 0.55)
		"selected", "selected_hover":
			s.top_color = c(look, "card_sel_top")
			s.bottom_color = c(look, "card_sel_bottom")
			s.trim_color = c(look, "card_sel_trim")
			s.trim_width = 1.5
			s.glow = 1.0 if state == "selected_hover" else 0.7
			s.shadow_size = 6.0
		"disabled":
			s.top_color = Color(s.top_color, s.top_color.a * 0.5)
			s.bottom_color = Color(s.bottom_color, s.bottom_color.a * 0.5)
			s.trim_color = Color(s.trim_color, 0.12)
			s.shadow_size = 0.0
			s.sunken = true
	s.set_content_margin_all(10)
	return s


## A text field (LineEdit, TextEdit, dropdown).
static func field_box(look: int, hover: bool = false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c(look, "field_hover" if hover else "field")
	s.border_color = c(look, "field_border")
	if hover:
		s.border_color = Color(c(look, "focus"), 0.55)
	s.set_border_width_all(1)
	s.border_width_top = 2 if look == DOCUMENT else 1
	s.set_corner_radius_all(3)
	s.content_margin_left = 11
	s.content_margin_right = 11
	s.content_margin_top = 7
	s.content_margin_bottom = 7
	s.anti_aliasing = true
	return s


static func focus_box(look: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = Color(c(look, "focus"), 0.9)
	s.set_border_width_all(2)
	s.set_corner_radius_all(3)
	s.anti_aliasing = true
	return s


## A dark inset for code, logs and patches, in any look.
static func slate_box(look: int) -> CraftedBox:
	var s := ThemeBuilder.inset_box()
	s.top_color = c(look, "slate_top")
	s.bottom_color = c(look, "slate_bottom")
	if look == STATUS:
		s.trim_color = Color(UiTokens.MINT, 0.16)
		s.frame_color = Color(0.0, 0.0, 0.02, 0.95)
		s.grain = 0.0
	elif look == DOCUMENT:
		s.trim_color = Color(UiTokens.SEPIA, 0.55)
		s.frame_color = Color("#140e09")
	s.set_content_margin_all(10)
	return s


## A banner: tinted body, a thin frame and a thick left edge in `color`.
static func callout_box(look: int, color: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(color, 0.1 if look == DOCUMENT else 0.13)
	s.border_color = Color(color, 0.55)
	s.set_border_width_all(1)
	s.border_width_left = 4
	s.set_corner_radius_all(2)
	s.content_margin_left = 16
	s.content_margin_right = 14
	s.content_margin_top = 9
	s.content_margin_bottom = 9
	s.anti_aliasing = true
	return s


## A pill (badges and tags).
static func pill_box(color: Color, filled: bool = false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color if filled else Color(color, 0.14)
	s.border_color = Color(color, 0.9 if filled else 0.7)
	s.set_border_width_all(1)
	s.set_corner_radius_all(10)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 1
	s.content_margin_bottom = 2
	s.anti_aliasing = true
	return s


## A plain panel for a group of fields (the side column, stat tiles).
static func group_box(look: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	match look:
		DOCUMENT:
			s.bg_color = Color(0.54, 0.35, 0.23, 0.07)
			s.border_color = Color(0.54, 0.35, 0.23, 0.3)
		STATUS:
			s.bg_color = Color(0.0, 0.02, 0.08, 0.35)
			s.border_color = Color(0.6, 0.78, 1.0, 0.16)
		_:
			s.bg_color = Color(0, 0, 0, 0.25)
			s.border_color = Color(UiTokens.HUD_BORDER, 0.6)
	s.set_border_width_all(1)
	s.set_corner_radius_all(3)
	s.set_content_margin_all(14)
	s.anti_aliasing = true
	return s


static func keycap_box(look: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0.35) if look != DOCUMENT else Color(UiTokens.INK, 0.85)
	s.border_color = Color(c(look, "muted"), 0.6) if look != DOCUMENT else Color(UiTokens.INK, 1.0)
	s.set_border_width_all(1)
	s.border_width_bottom = 2
	s.set_corner_radius_all(3)
	s.content_margin_left = 6
	s.content_margin_right = 6
	s.content_margin_top = 1
	s.content_margin_bottom = 1
	return s


# --- icons for the theme ----------------------------------------------------------------------------

## A downward chevron (dropdown arrow), drawn once per colour.
static func chevron_icon(color: Color, px: int = 12) -> Texture2D:
	var key := "chevron:%s:%d" % [color.to_html(), px]
	if not _textures.has(key):
		var w := float(px)
		var a := Vector2(w * 0.18, w * 0.36)
		var m := Vector2(w * 0.5, w * 0.68)
		var b := Vector2(w * 0.82, w * 0.36)
		_textures[key] = _stroke_texture(px, px, [[a, m], [m, b]], w * 0.13 + 0.7, color)
	return _textures[key]


## A filled dot (the checked radio in dropdown lists).
static func dot_icon(color: Color, px: int = 14, radius: float = 3.5) -> Texture2D:
	var key := "dot:%s:%d:%.1f" % [color.to_html(), px, radius]
	if not _textures.has(key):
		var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
		var ctr := Vector2(px, px) * 0.5
		for y in px:
			for x in px:
				var d := Vector2(float(x) + 0.5, float(y) + 0.5).distance_to(ctr)
				var cover := clampf(radius + 0.5 - d, 0.0, 1.0)
				img.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * cover))
		_textures[key] = ImageTexture.create_from_image(img)
	return _textures[key]


static func blank_icon(px: int = 14) -> Texture2D:
	var key := "blank:%d" % px
	if not _textures.has(key):
		var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		_textures[key] = ImageTexture.create_from_image(img)
	return _textures[key]


static func _stroke_texture(w: int, h: int, segments: Array, width: float, color: Color) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var p := Vector2(float(x) + 0.5, float(y) + 0.5)
			var d := INF
			for seg: Array in segments:
				d = minf(d, _segment_distance(p, seg[0], seg[1]))
			var cover := clampf(width * 0.5 + 0.5 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * cover))
	return ImageTexture.create_from_image(img)


static func _segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
	return p.distance_to(a + ab * t)


# --- the theme --------------------------------------------------------------------------------------

static func _build(look: int) -> Theme:
	var t := Theme.new()
	t.merge_with(ThemeBuilder.theme())
	_labels(t, look)
	_fields(t, look)
	_dropdowns(t, look)
	_scrollbars(t, look)
	_buttons(t, look)
	var line := StyleBoxLine.new()
	line.color = c(look, "line")
	line.thickness = 1
	t.set_stylebox("separator", "HSeparator", line)
	t.set_constant("separation", "HSeparator", 12)
	var vline := StyleBoxLine.new()
	vline.color = c(look, "line")
	vline.thickness = 1
	vline.vertical = true
	t.set_stylebox("separator", "VSeparator", vline)
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	t.set_stylebox("focus", "ScrollContainer", StyleBoxEmpty.new())
	return t


static func _label(t: Theme, name: String, font: Font, size: int, color: Color) -> void:
	t.set_type_variation(name, "Label")
	t.set_font("font", name, font)
	t.set_font_size("font_size", name, size)
	t.set_color("font_color", name, color)


static func _labels(t: Theme, look: int) -> void:
	t.set_color("font_color", "Label", c(look, "text"))
	_label(t, "WinTitle", UiFonts.cinzel(700, 3), 19, c(look, "title"))
	_label(t, "WinSubtitle", UiFonts.mono(500, 2), 11, c(look, "muted"))
	_label(t, "Section", UiFonts.mono(600, 3), 11, c(look, "section"))
	_label(t, "Body", UiFonts.spectral("Regular"), 15, c(look, "soft"))
	_label(t, "BodyStrong", UiFonts.spectral("SemiBold"), 16, c(look, "text"))
	_label(t, "BodyItalic", UiFonts.spectral("Italic"), 15, c(look, "soft"))
	_label(t, "Hint", UiFonts.spectral("Italic"), 13, c(look, "muted"))
	_label(t, "Mono", UiFonts.mono(500, 0), 13, c(look, "text"))
	_label(t, "MonoSmall", UiFonts.mono(500, 1), 11, c(look, "muted"))
	_label(t, "CardTitle", UiFonts.cinzel(700, 1), 14, c(look, "text"))
	_label(t, "Display", UiFonts.cormorant(600), 28, c(look, "text"))
	_label(t, "Value", UiFonts.mono(700, 0), 16, c(look, "text"))
	if look == STATUS:
		# The status window's glow: a soft shadow with no offset.
		for v in ["WinTitle", "Display"]:
			t.set_color("font_shadow_color", v, Color(UiTokens.MINT, 0.3))
			t.set_constant("shadow_offset_x", v, 0)
			t.set_constant("shadow_offset_y", v, 0)
			t.set_constant("shadow_outline_size", v, 6)
	elif look == HUD:
		for v in ["WinTitle", "Display"]:
			t.set_color("font_shadow_color", v, Color(0, 0, 0, 0.55))
			t.set_constant("shadow_offset_x", v, 0)
			t.set_constant("shadow_offset_y", v, 1)


static func _fields(t: Theme, look: int) -> void:
	for type in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type, field_box(look))
		t.set_stylebox("focus", type, focus_box(look))
		var ro := field_box(look)
		ro.bg_color = Color(ro.bg_color, ro.bg_color.a * 0.6)
		t.set_stylebox("read_only", type, ro)
		t.set_font("font", type, UiFonts.spectral("Regular"))
		t.set_font_size("font_size", type, 15)
		t.set_color("font_color", type, c(look, "text"))
		t.set_color("font_readonly_color", type, c(look, "soft"))
		t.set_color("font_placeholder_color", type, Color(c(look, "faint"), 0.95))
		t.set_color("caret_color", type, c(look, "focus"))
		t.set_color("selection_color", type, Color(c(look, "focus"), 0.28))
		t.set_color("font_selected_color", type, c(look, "text"))
		t.set_color("clear_button_color", type, c(look, "muted"))
		t.set_constant("caret_width", type, 2)
	t.set_color("current_line_color", "TextEdit", Color(0, 0, 0, 0))
	t.set_color("background_color", "TextEdit", Color(0, 0, 0, 0))
	t.set_constant("line_spacing", "TextEdit", 5)


static func _dropdowns(t: Theme, look: int) -> void:
	var normal := field_box(look)
	normal.content_margin_right = 12
	var hover := field_box(look, true)
	var pressed := field_box(look, true)
	pressed.border_color = c(look, "focus")
	var disabled := field_box(look)
	disabled.bg_color = Color(disabled.bg_color, disabled.bg_color.a * 0.45)
	disabled.border_color = Color(disabled.border_color, disabled.border_color.a * 0.5)
	t.set_stylebox("normal", "OptionButton", normal)
	t.set_stylebox("hover", "OptionButton", hover)
	t.set_stylebox("pressed", "OptionButton", pressed)
	t.set_stylebox("hover_pressed", "OptionButton", pressed)
	t.set_stylebox("disabled", "OptionButton", disabled)
	t.set_stylebox("focus", "OptionButton", StyleBoxEmpty.new())
	t.set_font("font", "OptionButton", UiFonts.spectral("Regular"))
	t.set_font_size("font_size", "OptionButton", 15)
	for key in ["font_color", "font_focus_color", "font_pressed_color", "font_hover_pressed_color"]:
		t.set_color(key, "OptionButton", c(look, "text"))
	t.set_color("font_hover_color", "OptionButton", c(look, "text"))
	t.set_color("font_disabled_color", "OptionButton", c(look, "faint"))
	t.set_icon("arrow", "OptionButton", chevron_icon(c(look, "muted"), 12))
	t.set_constant("arrow_margin", "OptionButton", 10)
	t.set_constant("h_separation", "OptionButton", 8)
	t.set_constant("modulate_arrow", "OptionButton", 0)

	var panel := CraftedBox.new()
	panel.top_color = c(look, "popup_top")
	panel.bottom_color = c(look, "popup_bottom")
	panel.frame_color = c(look, "card_frame")
	panel.trim_color = Color(c(look, "accent"), 0.45)
	panel.trim_inset = 2.0
	panel.studs = false
	panel.grain = 0.0 if look == STATUS else 0.04
	panel.shadow_size = 8.0
	panel.shadow_alpha = 0.4
	panel.inner_shadow = 6.0
	panel.set_content_margin_all(6)
	t.set_stylebox("panel", "PopupMenu", panel)
	var hover_line := StyleBoxFlat.new()
	hover_line.bg_color = Color(c(look, "accent"), 0.18 if look == DOCUMENT else 0.16)
	hover_line.set_corner_radius_all(2)
	t.set_stylebox("hover", "PopupMenu", hover_line)
	t.set_font("font", "PopupMenu", UiFonts.spectral("Medium"))
	t.set_font_size("font_size", "PopupMenu", 15)
	t.set_color("font_color", "PopupMenu", c(look, "text"))
	t.set_color("font_hover_color", "PopupMenu", c(look, "text") if look == DOCUMENT else c(look, "accent2"))
	t.set_color("font_disabled_color", "PopupMenu", Color(c(look, "faint"), 0.8))
	t.set_color("font_separator_color", "PopupMenu", c(look, "muted"))
	t.set_icon("radio_checked", "PopupMenu", dot_icon(c(look, "accent")))
	t.set_icon("radio_unchecked", "PopupMenu", blank_icon())
	t.set_icon("radio_checked_disabled", "PopupMenu", dot_icon(c(look, "faint")))
	t.set_icon("radio_unchecked_disabled", "PopupMenu", blank_icon())
	t.set_constant("v_separation", "PopupMenu", 8)
	t.set_constant("item_start_padding", "PopupMenu", 8)
	t.set_constant("item_end_padding", "PopupMenu", 14)


static func _scrollbars(t: Theme, look: int) -> void:
	for type in ["VScrollBar", "HScrollBar"]:
		var track := StyleBoxFlat.new()
		track.bg_color = Color(c(look, "line"), 0.35)
		track.set_corner_radius_all(3)
		track.set_content_margin_all(3)
		var grab := StyleBoxFlat.new()
		grab.bg_color = Color(c(look, "accent"), 0.42 if look != DOCUMENT else 0.5)
		grab.set_corner_radius_all(3)
		grab.set_content_margin_all(3)
		var grab_hi := grab.duplicate() as StyleBoxFlat
		grab_hi.bg_color = Color(c(look, "accent"), 0.7)
		var grab_pr := grab.duplicate() as StyleBoxFlat
		grab_pr.bg_color = Color(c(look, "accent"), 0.9)
		t.set_stylebox("scroll", type, track)
		t.set_stylebox("scroll_focus", type, track)
		t.set_stylebox("grabber", type, grab)
		t.set_stylebox("grabber_highlight", type, grab_hi)
		t.set_stylebox("grabber_pressed", type, grab_pr)
		t.set_icon("increment", type, blank_icon(1))
		t.set_icon("decrement", type, blank_icon(1))
		t.set_icon("increment_highlight", type, blank_icon(1))
		t.set_icon("decrement_highlight", type, blank_icon(1))
		t.set_icon("increment_pressed", type, blank_icon(1))
		t.set_icon("decrement_pressed", type, blank_icon(1))


static func _button_variation(t: Theme, name: String, boxes: Array, font: Font, size: int, colors: Array) -> void:
	# boxes: normal, hover, pressed, disabled[, hover_pressed]; colors: normal, hover, pressed, disabled.
	t.set_type_variation(name, "Button")
	t.set_stylebox("normal", name, boxes[0])
	t.set_stylebox("hover", name, boxes[1])
	t.set_stylebox("pressed", name, boxes[2])
	t.set_stylebox("hover_pressed", name, boxes[4] if boxes.size() > 4 else boxes[2])
	t.set_stylebox("disabled", name, boxes[3])
	t.set_stylebox("focus", name, StyleBoxEmpty.new())
	t.set_font("font", name, font)
	t.set_font_size("font_size", name, size)
	t.set_color("font_color", name, colors[0])
	t.set_color("font_focus_color", name, colors[0])
	t.set_color("font_hover_color", name, colors[1])
	t.set_color("font_pressed_color", name, colors[2])
	t.set_color("font_hover_pressed_color", name, colors[2])
	t.set_color("font_disabled_color", name, colors[3])


static func _crafted(top: Color, bottom: Color, trim: Color, frame: Color) -> CraftedBox:
	var s := CraftedBox.new()
	s.top_color = top
	s.bottom_color = bottom
	s.trim_color = trim
	s.frame_color = frame
	s.trim_inset = 2.0
	s.studs = false
	s.inner_shadow = 5.0
	s.inner_shadow_alpha = 0.25
	s.shadow_size = 3.0
	s.shadow_alpha = 0.35
	s.shadow_offset = Vector2(0, 2)
	s.grain = 0.05
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s


static func _buttons(t: Theme, look: int) -> void:
	# The default Button stays the HUD's terracotta call to action; give it roomier margins.
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var b := (t.get_stylebox(state, "Button") as CraftedBox).copy()
		b.content_margin_left = 18
		b.content_margin_right = 18
		b.content_margin_top = 7
		b.content_margin_bottom = 7
		t.set_stylebox(state, "Button", b)

	# Ghost: the secondary action, quiet until hovered.
	var g_normal: CraftedBox
	var g_hover: CraftedBox
	var g_pressed: CraftedBox
	var g_disabled: CraftedBox
	var g_colors: Array
	match look:
		DOCUMENT:
			g_normal = _crafted(Color("#f6ebd5"), Color("#e6d2ad"), Color(UiTokens.SEPIA, 0.55), Color("#8a6444"))
			g_hover = _crafted(Color("#fff6e3"), Color("#efdcb9"), Color(UiTokens.BTN, 0.9), Color("#8a6444"))
			g_hover.glow = 0.8
			g_pressed = _crafted(Color("#e3cda6"), Color("#efdcb9"), Color(UiTokens.BTN, 0.9), Color("#8a6444"))
			g_pressed.sunken = true
			g_disabled = _crafted(Color("#efe3cb"), Color("#e8dac0"), Color(UiTokens.SEPIA, 0.2), Color(0.54, 0.39, 0.27, 0.4))
			g_disabled.shadow_size = 0.0
			g_colors = [c(look, "text"), UiTokens.BTN, UiTokens.BTN_PRESSED, c(look, "faint")]
		STATUS:
			g_normal = _crafted(Color(0.11, 0.15, 0.34, 0.75), Color(0.05, 0.07, 0.19, 0.75), Color(UiTokens.MINT, 0.4), Color(0.01, 0.02, 0.06, 0.9))
			g_normal.grain = 0.0
			g_hover = _crafted(Color(0.14, 0.21, 0.42, 0.9), Color(0.06, 0.1, 0.24, 0.9), Color(UiTokens.MINT, 0.95), Color(0.01, 0.02, 0.06, 0.9))
			g_hover.grain = 0.0
			g_hover.glow = 1.0
			g_pressed = _crafted(Color(0.04, 0.07, 0.18, 0.95), Color(0.09, 0.13, 0.3, 0.95), Color(UiTokens.MINT, 0.95), Color(0.01, 0.02, 0.06, 0.9))
			g_pressed.grain = 0.0
			g_pressed.sunken = true
			g_disabled = _crafted(Color(0.08, 0.1, 0.22, 0.45), Color(0.05, 0.06, 0.15, 0.45), Color(UiTokens.MINT, 0.12), Color(0.01, 0.02, 0.06, 0.5))
			g_disabled.grain = 0.0
			g_disabled.shadow_size = 0.0
			g_colors = [Color("#dff3ff"), Color.WHITE, UiTokens.MINT, c(look, "faint")]
		_:
			g_normal = _crafted(Color("#3a2b1d"), Color("#22180f"), Color(UiTokens.GOLD, 0.45), Color("#0b0805"))
			g_hover = _crafted(Color("#4a3624"), Color("#2b1e13"), Color(UiTokens.GOLD_BRIGHT, 0.95), Color("#0b0805"))
			g_hover.glow = 1.0
			g_pressed = _crafted(Color("#1d140c"), Color("#2e2014"), Color(UiTokens.GOLD_BRIGHT, 0.95), Color("#0b0805"))
			g_pressed.sunken = true
			g_disabled = _crafted(Color("#241a11"), Color("#1a130c"), Color(UiTokens.HUD_BORDER, 0.3), Color("#0b0805"))
			g_disabled.shadow_size = 0.0
			g_colors = [UiTokens.HUD_TEXT, Color.WHITE, UiTokens.GOLD_BRIGHT, Color(UiTokens.HUD_MUTED, 0.6)]
	_button_variation(t, "GhostButton", [g_normal, g_hover, g_pressed, g_disabled], UiFonts.cinzel(700, 1), 13, g_colors)

	# Danger: deny, abandon.
	var d_normal := _crafted(Color("#7c2618"), Color("#531409"), Color("#ec6a52", 0.75), Color("#1c0703"))
	var d_hover := _crafted(Color("#983322"), Color("#62190c"), Color("#ffb09a", 0.95), Color("#1c0703"))
	d_hover.glow = 1.0
	var d_pressed := _crafted(Color("#4c1208"), Color("#6c1d0f"), Color("#ffb09a", 0.95), Color("#1c0703"))
	d_pressed.sunken = true
	var d_disabled := _crafted(Color("#3a1d16"), Color("#2a140f"), Color("#ec6a52", 0.2), Color("#1c0703"))
	d_disabled.shadow_size = 0.0
	_button_variation(t, "DangerButton", [d_normal, d_hover, d_pressed, d_disabled], UiFonts.cinzel(700, 1), 13,
		[Color("#ffe9e1"), Color.WHITE, Color("#ffd2c4"), Color(1, 0.8, 0.75, 0.35)])

	# Chip: small pill toggles (segments, roots, show details).
	var accent := c(look, "accent")
	var chip_normal := pill_box(accent)
	chip_normal.bg_color = Color(accent, 0.06)
	chip_normal.border_color = Color(accent, 0.35)
	chip_normal.content_margin_left = 11
	chip_normal.content_margin_right = 11
	chip_normal.content_margin_top = 4
	chip_normal.content_margin_bottom = 4
	var chip_hover := chip_normal.duplicate() as StyleBoxFlat
	chip_hover.bg_color = Color(accent, 0.15)
	chip_hover.border_color = Color(accent, 0.75)
	var chip_pressed := chip_normal.duplicate() as StyleBoxFlat
	chip_pressed.bg_color = Color(accent, 0.3 if look != DOCUMENT else 0.16)
	chip_pressed.border_color = accent
	chip_pressed.set_border_width_all(1)
	var chip_disabled := chip_normal.duplicate() as StyleBoxFlat
	chip_disabled.bg_color = Color(0, 0, 0, 0)
	chip_disabled.border_color = Color(c(look, "faint"), 0.3)
	_button_variation(t, "ChipButton", [chip_normal, chip_hover, chip_pressed, chip_disabled], UiFonts.mono(600, 1), 11,
		[c(look, "soft"), c(look, "text"), c(look, "text"), Color(c(look, "faint"), 0.7)])

	# Icon buttons (close, remove): flat until hovered.
	var i_normal := StyleBoxEmpty.new()
	i_normal.set_content_margin_all(4)
	var i_hover := StyleBoxFlat.new()
	i_hover.bg_color = Color(accent, 0.14)
	i_hover.set_corner_radius_all(4)
	i_hover.set_content_margin_all(4)
	var i_pressed := i_hover.duplicate() as StyleBoxFlat
	i_pressed.bg_color = Color(accent, 0.26)
	_button_variation(t, "IconButton", [i_normal, i_hover, i_pressed, i_normal], UiFonts.mono(600, 0), 13,
		[c(look, "muted"), c(look, "text"), c(look, "text"), c(look, "faint")])

	# Rows of a list (folders, changed files): hover tint, selected with a bar on the left.
	var r_normal := StyleBoxFlat.new()
	r_normal.bg_color = Color(0, 0, 0, 0)
	r_normal.content_margin_left = 12
	r_normal.content_margin_right = 10
	r_normal.content_margin_top = 5
	r_normal.content_margin_bottom = 5
	var r_hover := r_normal.duplicate() as StyleBoxFlat
	r_hover.bg_color = Color(accent, 0.09)
	var r_pressed := r_normal.duplicate() as StyleBoxFlat
	r_pressed.bg_color = Color(accent, 0.2 if look != DOCUMENT else 0.13)
	r_pressed.border_color = accent
	r_pressed.border_width_left = 3
	var r_pressed_hover := r_pressed.duplicate() as StyleBoxFlat
	r_pressed_hover.bg_color = Color(accent, 0.26 if look != DOCUMENT else 0.18)
	_button_variation(t, "RowButton", [r_normal, r_hover, r_pressed, r_normal, r_pressed_hover], UiFonts.spectral("Regular"), 15,
		[c(look, "text"), c(look, "text"), c(look, "text"), c(look, "faint")])

	# Selectable cards.
	_button_variation(t, "CardChoice", [card_box(look, "normal"), card_box(look, "hover"), card_box(look, "selected"),
		card_box(look, "disabled"), card_box(look, "selected_hover")], UiFonts.cinzel(700, 1), 13,
		[c(look, "text"), c(look, "text"), c(look, "text"), c(look, "faint")])

	# Check boxes: the box is drawn by CheckToggle; the style leaves room for it.
	var ck := StyleBoxEmpty.new()
	ck.content_margin_left = 28
	ck.content_margin_right = 4
	ck.content_margin_top = 3
	ck.content_margin_bottom = 3
	_button_variation(t, "CheckToggle", [ck, ck, ck, ck], UiFonts.spectral("Regular"), 15,
		[c(look, "soft"), c(look, "text"), c(look, "text"), c(look, "faint")])
