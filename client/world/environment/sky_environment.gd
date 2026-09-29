class_name SkyEnvironment
extends Node3D
## The town's light and atmosphere, after the handoff's warm dawn (city-scene.js), made cosy:
## - a warm soft sky (sky.gdshader) that also provides ambient light and reflections;
## - a low golden sun from the south-west with soft, stable shadows whose range and splits
##   follow the camera's zoom (1 unit = 1 tile);
## - AgX tonemapping, subtle SSAO and SSIL, soft glow, depth fog and a thin volumetric haze,
##   gentle colour adjustments;
## - a tilt-shift depth of field around the camera's focus point, stronger when zoomed in,
##   for the miniature-diorama feel;
## - drifting cloud shadows and wind (global shader parameters "cloud_offset", "wind_time").
## set_night() lerps everything toward the handoff's night navy #0d1230 with cool moonlight and
## makes the windows glow. Quality presets (GraphicsQuality) switch the costly features.

const SKY_SHADER := preload("res://world/environment/sky.gdshader")
const WIND := Vector2(0.9, 0.4)

## Day and night looks; set_night() lerps between them.
const DAY := {
	"zenith": Color("#86acd8"), "horizon": Color("#ffdcb6"), "ground": Color("#8a9463"), "halo": Color("#ffd29a"),
	"sun_color": Color("#ffe4c4"), "sun_energy": 1.55, "ambient_color": Color("#fff1dc"), "ambient_energy": 0.62,
	"fog_color": Color("#f2d4b4"), "sky_energy": 1.0, "stars": 0.0, "glow": 0.32, "exposure": 1.05,
	"vol_albedo": Color("#fff0dc"), "cloud": 0.28,
}
const NIGHT := {
	"zenith": Color("#0b1030"), "horizon": Color("#27305e"), "ground": Color("#10142a"), "halo": Color("#8fa4ff"),
	"sun_color": Color("#8fa6ff"), "sun_energy": 0.42, "ambient_color": Color("#5a6bb0"), "ambient_energy": 0.38,
	"fog_color": Color("#1a2150"), "sky_energy": 1.0, "stars": 1.0, "glow": 0.75, "exposure": 1.25,
	"vol_albedo": Color("#6a78c0"), "cloud": 0.1,
}

var environment: Environment
var world_environment: WorldEnvironment
var camera_attributes: CameraAttributesPractical
var sun: DirectionalLight3D
var sky_material: ShaderMaterial
var night: float = 0.0
var quality: Dictionary = {}
## Set false by tools that want a sharp capture.
var dof_enabled: bool = true

var _tween: Tween
var _time: float = 0.0
var _cloud: Vector2 = Vector2.ZERO
var _focus: float = 30.0


func _ready() -> void:
	sky_material = ShaderMaterial.new()
	sky_material.shader = SKY_SHADER
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_AUTOMATIC
	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 0.55
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.tonemap_agx_contrast = 1.18
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_depth_curve = 1.6
	environment.fog_density = 0.62
	environment.fog_aerial_perspective = 0.35
	environment.fog_sky_affect = 0.6
	environment.fog_sun_scatter = 0.25
	environment.glow_enabled = true
	environment.glow_normalized = true
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	environment.glow_hdr_threshold = 0.9
	environment.glow_bloom = 0.03
	environment.glow_strength = 1.0
	for i in 7:
		environment.set_glow_level(i, 1.0 if i in [1, 2, 3, 4] else 0.0)
	environment.adjustment_enabled = true
	environment.adjustment_saturation = 1.14
	environment.adjustment_contrast = 1.05
	environment.adjustment_brightness = 1.0
	environment.ssao_radius = 0.8
	environment.ssao_intensity = 1.4
	environment.ssao_power = 1.4
	environment.ssao_detail = 0.6
	environment.ssao_horizon = 0.06
	environment.ssao_sharpness = 0.98
	environment.ssao_light_affect = 0.05
	environment.ssil_radius = 3.0
	environment.ssil_intensity = 0.55
	environment.ssil_sharpness = 0.98
	environment.volumetric_fog_density = 0.0028
	environment.volumetric_fog_anisotropy = 0.55
	environment.volumetric_fog_length = 90.0
	environment.volumetric_fog_detail_spread = 2.0
	environment.volumetric_fog_ambient_inject = 0.35
	environment.volumetric_fog_sky_affect = 0.2
	camera_attributes = CameraAttributesPractical.new()
	camera_attributes.dof_blur_far_enabled = true
	camera_attributes.dof_blur_near_enabled = true
	world_environment = WorldEnvironment.new()
	world_environment.environment = environment
	world_environment.camera_attributes = camera_attributes
	add_child(world_environment)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.85
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.0
	sun.light_specular = 0.4
	add_child(sun)
	# city-scene.js puts the sun at (-30, 26, 18): low from the south-west, so building fronts
	# (facing +Z, toward the default camera) are lit and shadows fall away up-right.
	sun.look_at_from_position(Vector3(-30, 33, 21), Vector3.ZERO, Vector3.UP)
	RenderingServer.global_shader_parameter_set("world_noise", WorldTextures.noise())
	apply_quality(GraphicsQuality.current())
	set_night(0.0)


