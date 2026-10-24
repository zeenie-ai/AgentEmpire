extends GutTest
## The game menu: the pause it holds, its actions and its touch-sized buttons. Fakes stand in for
## Game, Settings and the browser, so nothing is saved, quit, written or opened.

const FakeHud = preload("res://tests/fixtures/fake_hud.gd")
## The smallest phone screen the HUD supports, in dp.
const SMALL_PHONE := Vector2(640, 360)


class FakeGame:
	extends RefCounted
	var paused: bool = false
	var world: SimWorld = null
	var calls: Array[String] = []

	func save_offline(_slot: String = "quick") -> bool:
		calls.append("save")
		return true

	func load_offline(_slot: String = "quick") -> bool:
		calls.append("load")
		return true

	func new_town(_map_seed: int, _town_id: String = "") -> SimWorld:
		calls.append("new_town")
		return null

	func save_and_quit() -> void:
		calls.append("quit")


class FakeSettings:
	extends RefCounted
	var values: Dictionary = {}

	func get_value(key: String, fallback: Variant = null) -> Variant:
		return values.get(key, fallback)

	func set_value(key: String, value: Variant) -> void:
		values[key] = value


var _hud: FakeHud
var _game: FakeGame
var _settings: FakeSettings
var _urls: Array[String] = []


func before_each() -> void:
	_hud = autofree(FakeHud.new())
	_game = FakeGame.new()
	_settings = FakeSettings.new()
	_settings.values = {"audio/master": 0.8}
	_urls.clear()


func after_each() -> void:
	_hud.free_windows()


func _menu() -> GameMenu:
	var m := GameMenu.new()
	m.game = _game
	m.settings = _settings
	m.open_url = func(url: String) -> Error:
		_urls.append(url)
		return OK
	m.setup(_hud, null)
	add_child_autofree(m)
	return m


func _button(panel: Control, text: String) -> Button:
	for b: Button in panel.find_children("*", "Button", true, false):
		if b.text == text:
			return b
	fail_test("no %s button" % text)
	return null


# --- the menu ------------------------------------------------------------------------------------

func test_the_town_waits_while_the_menu_is_open() -> void:
	var m := _menu()
	assert_true(_game.paused, "paused while open")
	remove_child(m)
	assert_false(_game.paused, "running again once it closes")


func test_a_town_paused_before_stays_paused() -> void:
	_game.paused = true
	var m := _menu()
	remove_child(m)
	assert_true(_game.paused)


func test_every_button_is_a_touch_target() -> void:
	var m := _menu()
	var buttons := m.find_children("*", "Button", true, false)
	assert_eq(buttons.size(), 12, "Resume, Save, Load, New town, Sound on and off, three presets, How to play, Privacy policy, Quit")
	for b: Button in buttons:
		assert_gte(b.get_combined_minimum_size().y, Platform.TOUCH_TARGET_DP, "%s is a touch target" % b.text)


func test_the_menu_fits_the_smallest_phone() -> void:
	var m := _menu()
	var need := m.get_combined_minimum_size()
	assert_lt(need.x, SMALL_PHONE.x - 32.0, "width %d" % need.x)
	assert_lt(need.y, SMALL_PHONE.y - 16.0, "height %d" % need.y)


func test_the_header_names_the_age_and_the_townsfolk() -> void:
	assert_eq(_menu().town_line(), "", "no town yet")
	var w := SimFixture.generated_world(1234)
	_game.world = w
	assert_eq(_menu().town_line(), "%s Age  ·  %d townsfolk" % [w.econ.age_name(w.age), w.unit_count("townsfolk")])


func test_resume_save_and_load_close_the_menu() -> void:
	for text: String in ["Resume", "Save", "Load"]:
		var m := _menu()
		_button(m, text).pressed.emit()
		assert_true(m.is_queued_for_deletion(), "%s closes the menu" % text)
	assert_eq(_game.calls, ["save", "load"] as Array[String])


func test_new_town_asks_first() -> void:
	var m := _menu()
	_button(m, "New town").pressed.emit()
	assert_eq(_game.calls.size(), 0, "nothing happens before Yes")
	assert_eq(_hud.confirms.size(), 1)
	assert_false(m.is_queued_for_deletion())
	var on_yes: Callable = _hud.confirms[0][2]
	on_yes.call()
	assert_eq(_game.calls, ["new_town"] as Array[String])
	assert_true(m.is_queued_for_deletion(), "the new town opens without the menu")


func test_how_to_play_opens_the_help_over_the_menu() -> void:
	var m := _menu()
	_button(m, "How to play").pressed.emit()
	assert_eq(_hud.windows.size(), 1)
	assert_true(_hud.windows[0] is HelpPanel)
	assert_false(m.is_queued_for_deletion(), "the menu waits under it")


func test_sound_goes_off_and_back_to_its_default() -> void:
	var m := _menu()
	assert_true(_button(m, "On").button_pressed)
	_button(m, "Off").pressed.emit()
	assert_eq(float(_settings.values["audio/master"]), 0.0)
	_button(m, "On").pressed.emit()
	assert_eq(float(_settings.values["audio/master"]), float(Settings.DEFAULTS["audio/master"]))
	assert_false(m.is_queued_for_deletion(), "the menu stays open")


func test_sound_that_is_off_shows_as_off() -> void:
	_settings.values["audio/master"] = 0.0
	var m := _menu()
	assert_true(_button(m, "Off").button_pressed)
	assert_false(_button(m, "On").button_pressed)


func test_each_graphics_preset_goes_to_the_setting() -> void:
	var m := _menu()
	assert_true(_button(m, String(GraphicsQuality.LABELS[GraphicsQuality.current_name()])).button_pressed,
		"the preset in effect is the pressed one")
	for preset: String in GraphicsQuality.NAMES:
		_button(m, String(GraphicsQuality.LABELS[preset])).pressed.emit()
		assert_eq(_settings.values.get(GraphicsQuality.SETTING), preset)
	assert_false(m.is_queued_for_deletion())


func test_privacy_policy_opens_the_page() -> void:
	_button(_menu(), "Privacy policy").pressed.emit()
	assert_eq(_urls, ["https://zeenie-ai.github.io/AgentEmpire/privacy/"] as Array[String])


func test_quit_saves_and_quits() -> void:
	_button(_menu(), "Quit").pressed.emit()
	assert_eq(_game.calls, ["quit"] as Array[String])
