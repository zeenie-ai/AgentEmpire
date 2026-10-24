extends GutTest
## What a phone or tablet does differently by default: no Town Hall search, Low graphics, and
## selection rings drawn without decals on the Mobile renderer.


func test_no_town_hall_search_without_a_town_hall() -> void:
	assert_false(Net.wanted_for(false, PackedStringArray()), "a phone or tablet")
	assert_false(Net.wanted_for(false, PackedStringArray(["--mobile"])), "the desktop preview")
	assert_false(Net.wanted_for(true, PackedStringArray(["--offline"])), "desktop with --offline")
	assert_true(Net.wanted_for(true, PackedStringArray()), "desktop")
	# The test run is a desktop run.
	assert_eq(Net.wanted(), not "--offline" in OS.get_cmdline_user_args())


func test_low_graphics_by_default_on_the_web_and_on_mobile() -> void:
	assert_eq(GraphicsQuality.default_for(false, true), GraphicsQuality.LOW, "phones and tablets")
	assert_eq(GraphicsQuality.default_for(true, false), GraphicsQuality.LOW, "the web")
	assert_eq(GraphicsQuality.default_for(false, false), GraphicsQuality.HIGH, "desktop")
	assert_eq(GraphicsQuality.default_name(), GraphicsQuality.HIGH, "this desktop run")


func test_selection_rings_are_decals_only_on_forward_plus() -> void:
	var low := GraphicsQuality.preset(GraphicsQuality.LOW)
	var medium := GraphicsQuality.preset(GraphicsQuality.MEDIUM)
	var high := GraphicsQuality.preset(GraphicsQuality.HIGH)
	assert_true(GraphicsQuality.decals_for(high, "forward_plus"))
	assert_true(GraphicsQuality.decals_for(medium, "forward_plus"))
	assert_false(GraphicsQuality.decals_for(low, "forward_plus"), "Low draws the MultiMesh rings")
	# The Mobile renderer applies at most 8 decals to each mesh: a group's rings vanished.
	assert_false(GraphicsQuality.decals_for(high, "mobile"))
	assert_false(GraphicsQuality.decals_for(medium, "mobile"))
	assert_false(GraphicsQuality.decals_for(high, "gl_compatibility"), "no decals there at all")