## Applies a GraphicsQuality preset to the environment, the sun and the viewport.
func apply_quality(q: Dictionary) -> void:
	quality = q
	var fplus := GraphicsQuality.is_forward_plus()
	environment.ssao_enabled = fplus and bool(q["ssao"])
	environment.ssil_enabled = fplus and bool(q["ssil"])
	environment.volumetric_fog_enabled = fplus and bool(q["volumetric_fog"])
	environment.glow_enabled = bool(q["glow"])
	match int(q["shadow_splits"]):
		2:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		3, 4:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.light_angular_distance = float(q["shadow_softness"]) if fplus else 0.0
	sun.shadow_blur = float(q["shadow_blur"])
	GraphicsQuality.apply_shadow_atlas(q)
	if is_inside_tree():
		GraphicsQuality.apply_viewport(get_viewport(), q)
	_apply_dof_enabled()
	RenderingServer.global_shader_parameter_set("cloud_strength", _cloud_strength())


func _apply_dof_enabled() -> void:
	var on := dof_enabled and bool(quality.get("dof", false)) and GraphicsQuality.is_forward_plus()
	camera_attributes.dof_blur_far_enabled = on
	camera_attributes.dof_blur_near_enabled = on


func set_dof_enabled(on: bool) -> void:
	dof_enabled = on
	_apply_dof_enabled()


func _cloud_strength() -> float:
	if not bool(quality.get("clouds", true)):
		return 0.0
	return lerpf(float(DAY["cloud"]), float(NIGHT["cloud"]), night)


## 0 = day, 1 = night.
func set_night(n: float) -> void:
	night = clampf(n, 0.0, 1.0)
	var k := night
	sky_material.set_shader_parameter("zenith", _c("zenith", k))
	sky_material.set_shader_parameter("horizon", _c("horizon", k))
	sky_material.set_shader_parameter("ground_color", _c("ground", k))
	sky_material.set_shader_parameter("halo", _c("halo", k))
	sky_material.set_shader_parameter("stars", _f("stars", k))
	sky_material.set_shader_parameter("energy", _f("sky_energy", k))
	sky_material.set_shader_parameter("sun_disk", lerpf(2.0, 0.6, k))
	environment.ambient_light_color = _c("ambient_color", k)
	environment.ambient_light_energy = _f("ambient_energy", k)
	environment.fog_light_color = _c("fog_color", k)
	environment.volumetric_fog_albedo = _c("vol_albedo", k)
	environment.glow_intensity = _f("glow", k)
	environment.tonemap_exposure = _f("exposure", k)
	sun.light_color = _c("sun_color", k)
	sun.light_energy = _f("sun_energy", k)
	ArtMaterials.set_night(night)
	RenderingServer.global_shader_parameter_set("cloud_strength", _cloud_strength())


func _c(key: String, k: float) -> Color:
	return (DAY[key] as Color).lerp(NIGHT[key] as Color, k)


func _f(key: String, k: float) -> float:
	return lerpf(float(DAY[key]), float(NIGHT[key]), k)


## Eases toward `target` over `seconds`.
func fade_night(target: float, seconds: float = 1.6) -> void:
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(set_night, night, target, seconds).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _process(delta: float) -> void:
	_time += delta
	_cloud += WIND * delta
	RenderingServer.global_shader_parameter_set("wind_time", _time)
	RenderingServer.global_shader_parameter_set("cloud_offset", _cloud)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	_focus = focus_distance(cam)
	_update_shadow_range(_focus)
	_update_dof(_focus)


## Distance from the camera to the ground point at the centre of the view.
static func focus_distance(cam: Camera3D) -> float:
	var fwd := -cam.global_transform.basis.z
	if fwd.y > -0.05:
		return 60.0
	return cam.global_position.y / -fwd.y


## Shadows cover what the camera sees, no more: the visible ground spans roughly 0.7 to 1.6
## times the focus distance, so the splits are packed into that band.
func _update_shadow_range(d: float) -> void:
	sun.directional_shadow_max_distance = clampf(d * 2.1 + 8.0, 30.0, 220.0)
	sun.directional_shadow_split_1 = 0.36
	sun.directional_shadow_split_2 = 0.52
	sun.directional_shadow_split_3 = 0.72
	environment.fog_depth_begin = d * 1.5
	environment.fog_depth_end = d * 4.2 + 60.0


## Tilt-shift: sharp around the focus point, softening toward the top and bottom of the
## screen. Stronger when zoomed in (the diorama close-up), subtle when zoomed out.
func _update_dof(d: float) -> void:
	if not camera_attributes.dof_blur_far_enabled:
		return
	var zoom := clampf(inverse_lerp(10.0, 70.0, d), 0.0, 1.0)
	camera_attributes.dof_blur_far_distance = d * 1.18
	camera_attributes.dof_blur_far_transition = d * lerpf(0.55, 0.9, zoom)
	camera_attributes.dof_blur_near_distance = d * 0.74
	camera_attributes.dof_blur_near_transition = d * lerpf(0.22, 0.35, zoom)
	camera_attributes.dof_blur_amount = lerpf(0.11, 0.05, zoom)
