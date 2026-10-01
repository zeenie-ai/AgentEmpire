class_name ThemeBuilder
extends RefCounted
## Builds the AgentEmpire UI Theme from the handoff tokens (UiTokens), with crafted, layered
## panels (CraftedBox: gradient body, wood grain, bevel, inner shadow, gold trim and studs):
## - HUD panels: dark wood #1b140e with gold #e0b560 trim; insets are sunken into the wood;
## - documents and tooltips: parchment #f7ecd8 with ink #2a1d14;
## - status windows (toasts, hints): navy with a mint #a9f0d0 trim;
## - buttons: terracotta #8f3b25, hover #a8472b with a glowing gold trim, pressed sunk in.
## Type variations: HudPanel, HudBar, InsetPanel, DocumentPanel, StatusPanel, TitleLabel,
## DisplayLabel, BodyLabel, MonoLabel, MutedLabel, DocumentLabel, StatusLabel, CardButton,
## FlatButton.

static var _theme: Theme


static func theme() -> Theme:
	if _theme == null:
		_theme = build()
	return _theme


static func build() -> Theme:
	var t := Theme.new()
	t.default_font = UiFonts.spectral("Regular")
	t.default_font_size = 16

	t.set_color("font_color", "Label", UiTokens.HUD_TEXT)

	t.set_stylebox("panel", "PanelContainer", hud_box())
	t.set_stylebox("panel", "Panel", hud_box())
	_panel_variation(t, "HudPanel", hud_box())
	_panel_variation(t, "HudBar", bar_box())
	_panel_variation(t, "InsetPanel", inset_box())
	_panel_variation(t, "DocumentPanel", document_box())
	_panel_variation(t, "StatusPanel", status_box(UiTokens.MINT))

	_label_variation(t, "TitleLabel", UiFonts.cinzel(700, 2), 17, UiTokens.GOLD)
	_label_variation(t, "DisplayLabel", UiFonts.cormorant(600), 28, UiTokens.HUD_TEXT)
	_label_variation(t, "BodyLabel", UiFonts.spectral("Regular"), 15, UiTokens.HUD_SUBTLE)
	_label_variation(t, "MonoLabel", UiFonts.mono(500, 1), 14, UiTokens.HUD_TEXT)
	_label_variation(t, "MutedLabel", UiFonts.mono(500, 2), 11, UiTokens.HUD_MUTED)
	_label_variation(t, "DocumentLabel", UiFonts.spectral("Regular"), 15, UiTokens.INK)
	_label_variation(t, "StatusLabel", UiFonts.spectral("Medium"), 15, Color("#eef6ff"))
	for v in ["TitleLabel", "DisplayLabel"]:
		t.set_color("font_shadow_color", v, Color(0, 0, 0, 0.55))
		t.set_constant("shadow_offset_x", v, 0)
		t.set_constant("shadow_offset_y", v, 1)

	_button_styles(t, "Button")
	t.set_font("font", "Button", UiFonts.cinzel(700, 1))
	t.set_font_size("font_size", "Button", 13)
	t.set_color("font_color", "Button", UiTokens.BTN_TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", UiTokens.GOLD_BRIGHT)
	t.set_color("font_focus_color", "Button", UiTokens.BTN_TEXT)
	t.set_color("font_disabled_color", "Button", UiTokens.HUD_MUTED.darkened(0.2))

	t.set_type_variation("CardButton", "Button")
	_button_styles(t, "CardButton")

	t.set_type_variation("FlatButton", "Button")
	var flat := StyleBoxEmpty.new()
	flat.set_content_margin_all(4)
	var flat_hover := button_box(Color(0.28, 0.2, 0.13, 0.55), Color(0.16, 0.11, 0.07, 0.55), UiTokens.GOLD)
	flat_hover.trim_color = Color(UiTokens.GOLD, 0.5)
	flat_hover.set_content_margin_all(4)
	t.set_stylebox("normal", "FlatButton", flat)
	t.set_stylebox("hover", "FlatButton", flat_hover)
	t.set_stylebox("pressed", "FlatButton", flat_hover)
	t.set_stylebox("hover_pressed", "FlatButton", flat_hover)
	t.set_stylebox("disabled", "FlatButton", flat)
	t.set_stylebox("focus", "FlatButton", StyleBoxEmpty.new())
	t.set_font("font", "FlatButton", UiFonts.mono(500, 1))
	t.set_font_size("font_size", "FlatButton", 14)
	t.set_color("font_color", "FlatButton", UiTokens.HUD_TEXT)

	# Tooltips: parchment; CraftedTooltip lays out the contents of rich ones.
	var tip := document_box()
	tip.shadow_size = 8.0
	tip.content_margin_left = 14
	tip.content_margin_right = 14
	tip.content_margin_top = 10
	tip.content_margin_bottom = 10
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", UiTokens.INK)
	t.set_font("font", "TooltipLabel", UiFonts.spectral("Regular"))
	t.set_font_size("font_size", "TooltipLabel", 15)

	var bar_bg := inset_box()
	bar_bg.set_content_margin_all(0)
	bar_bg.inner_shadow = 4.0
	t.set_stylebox("background", "ProgressBar", bar_bg)
	var fill := CraftedBox.new()
	fill.top_color = UiTokens.GOLD_BRIGHT
	fill.bottom_color = UiTokens.GOLD_DEEP.darkened(0.15)
	fill.frame_color = Color(0.3, 0.2, 0.08, 0.9)
	fill.trim_width = 0.0
	fill.inner_shadow = 0.0
	fill.shadow_size = 0.0
	fill.grain = 0.0
	fill.set_content_margin_all(0)
	t.set_stylebox("fill", "ProgressBar", fill)
	t.set_font("font", "ProgressBar", UiFonts.mono(500))
	t.set_font_size("font_size", "ProgressBar", 11)
	t.set_color("font_color", "ProgressBar", UiTokens.HUD_TEXT)

	# Option buttons and popups (settings).
	t.set_stylebox("panel", "PopupMenu", hud_box())
	t.set_font("font", "PopupMenu", UiFonts.spectral("Medium"))
	t.set_font_size("font_size", "PopupMenu", 15)
	t.set_color("font_color", "PopupMenu", UiTokens.HUD_TEXT)
	t.set_color("font_hover_color", "PopupMenu", UiTokens.GOLD_BRIGHT)
	var hover_line := StyleBoxFlat.new()
	hover_line.bg_color = Color(UiTokens.BTN, 0.8)
	t.set_stylebox("hover", "PopupMenu", hover_line)
	return t


static func box(bg: Color, border: Color, border_w: int, radius: int, margin: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_w)
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(margin)
	s.anti_aliasing = true
	return s


## The HUD's dark wood panel with gold trim.
static func hud_box() -> CraftedBox:
	var s := CraftedBox.new()
	s.top_color = Color("#2c2016")
	s.bottom_color = Color("#140e09")
	s.set_content_margin_all(12)
	return s


## The top resource bar: a wood beam with a gold line along its lower edge.
static func bar_box() -> CraftedBox:
	var s := CraftedBox.new()
	s.top_color = Color("#2a1f15")
	s.bottom_color = Color("#120d08")
	s.trim_inset = 2.0
	s.studs = false
	s.inner_shadow = 6.0
	s.shadow_size = 10.0
	s.shadow_alpha = 0.5
	s.shadow_offset = Vector2(0, 4)
	s.content_margin_left = 18
	s.content_margin_right = 18
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	return s


## A recess in the wood (minimap frame, selection details, command card).
static func inset_box() -> CraftedBox:
	var s := CraftedBox.new()
	s.top_color = Color("#0f0b07")
	s.bottom_color = Color("#18110b")
	s.frame_color = Color("#070504")
	s.trim_color = Color(UiTokens.HUD_BORDER, 0.8)
	s.trim_inset = 1.0
	s.studs = false
	s.sunken = true
	s.inner_shadow = 12.0
	s.inner_shadow_alpha = 0.55
	s.shadow_size = 0.0
	s.grain = 0.035
	s.set_content_margin_all(6)
	return s


static func document_box() -> CraftedBox:
	var s := CraftedBox.new()
	s.top_color = UiTokens.PARCHMENT
	s.bottom_color = UiTokens.PARCHMENT_DARK.darkened(0.03)
	s.frame_color = UiTokens.SEPIA.darkened(0.2)
	s.trim_color = Color(UiTokens.SEPIA, 0.55)
	s.inner_shadow = 10.0
	s.inner_shadow_alpha = 0.12
	s.grain = 0.05
	s.shadow_size = 12.0
	s.shadow_alpha = 0.4
	s.shadow_offset = Vector2(0, 5)
	s.set_content_margin_all(12)
	return s


## A navy status window whose trim takes `border` (toasts, hints).
static func status_box(border: Color) -> CraftedBox:
	var s := CraftedBox.new()
	s.top_color = Color(0.09, 0.11, 0.27, 0.96)
	s.bottom_color = Color(0.04, 0.05, 0.15, 0.96)
	s.frame_color = Color(0.02, 0.02, 0.07, 0.95)
	s.trim_color = Color(border, 0.9)
	s.trim_inset = 2.0
	s.inner_shadow = 8.0
	s.inner_shadow_alpha = 0.3
	s.grain = 0.0
	s.shadow_size = 10.0
	s.shadow_alpha = 0.45
	s.content_margin_left = 16
	s.content_margin_right = 16
	s.content_margin_top = 9
	s.content_margin_bottom = 9
	return s


## A button face: gradient from `top` to `bottom` with a trim in `trim`.
static func button_box(top: Color, bottom: Color, trim: Color = UiTokens.BTN_BORDER) -> CraftedBox:
	var s := CraftedBox.new()
	s.top_color = top
	s.bottom_color = bottom
	s.trim_color = Color(trim, 0.85)
	s.trim_inset = 2.0
	s.studs = false
	s.inner_shadow = 5.0
	s.inner_shadow_alpha = 0.3
	s.shadow_size = 3.0
	s.shadow_alpha = 0.4
	s.shadow_offset = Vector2(0, 2)
	s.grain = 0.06
	s.set_content_margin_all(6)
	return s


static func _button_styles(t: Theme, type: String) -> void:
	var normal := button_box(Color("#9c4329"), Color("#6f2c1b"))
	var hover := button_box(Color("#b8553a"), Color("#853822"), UiTokens.GOLD_BRIGHT)
	hover.glow = 1.0
	var pressed := button_box(Color("#5f2616"), Color("#7a331f"), UiTokens.GOLD_BRIGHT)
	pressed.sunken = true
	pressed.shadow_size = 0.0
	var disabled := button_box(Color("#2d1f16"), Color("#1d140e"), UiTokens.HUD_BORDER)
	disabled.trim_color = Color(UiTokens.HUD_BORDER, 0.45)
	disabled.sunken = true
	disabled.shadow_size = 0.0
	t.set_stylebox("normal", type, normal)
	t.set_stylebox("hover", type, hover)
	t.set_stylebox("pressed", type, pressed)
	t.set_stylebox("hover_pressed", type, pressed)
	t.set_stylebox("disabled", type, disabled)
	t.set_stylebox("focus", type, StyleBoxEmpty.new())


static func _panel_variation(t: Theme, name: String, style: StyleBox) -> void:
	t.set_type_variation(name, "PanelContainer")
	t.set_stylebox("panel", name, style)


static func _label_variation(t: Theme, name: String, font: Font, size: int, color: Color) -> void:
	t.set_type_variation(name, "Label")
	t.set_font("font", name, font)
	t.set_font_size("font_size", name, size)
	t.set_color("font_color", name, color)
