extends GutTest
## The Town Hall chip's menu asks the HUD to switch between practice and real agents or to close
## the Town Hall; it never switches to the mode already running.


func test_the_menu_asks_for_the_other_mode_and_for_closing() -> void:
	var bar := TopBar.new()
	add_child_autofree(bar)
	watch_signals(bar)
	# No Town Hall is connected in the tests, so neither mode is the current one.
	bar._on_hall_menu(TopBar.HALL_REAL)
	assert_signal_emitted_with_parameters(bar, "town_hall_mode_requested", [TownHallLauncher.MODE_REAL])
	bar._on_hall_menu(TopBar.HALL_PRACTICE)
	assert_signal_emitted_with_parameters(bar, "town_hall_mode_requested", [TownHallLauncher.MODE_FAKE])
	assert_signal_emit_count(bar, "town_hall_mode_requested", 2)
	bar._on_hall_menu(TopBar.HALL_CLOSE)
	assert_signal_emitted(bar, "town_hall_close_requested")


func test_the_chip_says_offline_without_a_town_hall() -> void:
	var bar := TopBar.new()
	add_child_autofree(bar)
	bar._refresh_hall()
	assert_eq(bar._hall_label.text, "TOWN HALL OFFLINE")
