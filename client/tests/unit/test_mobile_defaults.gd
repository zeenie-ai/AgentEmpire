extends GutTest
## What a phone or tablet does differently by default: no Town Hall search.


func test_no_town_hall_search_without_a_town_hall() -> void:
	assert_false(Net.wanted_for(false, PackedStringArray()), "a phone or tablet")
	assert_false(Net.wanted_for(false, PackedStringArray(["--mobile"])), "the desktop preview")
	assert_false(Net.wanted_for(true, PackedStringArray(["--offline"])), "desktop with --offline")
	assert_true(Net.wanted_for(true, PackedStringArray()), "desktop")
	# The test run is a desktop run.
	assert_eq(Net.wanted(), not "--offline" in OS.get_cmdline_user_args())
