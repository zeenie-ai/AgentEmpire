class_name Platform
extends RefCounted
## Which kind of device the game runs on, and the sizes that follow from it. Static, with no
## autoloads, so tools run with -s can use it too.
##
## A phone or tablet (the "mobile" feature) plays the offline town with touch controls and a HUD
## measured in dp: one logical pixel is one Android dp (1/160 inch), whatever the screen. On
## desktop, `-- --mobile` previews that build in a window, with `-- --dpi=<n>` standing in for
## the screen's density (a phone is about 420).

const MOBILE_FLAG := "--mobile"
const DPI_FLAG := "--dpi="
## Android's dp: one dp is one pixel at 160 dpi.
const DP_DPI := 160.0
## Android's touch slop (ViewConfiguration): a press that moves less than this is a tap.
const TOUCH_SLOP_DP := 8.0
## Android's long-press timeout.
const LONG_PRESS_MS := 400
## The smallest touch target Android and Material recommend.
const TOUCH_TARGET_DP := 48.0
## Below this safe width (dp) the HUD uses its compact phone layout. The full top bar, without the
## Town Hall chip and the Mana orb, needs about 1,170 dp.
const COMPACT_BELOW_DP := 1200.0


## True on a phone or tablet, and on desktop with `-- --mobile`.
static func is_mobile() -> bool:
	return OS.has_feature("mobile") or MOBILE_FLAG in OS.get_cmdline_user_args()


## Whether this build can reach a Town Hall. Phones and tablets play offline until they can link
## to the Town Hall on the player's computer.
static func has_town_hall() -> bool:
	return not is_mobile()


## The screen's density in dots per inch: `--dpi=<n>`, else what the display reports.
static func screen_dpi() -> float:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(DPI_FLAG):
			return a.substr(DPI_FLAG.length()).to_float()
	return float(DisplayServer.screen_get_dpi())


## On mobile, sizes the 2D UI in dp: no stretch from the 1600x900 base, and a content scale of
## dpi / 160, so one logical pixel is one dp at any screen size. Desktop keeps the project's
## canvas_items stretch.
static func apply_scale(window: Window) -> void:
	if not is_mobile():
		return
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	window.content_scale_factor = screen_dpi() / DP_DPI


## The logical size of a `screen_px` screen at `dpi` under apply_scale(): the screen in dp.
static func logical_size_at(screen_px: Vector2, dpi: float) -> Vector2:
	return screen_px / (dpi / DP_DPI)


## True when the HUD should use its compact phone layout: on mobile, a safe area narrower than
## COMPACT_BELOW_DP. `vp` is the root viewport.
static func compact(vp: Viewport) -> bool:
	return is_mobile() and compact_at(safe_rect(vp).size.x)


## Whether a safe area `safe_width_dp` wide gets the compact layout.
static func compact_at(safe_width_dp: float) -> bool:
	return safe_width_dp < COMPACT_BELOW_DP


## The part of the viewport clear of camera cutouts and system bars, in viewport (logical)
## coordinates: the display's safe area on a device, the whole visible rect elsewhere.
static func safe_rect(vp: Viewport) -> Rect2:
	if not OS.has_feature("mobile"):
		return vp.get_visible_rect()
	return vp.get_final_transform().affine_inverse() * Rect2(DisplayServer.get_display_safe_area())


## Logical pixels per dp in `vp`: 1.0 on mobile (apply_scale), and on desktop what the
## canvas_items stretch makes of the screen's density.
static func px_per_dp(vp: Viewport) -> float:
	return px_per_dp_at(screen_dpi(), vp.get_final_transform().get_scale().x)


## Logical pixels per dp for a screen of `dpi` drawn at `final_scale` physical pixels per logical
## pixel.
static func px_per_dp_at(dpi: float, final_scale: float) -> float:
	return dpi / DP_DPI / final_scale


## On desktop with `-- --mobile`, the mouse acts as a finger (the engine's touch emulation), so the
## touch controls can be tried in a window.
static func apply_input_mode() -> void:
	if is_mobile() and not OS.has_feature("mobile"):
		Input.emulate_touch_from_mouse = true
