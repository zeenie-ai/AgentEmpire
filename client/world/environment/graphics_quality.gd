class_name GraphicsQuality
extends RefCounted
## Low, Medium and High graphics presets (Settings "graphics/quality"; High by default on
## desktop, Low on the web). A preset is plain data that SkyEnvironment, the viewport and the
## views apply. Features a renderer lacks (the web's Compatibility renderer has no SSAO, SSIL,
## volumetric fog, depth of field or decals) are skipped there, so every preset runs everywhere.
##
## Anti-aliasing: MSAA 4x resolves geometry edges (roof lines, fences, grass blades) crisply,
## and SMAA on top cleans up shader and texture aliasing without the smearing that TAA gives
## small moving units and camera pans. Low swaps in 2x MSAA and FXAA for integrated GPUs.

const LOW := "low"
const MEDIUM := "medium"
const HIGH := "high"
const NAMES: Array[String] = [LOW, MEDIUM, HIGH]
const LABELS := {LOW: "Low", MEDIUM: "Medium", HIGH: "High"}
const SETTING := "graphics/quality"


static func default_name() -> String:
	return LOW if OS.has_feature("web") else HIGH


## The preset name in effect (a command-line "--quality=<name>" wins over the saved setting).
static func current_name() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--quality="):
			var forced := a.substr(10).to_lower()
			if forced in NAMES:
				return forced
	var tree := Engine.get_main_loop() as SceneTree
	var settings: Node = tree.root.get_node_or_null("Settings") if tree != null else null
	var q := String(settings.call("get_value", SETTING, default_name())) if settings != null else default_name()
	return q if q in NAMES else default_name()


static func current() -> Dictionary:
	return preset(current_name())


static func is_forward_plus() -> bool:
	return RenderingServer.get_current_rendering_method() == "forward_plus"


static func is_compatibility() -> bool:
	return RenderingServer.get_current_rendering_method() == "gl_compatibility"


static func preset(name: String) -> Dictionary:
	match name:
		LOW:
			return {
				"name": LOW, "msaa": Viewport.MSAA_2X, "screen_aa": Viewport.SCREEN_SPACE_AA_FXAA,
				"shadow_size": 2048, "shadow_filter": RenderingServer.SHADOW_QUALITY_SOFT_LOW,
				"shadow_splits": 2, "shadow_softness": 0.0, "shadow_blur": 1.6,
				"ssao": false, "ssil": false, "volumetric_fog": false, "dof": false, "glow": true,
				"grass": 0.35, "particles": 0.5, "decals": false, "clouds": true, "debanding": false,
			}
		MEDIUM:
			return {
				"name": MEDIUM, "msaa": Viewport.MSAA_4X, "screen_aa": Viewport.SCREEN_SPACE_AA_FXAA,
				"shadow_size": 4096, "shadow_filter": RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM,
				"shadow_splits": 3, "shadow_softness": 0.0, "shadow_blur": 1.3,
				"ssao": true, "ssil": false, "volumetric_fog": false, "dof": true, "glow": true,
				"grass": 0.7, "particles": 0.8, "decals": true, "clouds": true, "debanding": true,
			}
	return {
		"name": HIGH, "msaa": Viewport.MSAA_4X, "screen_aa": Viewport.SCREEN_SPACE_AA_SMAA,
		"shadow_size": 4096, "shadow_filter": RenderingServer.SHADOW_QUALITY_SOFT_HIGH,
		"shadow_splits": 4, "shadow_softness": 0.9, "shadow_blur": 1.0,
		"ssao": true, "ssil": true, "volumetric_fog": true, "dof": true, "glow": true,
		"grass": 1.0, "particles": 1.0, "decals": true, "clouds": true, "debanding": true,
	}


## Viewport anti-aliasing and debanding.
static func apply_viewport(vp: Viewport, q: Dictionary) -> void:
	if vp == null:
		return
	vp.msaa_3d = int(q["msaa"])
	vp.use_taa = false
	if not is_compatibility():
		vp.screen_space_aa = int(q["screen_aa"])
		vp.use_debanding = bool(q["debanding"])


## The directional shadow atlas and its filter (global to the renderer).
static func apply_shadow_atlas(q: Dictionary) -> void:
	RenderingServer.directional_shadow_atlas_set_size(int(q["shadow_size"]), not is_forward_plus())
	RenderingServer.directional_soft_shadow_filter_set_quality(int(q["shadow_filter"]))


## True when decals (selection rings) are available and wanted.
static func use_decals(q: Dictionary) -> bool:
	return bool(q.get("decals", false)) and not is_compatibility()


## True when GPU particles should be used (CPU particles on the Compatibility renderer).
static func use_gpu_particles() -> bool:
	return not is_compatibility()
