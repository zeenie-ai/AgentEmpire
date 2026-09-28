class_name SkyEnvironment
extends Node3D
## Dawn sky, fog and sun after the handoff's city-scene.js: background and fog #f2b98c, a warm
## sun #ffc78f from the south-west, hemisphere-like ambient #ffe9cf. set_night() lerps toward
## the night navy #0d1230 and a cool moonlight, and makes the windows glow.

const FOG_BEGIN := 80.0
const FOG_END := 260.0
## Tuned so sunlit ground shows close to its palette colour (linear tonemap): the sun meets the
## ground at ~40 degrees (N.L ~0.64), so 0.95 x 0.64 + 0.42 ambient ~ 1.0.
const SUN_ENERGY_DAY := 0.95
const SUN_ENERGY_NIGHT := 0.22
const AMBIENT_DAY := 0.42
const AMBIENT_NIGHT := 0.16
## Sun and ambient tints: the handoff's warm dawn light, softened so the grass stays green.
const SUN_TINT := Color("#ffe2c4")
const AMBIENT_TINT := Color("#e8ecf4")

var environment: Environment
var world_environment: WorldEnvironment
var sun: DirectionalLight3D
var sky_material: ProceduralSkyMaterial
var night: float = 0.0

var _tween: Tween


func _ready() -> void:
	sky_material = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_material
	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_depth_begin = FOG_BEGIN
	environment.fog_depth_end = FOG_END
	environment.fog_depth_curve = 1.4
	environment.fog_sky_affect = 0.35
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world_environment = WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 110.0
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 1.2
	add_child(sun)
	# city-scene.js puts the sun at (-30, 26, 18); raised a little for shorter shadows.
	sun.look_at_from_position(Vector3(-30, 30, 18), Vector3.ZERO, Vector3.UP)
	set_night(0.0)


## 0 = dawn, 1 = night.
func set_night(n: float) -> void:
	night = clampf(n, 0.0, 1.0)
	var bg := Palette.DAWN.lerp(Palette.NIGHT, night)
	sky_material.sky_top_color = Color("#d99a86").lerp(Color("#070a1e"), night)
	sky_material.sky_horizon_color = bg
	sky_material.ground_horizon_color = bg
	sky_material.ground_bottom_color = Palette.GRASS.darkened(0.3).lerp(Palette.NIGHT, night)
	sky_material.sun_angle_max = 30.0
	environment.fog_light_color = bg
	environment.ambient_light_color = AMBIENT_TINT.lerp(Color("#3a4a8a"), night)
	environment.ambient_light_energy = lerpf(AMBIENT_DAY, AMBIENT_NIGHT, night)
	sun.light_color = SUN_TINT.lerp(Palette.SUN_NIGHT, night)
	sun.light_energy = lerpf(SUN_ENERGY_DAY, SUN_ENERGY_NIGHT, night)
	ArtMaterials.set_night(night)


## Eases toward `target` over `seconds`.
func fade_night(target: float, seconds: float = 1.6) -> void:
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(set_night, night, target, seconds).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
