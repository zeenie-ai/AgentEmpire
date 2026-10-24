class_name HelpPanel
extends PanelContainer
## How to play on a phone or tablet: selecting, giving orders, moving the view, the Select toggle,
## building, long-press and Back, a short line each. It opens over the first town once
## (show_once, Settings onboarding/touch_help) and again from the game menu's How to play.
## Parchment, like the game menu; Got it closes it.

const SEEN_KEY := "onboarding/touch_help"
## What the player does, and what it does.
const LINES := [
	["Tap", "Selects a townsperson or a building."],
	["Tap a target", "Gives the selected townsfolk an order there."],
	["Drag", "Moves the view. Pinch to zoom, twist to rotate."],
	["Select, then drag", "Selects everyone in the box you draw."],
	["Build", "Tap a card, drag the outline, then tap Build or Cancel."],
	["Long-press a card", "Shows what it does and what it costs."],
	["Back", "Clears the selection, then opens the menu."],
]
const TEXT_WIDTH := 380.0


## Opens the help over the town if the player has not seen it yet, and remembers that they have
## (in `settings`, the Settings autoload). True when it opened. GameMain calls it when a phone or
## tablet starts.
static func show_once(hud: Hud, settings: Object) -> bool:
	if bool(settings.get_value(SEEN_KEY, false)):
		return false
	settings.set_value(SEEN_KEY, true)
	hud.open_window(HelpPanel.new())
	return true


func _ready() -> void:
	theme_type_variation = "DocumentPanel"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	var title := Label.new()
	title.text = "HOW TO PLAY"
	title.theme_type_variation = "TitleLabel"
	title.add_theme_color_override("font_color", UiTokens.SEPIA)
	box.add_child(title)
	var rule := ColorRect.new()
	rule.color = Color(UiTokens.SEPIA, 0.45)
	rule.custom_minimum_size = Vector2(0, 1)
	box.add_child(rule)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)
	for line: Array in LINES:
		var gesture := Label.new()
		gesture.text = String(line[0]).to_upper()
		gesture.add_theme_font_override("font", UiFonts.cinzel(700, 1))
		gesture.add_theme_font_size_override("font_size", 13)
		gesture.add_theme_color_override("font_color", UiTokens.SEPIA.darkened(0.3))
		gesture.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		grid.add_child(gesture)
		var meaning := Label.new()
		meaning.text = String(line[1])
		meaning.theme_type_variation = "DocumentLabel"
		meaning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		meaning.custom_minimum_size = Vector2(TEXT_WIDTH, 0)
		grid.add_child(meaning)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(row)
	var ok := Button.new()
	ok.text = "Got it"
	ok.custom_minimum_size = Vector2(132, Platform.TOUCH_TARGET_DP)
	ok.focus_mode = Control.FOCUS_NONE
	ok.pressed.connect(queue_free)
	row.add_child(ok)
