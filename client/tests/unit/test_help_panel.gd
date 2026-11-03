extends GutTest
## The touch help: it opens over the first town once, explains the touch scheme, and fits the
## smallest phone. A fake stands in for Settings, so nothing is written.

const FakeHud = preload("res://tests/fixtures/fake_hud.gd")
## The smallest phone screen the HUD supports, in dp.
const SMALL_PHONE := Vector2(640, 360)


class FakeSettings:
	extends RefCounted
	var values: Dictionary = {}

	func get_value(key: String, fallback: Variant = null) -> Variant:
		return values.get(key, fallback)

	func set_value(key: String, value: Variant) -> void:
		values[key] = value


var _hud: FakeHud


func before_each() -> void:
	_hud = autofree(FakeHud.new())


func after_each() -> void:
	_hud.free_windows()


func _help() -> HelpPanel:
	return add_child_autofree(HelpPanel.new())


func test_the_help_opens_once() -> void:
	var settings := FakeSettings.new()
	assert_true(HelpPanel.show_once(_hud, settings))
	assert_eq(_hud.windows.size(), 1)
	assert_true(_hud.windows[0] is HelpPanel)
	assert_eq(settings.values.get(HelpPanel.SEEN_KEY), true)
	assert_false(HelpPanel.show_once(_hud, settings), "not a second time")
	assert_eq(_hud.windows.size(), 1)


func test_the_help_explains_the_touch_scheme() -> void:
	var text := ""
	for l: Label in _help().find_children("*", "Label", true, false):
		text += l.text.to_lower() + "\n"
	for words: String in ["tap", "a target", "drag", "pinch", "twist", "select", "build", "cancel", "long-press",
			"back", "clears the selection", "menu"]:
		assert_string_contains(text, words)


func test_got_it_closes_the_help() -> void:
	var p := _help()
	var ok: Button = null
	for b: Button in p.find_children("*", "Button", true, false):
		ok = b
	assert_eq(ok.text, "Got it")
	assert_gte(ok.get_combined_minimum_size().y, Platform.TOUCH_TARGET_DP)
	ok.pressed.emit()
	assert_true(p.is_queued_for_deletion())


func test_the_help_fits_the_smallest_phone() -> void:
	var p := _help()
	await wait_process_frames(2)
	var need := p.get_combined_minimum_size()
	assert_lt(need.x, SMALL_PHONE.x - 32.0, "width %d" % need.x)
	assert_lt(need.y, SMALL_PHONE.y - 16.0, "height %d" % need.y)
