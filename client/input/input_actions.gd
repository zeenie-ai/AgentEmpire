class_name InputActions
extends RefCounted
## Every rebindable action and its default key. Settings registers them in the InputMap at
## startup and then applies the player's saved overrides.
##
## The command card is a 5x3 grid bound to card_0..card_14, laid out on the keyboard as
## Q W E R T / A S D F G / Z X C V B by default (physical keys, so the grid keeps its shape on
## other layouts).

const CARD_SLOTS := 15
const CARD_DEFAULT_KEYS: Array[Key] = [
	KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T,
	KEY_A, KEY_S, KEY_D, KEY_F, KEY_G,
	KEY_Z, KEY_X, KEY_C, KEY_V, KEY_B,
]

## action -> default physical key. Ctrl/Alt variants are resolved in code (camera rotation,
## control-group assignment).
const DEFAULTS := {
	"cam_left": KEY_LEFT,
	"cam_right": KEY_RIGHT,
	"cam_up": KEY_UP,
	"cam_down": KEY_DOWN,
	"select_idle": KEY_PERIOD,
	"select_keep": KEY_H,
	"cancel": KEY_ESCAPE,
	"delete": KEY_DELETE,
	"toggle_night": KEY_F2,
	"toggle_fps": KEY_F3,
	"quick_save": KEY_F5,
	"quick_load": KEY_F9,
	"pause": KEY_PAUSE,
}


static func card_action(slot: int) -> StringName:
	return StringName("card_%d" % slot)


static func group_action(n: int) -> StringName:
	return StringName("group_%d" % n)


static func all_defaults() -> Dictionary:
	var out := DEFAULTS.duplicate()
	for i in CARD_SLOTS:
		out[String(card_action(i))] = CARD_DEFAULT_KEYS[i]
	for n in range(1, 10):
		out[String(group_action(n))] = KEY_0 + n
	return out


## Adds any missing action with its default key. Existing bindings are left alone.
static func register_defaults() -> void:
	var defaults := all_defaults()
	for action: String in defaults:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			InputMap.action_add_event(action, _key_event(int(defaults[action])))


## Replaces the keys of `action` with a single physical key.
static func rebind(action: String, physical_keycode: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, _key_event(physical_keycode))


## Label of the first key bound to `action` ("Q", "Period", ...).
static func key_label(action: StringName) -> String:
	if not InputMap.has_action(action):
		return ""
	for e in InputMap.action_get_events(action):
		var k := e as InputEventKey
		if k != null:
			var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
			var shown := DisplayServer.keyboard_get_keycode_from_physical(code) if k.physical_keycode != KEY_NONE else code
			return OS.get_keycode_string(shown)
	return ""


static func _key_event(physical_keycode: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = physical_keycode as Key
	return e
