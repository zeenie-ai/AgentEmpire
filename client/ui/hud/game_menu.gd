class_name GameMenu
extends PanelContainer
## The game menu on phones and tablets: Resume, Save, Load, New town, How to play, Sound,
## Graphics, Privacy policy and Quit, under a line with the town's age and townsfolk. The town is
## paused while it is open; closing it puts Game.paused back to what it was. Opened with
## Hud.open_game_menu() from the top bar's Menu button and by Back. Parchment, like Hud.confirm,
## and every button is a full touch target (Platform.TOUCH_TARGET_DP).
##
## Save, Load and New town close the menu, so their toast shows over the town; Sound and Graphics
## apply at once and keep it open.

const PRIVACY_URL := "https://zeenie-ai.github.io/AgentEmpire/privacy/"
const BUTTON_WIDTH := 168.0
const CHOICE_WIDTH := 72.0

var hud: Hud
var input: RtsInput
## What the menu acts on: the Game and Settings autoloads and the system's browser. Tests set
## fakes before the menu enters the tree, so they never save, quit or write settings.
var game: Object = Game
var settings: Object = Settings
var open_url: Callable = OS.shell_open

var _was_paused: bool = false


func setup(hud_layer: Hud, rts_input: RtsInput) -> GameMenu:
	hud = hud_layer
	input = rts_input
	return self


func _enter_tree() -> void:
	_was_paused = game.paused
	game.paused = true


func _exit_tree() -> void:
	game.paused = _was_paused


func _ready() -> void:
	theme_type_variation = "DocumentPanel"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	add_child(box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 24)
	box.add_child(head)
	var title := Label.new()
	title.text = "PAUSED"
	title.theme_type_variation = "TitleLabel"
	title.add_theme_color_override("font_color", UiTokens.SEPIA)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var town := Label.new()
	town.text = town_line()
	town.theme_type_variation = "DocumentLabel"
	town.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(town)
	var rule := ColorRect.new()
	rule.color = Color(UiTokens.SEPIA, 0.45)
	rule.custom_minimum_size = Vector2(0, 1)
	box.add_child(rule)

	box.add_child(_button("Resume", queue_free))
	box.add_child(_row([_button("Save", _save), _button("Load", _load), _button("New town", _new_town)]))

	var options := HBoxContainer.new()
	options.add_theme_constant_override("separation", 6)
	box.add_child(options)
	options.add_child(_caption("Sound"))
	var sound := ButtonGroup.new()
	var on := float(settings.get_value("audio/master", 1.0)) > 0.0
	options.add_child(_choice(sound, "On", on, _set_sound.bind(true)))
	options.add_child(_choice(sound, "Off", not on, _set_sound.bind(false)))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.custom_minimum_size = Vector2(18, 0)
	options.add_child(gap)
	options.add_child(_caption("Graphics"))
	var quality := ButtonGroup.new()
	var current := GraphicsQuality.current_name()
	for preset in GraphicsQuality.NAMES:
		options.add_child(_choice(quality, String(GraphicsQuality.LABELS[preset]), preset == current, _set_graphics.bind(preset)))

	box.add_child(_row([_button("How to play", _how_to_play), _button("Privacy policy", _privacy), _button("Quit", _quit)]))


## "Founding Age  ·  12 townsfolk", or "" before a town runs.
func town_line() -> String:
	var w: SimWorld = game.world
	if w == null:
		return ""
	var n := w.unit_count("townsfolk")
	return "%s Age  ·  %s" % [w.econ.age_name(w.age), "1 townsperson" if n == 1 else "%d townsfolk" % n]


# --- actions -------------------------------------------------------------------------------------

func _save() -> void:
	queue_free()
	game.save_offline()


func _load() -> void:
	queue_free()
	game.load_offline()


func _new_town() -> void:
	hud.confirm("Start a new town?", "A new map with a fresh Keep. This town is lost unless you saved it.", _start_new_town)


func _start_new_town() -> void:
	queue_free()
	game.new_town(randi())


func _how_to_play() -> void:
	hud.open_window(HelpPanel.new())


func _set_sound(on: bool) -> void:
	settings.set_value("audio/master", float(Settings.DEFAULTS["audio/master"]) if on else 0.0)


## Applied live: the world follows the setting (WorldView).
func _set_graphics(preset: String) -> void:
	settings.set_value(GraphicsQuality.SETTING, preset)


func _privacy() -> void:
	open_url.call(PRIVACY_URL)


func _quit() -> void:
	game.save_and_quit()


# --- building blocks -------------------------------------------------------------------------------

func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(BUTTON_WIDTH, Platform.TOUCH_TARGET_DP)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(on_press)
	return b


## One of a few choices, as a segment that stays pressed while it is the current one.
func _choice(group: ButtonGroup, text: String, current: bool, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.button_pressed = current
	b.custom_minimum_size = Vector2(CHOICE_WIDTH, Platform.TOUCH_TARGET_DP)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(on_press)
	return b


func _row(buttons: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	for b: Button in buttons:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	return row


func _caption(text: String) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_override("font", UiFonts.mono(500, 2))
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", UiTokens.SEPIA)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l
