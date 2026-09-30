extends Node
## Player settings, stored in user://settings.cfg. Also registers the InputMap actions and
## applies saved key rebinds, so every other system can rely on the actions existing.

signal changed(key: String, value: Variant)

const PATH := "user://settings.cfg"
const DEFAULTS := {
	"camera/edge_scroll": true,
	"camera/pan_speed": 1.0,
	"display/show_fps": false,
	# "" picks the platform default (High on desktop, Low on the web); see GraphicsQuality.
	"graphics/quality": "",
	# Volumes from 0 to 1, one per audio bus (see the Audio autoload).
	"audio/master": 0.8,
	"audio/music": 0.6,
	"audio/sfx": 0.9,
	"audio/ui": 0.8,
	"audio/ambience": 0.6,
	# Quiet the game while its window is in the background.
	"audio/mute_unfocused": true,
	"game/seed": 4127,
	# First-run onboarding: whether it is finished, and the work folder the player chose for
	# new agents (the Summoning dialog's default).
	"onboarding/done": false,
	"onboarding/work_folder": "",
	# Start the Town Hall when the game opens and none is running (desktop).
	"townhall/auto_start": true,
	# What the auto-started Town Hall runs: "fake" (scripted agents) or "real" (the installed
	# Claude Code, Codex and pi).
	"townhall/provider": "fake",
}

var _values: Dictionary = {}
var _keybinds: Dictionary = {}


func _ready() -> void:
	_values = DEFAULTS.duplicate()
	_load()
	InputActions.register_defaults()
	for action: String in _keybinds:
		InputActions.rebind(action, int(_keybinds[action]))


func get_value(key: String, fallback: Variant = null) -> Variant:
	return _values.get(key, DEFAULTS.get(key, fallback))


func set_value(key: String, value: Variant) -> void:
	_values[key] = value
	_save()
	changed.emit(key, value)


## Rebinds an action to a physical key and remembers it.
func rebind(action: String, physical_keycode: int) -> void:
	InputActions.rebind(action, physical_keycode)
	_keybinds[action] = physical_keycode
	_save()
	changed.emit("keybind/" + action, physical_keycode)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for key: String in DEFAULTS:
		var parts := key.split("/")
		if cfg.has_section_key(parts[0], parts[1]):
			_values[key] = cfg.get_value(parts[0], parts[1])
	if cfg.has_section("keybinds"):
		for action in cfg.get_section_keys("keybinds"):
			_keybinds[action] = int(cfg.get_value("keybinds", action))


func _save() -> void:
	var cfg := ConfigFile.new()
	for key: String in _values:
		var parts := key.split("/")
		if parts.size() == 2:
			cfg.set_value(parts[0], parts[1], _values[key])
	for action: String in _keybinds:
		cfg.set_value("keybinds", action, _keybinds[action])
	cfg.save(PATH)
