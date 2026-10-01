extends GutTest
## The Game autoload's Town Hall API with no Town Hall connected (the tests never start one;
## tools/townhall_mode_check.gd covers switching between real Town Halls).

var toasts: Array[String] = []
var modes: Array[String] = []


func before_each() -> void:
	toasts.clear()
	modes.clear()
	Notify.toast.connect(_on_toast)
	Game.town_hall_mode_changed.connect(_on_mode)


func after_each() -> void:
	Notify.toast.disconnect(_on_toast)
	Game.town_hall_mode_changed.disconnect(_on_mode)


func _on_toast(text: String, _kind: String) -> void:
	toasts.append(text)


func _on_mode(mode: String) -> void:
	modes.append(mode)


func test_without_a_town_hall_there_is_no_mode_and_nothing_the_game_started() -> void:
	assert_false(Net.is_online())
	assert_eq(Game.town_hall_mode(), "")
	assert_false(Game.town_hall_launched_by_game())
	assert_false(Game.town_hall_busy())


func test_closing_with_no_town_hall_connected_only_says_so() -> void:
	await Game.close_town_hall()
	assert_true(toasts.has("No Town Hall is connected."), str(toasts))
	assert_false(Game.town_hall_busy())
	assert_eq(modes, [] as Array[String])
