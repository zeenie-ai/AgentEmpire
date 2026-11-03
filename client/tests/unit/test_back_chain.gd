extends GutTest
## BackChain: Android's Back undoes the most recent thing first (a touch tip or the minimap
## overlay, the top window, placement, the Select toggle, the selection) and otherwise opens the
## game menu; it never quits. Coming back from the background opens the menu on a phone.

const FakeHud = preload("res://tests/fixtures/fake_hud.gd")


## What a game menu reads and pauses, in place of the Game autoload.
class FakeGame:
	extends RefCounted
	var paused: bool = false
	var world: SimWorld = null


var _hud: FakeHud
var _input: RtsInput
var _chain: BackChain


func before_each() -> void:
	_hud = autofree(FakeHud.new())
	# Out of the tree: only its state and the calls Back makes are used.
	_input = autofree(RtsInput.new())
	_input.selection = Selection.new()
	_chain = add_child_autofree(BackChain.new())
	_chain.setup(_hud, _input)


func after_each() -> void:
	TouchTip.dismiss()
	_hud.free_windows()


func test_each_press_undoes_the_latest_thing_and_the_last_opens_the_menu() -> void:
	var chip: Button = add_child_autofree(Button.new())
	chip.tooltip_text = "Wood: 120"
	TouchTip.show_for(chip)
	_hud.overlay = true
	_hud.open_window(Control.new())
	_hud.open_window(Control.new())
	_input.mode = RtsInput.Mode.PLACE
	_input.drag_selects = true
	_input.selection.set_ids([3, 4])
	watch_signals(_input)

	_chain.go_back()
	assert_false(TouchTip.showing(), "1. the tip")
	assert_true(_hud.overlay, "one thing per press")
	_chain.go_back()
	assert_false(_hud.overlay, "2. the minimap overlay")
	assert_eq(_hud.windows.size(), 2)
	_chain.go_back()
	assert_eq(_hud.windows.size(), 1, "3. the top window")
	_chain.go_back()
	assert_eq(_hud.windows.size(), 0, "and then the one under it")
	assert_eq(_input.mode, RtsInput.Mode.PLACE)
	_chain.go_back()
	assert_eq(_input.mode, RtsInput.Mode.SELECT, "4. placement")
	assert_true(_input.drag_selects)
	_chain.go_back()
	assert_false(_input.drag_selects, "5. the Select toggle")
	assert_signal_emitted_with_parameters(_input, "drag_selects_changed", [false])
	assert_eq(_input.selection.ids.size(), 2)
	_chain.go_back()
	assert_true(_input.selection.is_empty(), "6. the selection")
	assert_eq(_hud.menus, 0)
	_chain.go_back()
	assert_eq(_hud.menus, 1, "7. the game menu")


func test_rally_mode_is_cancelled_like_placement() -> void:
	_input.mode = RtsInput.Mode.RALLY
	_input.selection.set_ids([7])
	_chain.go_back()
	assert_eq(_input.mode, RtsInput.Mode.SELECT)
	assert_false(_input.selection.is_empty(), "the building stays selected")


func test_the_back_button_goes_back() -> void:
	_input.selection.set_ids([5])
	_go_back_notice()
	await wait_process_frames(2)
	assert_true(_input.selection.is_empty())
	_go_back_notice()
	await wait_process_frames(2)
	assert_eq(_hud.menus, 1)


# --- one press, one step (godotengine/godot#123454) ----------------------------------------------
# Each Back step below opens a game menu on the empty town, so _hud.menus counts the steps. Key
# events reach the game at the start of a frame; the key's own go-back notification follows its
# event in the same frame; the back dispatcher's arrives between frames.

func _key(pressed: bool, echo: bool = false) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = KEY_BACK
	e.keycode = KEY_BACK
	e.pressed = pressed
	e.echo = echo
	_chain._input(e)


func _go_back_notice() -> void:
	_chain.notification(NOTIFICATION_WM_GO_BACK_REQUEST)


