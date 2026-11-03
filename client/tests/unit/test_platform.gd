extends GutTest
## Platform: the dp arithmetic behind the phone and tablet HUD.


func test_dp_scale_makes_one_logical_px_one_dp() -> void:
	# A 6.5-inch phone: 2400x1080 at 420 dpi.
	var phone := Platform.logical_size_at(Vector2(2400, 1080), 420.0)
	assert_almost_eq(phone.x, 914.29, 0.01)
	assert_almost_eq(phone.y, 411.43, 0.01)
	# A 10-inch tablet: 2560x1600 at 320 dpi.
	assert_eq(Platform.logical_size_at(Vector2(2560, 1600), 320.0), Vector2(1280, 800))


func test_px_per_dp() -> void:
	# The desktop stretch: a 2400x1080 window over the 1600x900 base draws 1.2 pixels per logical
	# pixel, so one dp at 420 dpi is 2.1875 logical pixels.
	assert_almost_eq(Platform.px_per_dp_at(420.0, 1080.0 / 900.0), 2.1875, 0.0001)
	# The mobile scale (dpi / 160 pixels per logical pixel): one dp is one logical pixel.
	assert_almost_eq(Platform.px_per_dp_at(420.0, 420.0 / 160.0), 1.0, 0.0001)


func test_compact_layout_below_1200_dp() -> void:
	assert_true(Platform.compact_at(914.0), "a landscape phone")
	assert_true(Platform.compact_at(1097.0), "a small tablet")
	assert_false(Platform.compact_at(1280.0), "a 10-inch tablet")
	assert_false(Platform.compact_at(1430.0), "a large tablet")


func test_desktop_is_not_mobile() -> void:
	# The test run is a desktop run without --mobile.
	assert_false(Platform.is_mobile())
	assert_true(Platform.has_town_hall())
