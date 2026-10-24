extends GutTest
## BackChain: Android's Back undoes the most recent thing first (a touch tip or the minimap
## overlay, the top window, placement, the Select toggle, the selection) and otherwise opens the
## game menu; it never quits. Coming back from the background opens the menu on a phone.

const FakeHud = preload("res://tests/fixtures/fake_hud.gd")

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
	_chain.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
	assert_true(_input.selection.is_empty())
	_chain.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
	assert_eq(_hud.menus, 1)


func test_coming_back_on_a_phone_opens_the_menu() -> void:
	_chain.mobile = true
	_chain.notification(NOTIFICATION_APPLICATION_RESUMED)
	assert_eq(_hud.menus, 0, "once the notification has gone round the tree")
	await wait_process_frames(2)
	assert_eq(_hud.menus, 1)


func test_coming_back_to_an_open_window_leaves_it() -> void:
	_chain.mobile = true
	_hud.open_window(Control.new())
	_chain.notification(NOTIFICATION_APPLICATION_RESUMED)
	await wait_process_frames(2)
	assert_eq(_hud.menus, 0)


func test_desktop_does_not_open_the_menu_on_resume() -> void:
	_chain.mobile = false
	_chain.notification(NOTIFICATION_APPLICATION_RESUMED)
	await wait_process_frames(2)
	assert_eq(_hud.menus, 0)