func test_a_back_key_tap_on_android_16_takes_one_step() -> void:
	# adb's keyevent or a quick tap: the dispatcher's notification comes before the key events.
	_go_back_notice()
	_key(true)
	_key(false)
	_go_back_notice()
	await wait_process_frames(2)
	assert_eq(_hud.menus, 1)


func test_a_held_back_key_on_android_16_takes_one_step() -> void:
	_key(true)
	_go_back_notice()
	await wait_process_frames(1)
	assert_eq(_hud.menus, 1, "the step comes with the key's down event")
	for i in 3:
		_key(true, true)
		_go_back_notice()
		await wait_process_frames(1)
	_go_back_notice()
	await wait_process_frames(1)
	_key(false)
	await wait_process_frames(2)
	assert_eq(_hud.menus, 1, "repeats and the dispatcher's notification add none")


func test_the_dispatcher_may_answer_after_the_key_is_up() -> void:
	_key(true)
	_go_back_notice()
	await wait_process_frames(1)
	_key(false)
	await wait_process_frames(1)
	_go_back_notice()
	await wait_process_frames(2)
	assert_eq(_hud.menus, 1)


func test_each_back_gesture_takes_one_step() -> void:
	_go_back_notice()
	await wait_process_frames(2)
	assert_eq(_hud.menus, 1)
	_go_back_notice()
	await wait_process_frames(2)
	assert_eq(_hud.menus, 2)


func test_the_back_key_takes_one_step_before_android_16() -> void:
	# Android 15 and older: no dispatcher notification, only the key's own.
	_key(true)
	_go_back_notice()
	await wait_process_frames(1)
	_key(true, true)
	_go_back_notice()
	await wait_process_frames(1)
	_key(false)
	await wait_process_frames(2)
	assert_eq(_hud.menus, 1, "a held press")
	_key(true)
	_key(false)
	_go_back_notice()
	await wait_process_frames(2)
	assert_eq(_hud.menus, 2, "a tap")


func test_two_quick_taps_take_two_steps() -> void:
	# Both dispatcher notifications arrive before the frame that brings both key presses.
	_go_back_notice()
	_go_back_notice()
	_key(true)
	_key(false)
	_key(true)
	_key(false)
	_go_back_notice()
	_go_back_notice()
	await wait_process_frames(2)
	assert_eq(_hud.menus, 2)


func test_desktop_leaves_the_back_key_alone() -> void:
	# A keyboard's Back (browser) key must not open the game menu on desktop.
	assert_false(_chain.is_processing_input())


func test_coming_back_on_a_phone_opens_the_menu() -> void:
	_chain.mobile = true
	_chain.notification(NOTIFICATION_APPLICATION_RESUMED)
	assert_eq(_hud.menus, 0, "once the notification has gone round the tree")
	await wait_process_frames(2)
	assert_eq(_hud.menus, 1)


func test_coming_back_opens_the_menu_over_another_window() -> void:
	# The help, say: the town was paused in the background, so it needs the menu's Resume.
	_chain.mobile = true
	_hud.open_window(Control.new())
	_chain.notification(NOTIFICATION_APPLICATION_RESUMED)
	await wait_process_frames(2)
	assert_eq(_hud.menus, 1)


func test_coming_back_to_an_open_menu_leaves_it() -> void:
	_chain.mobile = true
	var menu := GameMenu.new()
	menu.game = FakeGame.new()
	add_child_autofree(menu.setup(_hud, _input))
	_chain.notification(NOTIFICATION_APPLICATION_RESUMED)
	await wait_process_frames(2)
	assert_eq(_hud.menus, 0, "no second menu")


func test_desktop_does_not_open_the_menu_on_resume() -> void:
	_chain.mobile = false
	_chain.notification(NOTIFICATION_APPLICATION_RESUMED)
	await wait_process_frames(2)
	assert_eq(_hud.menus, 0)
