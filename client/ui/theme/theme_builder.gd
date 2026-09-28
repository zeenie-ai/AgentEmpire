class_name ThemeBuilder
extends RefCounted
## Builds the Aurelhaven UI Theme from the handoff tokens (UiTokens):
## - HUD panels: dark wood #1b140e with #6b5230 borders;
## - documents: parchment #f7ecd8 with ink #2a1d14;
## - status windows: navy rgba(14,18,48,.82) with a mint #a9f0d0 border;
## - buttons: terracotta #8f3b25, hover #a8472b, gold #e0b560 border.
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
	_panel_variation(t, "InsetPanel", box(UiTokens.HUD_INSET, UiTokens.HUD_BORDER, 1, UiTokens.RADIUS, 4))
	_panel_variation(t, "DocumentPanel", document_box())
	_panel_variation(t, "StatusPanel", status_box(UiTokens.MINT))

	_label_variation(t, "TitleLabel", UiFonts.cinzel(700, 2), 17, UiTokens.GOLD)
	_label_variation(t, "DisplayLabel", UiFonts.cormorant(600), 28, UiTokens.HUD_TEXT)
	_label_variation(t, "BodyLabel", UiFonts.spectral("Regular"), 15, UiTokens.HUD_SUBTLE)
	_label_variation(t, "MonoLabel", UiFonts.mono(500, 1), 14, UiTokens.HUD_TEXT)
	_label_variation(t, "MutedLabel", UiFonts.mono(500, 2), 11, UiTokens.HUD_MUTED)
	_label_variation(t, "DocumentLabel", UiFonts.spectral("Regular"), 15, UiTokens.INK)
	_label_variation(t, "StatusLabel", UiFonts.spectral("Medium"), 15, Color("#eef6ff"))

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
	var flat := box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, UiTokens.RADIUS, 4)
	var flat_hover := box(Color(1, 1, 1, 0.06), UiTokens.HUD_BORDER, 1, UiTokens.RADIUS, 4)
	t.set_stylebox("normal", "FlatButton", flat)
	t.set_stylebox("hover", "FlatButton", flat_hover)
	t.set_stylebox("pressed", "FlatButton", flat_hover)
	t.set_stylebox("disabled", "FlatButton", flat)
	t.set_stylebox("focus", "FlatButton", StyleBoxEmpty.new())
	t.set_font("font", "FlatButton", UiFonts.mono(500, 1))
	t.set_font_size("font_size", "FlatButton", 14)
	t.set_color("font_color", "FlatButton", UiTokens.HUD_TEXT)

	var tip := document_box()
	tip.content_margin_left = 12
	tip.content_margin_right = 12
	tip.content_margin_top = 8
	tip.content_margin_bottom = 8
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", UiTokens.INK)
	t.set_font("font", "TooltipLabel", UiFonts.spectral("Regular"))
	t.set_font_size("font_size", "TooltipLabel", 15)

	t.set_stylebox("background", "ProgressBar", box(UiTokens.HUD_INSET, UiTokens.HUD_BORDER, 1, UiTokens.RADIUS, 0))
	t.set_stylebox("fill", "ProgressBar", box(UiTokens.GOLD_DEEP, UiTokens.GOLD_BRIGHT.darkened(0.1), 1, UiTokens.RADIUS, 0))
	t.set_font("font", "ProgressBar", UiFonts.mono(500))
	t.set_font_size("font_size", "ProgressBar", 11)
	t.set_color("font_color", "ProgressBar", UiTokens.HUD_TEXT)
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


static func hud_box() -> StyleBoxFlat:
	return box(UiTokens.HUD_BG_SOFT, UiTokens.HUD_BORDER, 1, UiTokens.RADIUS, 10)


static func bar_box() -> StyleBoxFlat:
	var s := box(UiTokens.HUD_BG, UiTokens.HUD_BORDER, 0, 0, 0)
	s.border_width_bottom = 1
	s.content_margin_left = 18
	s.content_margin_right = 18
	s.shadow_color = Color(0, 0, 0, 0.35)
	s.shadow_size = 6
	return s


static func document_box() -> StyleBoxFlat:
	var s := box(UiTokens.PARCHMENT, UiTokens.SEPIA.lightened(0.25), 1, UiTokens.RADIUS, 12)
	s.shadow_color = Color(40.0 / 255.0, 20.0 / 255.0, 5.0 / 255.0, 0.35)
	s.shadow_size = 12
	s.shadow_offset = Vector2(0, 6)
	return s


static func status_box(border: Color) -> StyleBoxFlat:
	var s := box(UiTokens.STATUS_BG, border, 1, UiTokens.RADIUS, 10)
	s.content_margin_top = 7
	s.content_margin_bottom = 7
	return s


static func button_box(bg: Color, border: Color = UiTokens.BTN_BORDER) -> StyleBoxFlat:
	var s := box(bg, border, 1, UiTokens.RADIUS, 6)
	return s


static func _button_styles(t: Theme, type: String) -> void:
	t.set_stylebox("normal", type, button_box(UiTokens.BTN))
	t.set_stylebox("hover", type, button_box(UiTokens.BTN_HOVER, UiTokens.GOLD_BRIGHT))
	t.set_stylebox("pressed", type, button_box(UiTokens.BTN_PRESSED, UiTokens.GOLD_BRIGHT))
	t.set_stylebox("hover_pressed", type, button_box(UiTokens.BTN_PRESSED, UiTokens.GOLD_BRIGHT))
	t.set_stylebox("disabled", type, button_box(UiTokens.BTN_DISABLED, UiTokens.HUD_BORDER))
	t.set_stylebox("focus", type, StyleBoxEmpty.new())


static func _panel_variation(t: Theme, name: String, style: StyleBox) -> void:
	t.set_type_variation(name, "PanelContainer")
	t.set_stylebox("panel", name, style)


static func _label_variation(t: Theme, name: String, font: Font, size: int, color: Color) -> void:
	t.set_type_variation(name, "Label")
	t.set_font("font", name, font)
	t.set_font_size("font_size", name, size)
	t.set_color("font_color", name, color)
