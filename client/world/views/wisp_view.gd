class_name WispView
extends Node3D
## A Font Wisp: the Summoning Font's spirit courier, carrying a task scroll nobody else could.
## A small bright orb with a halo, its own light and a trail of sparks. While it waits for its
## delay it circles above the Keep; then it flies straight to the agent's home.

const FLY_HEIGHT := 2.3
const WAIT_HEIGHT := 3.6
const WAIT_RADIUS := 1.3
const COLOR := Color(0.7, 0.95, 1.0)

var wisp_id: int = 0

var _halo: MeshInstance3D
var _light: OmniLight3D
var _phase: float = 0.0


func setup(id: int) -> void:
	wisp_id = id
	_phase = float(id % 13) * 0.5
	var core := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.2
	sphere.height = 0.4
	core.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.92, 1.0, 1.0)
	mat.emission_enabled = true
	mat.emission = COLOR
	mat.emission_energy_multiplier = 3.0
	core.material_override = mat
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(core)
	_halo = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	_halo.mesh = quad
	var halo_mat := Fx.sprite_material(WorldTextures.soft_dot(), true).duplicate() as StandardMaterial3D
	halo_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	halo_mat.albedo_color = Color(COLOR, 0.85)
	_halo.material_override = halo_mat
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_halo)
	_light = OmniLight3D.new()
	_light.light_color = COLOR
	_light.omni_range = 4.0
	_light.light_energy = 2.4
	_light.shadow_enabled = false
	add_child(_light)
	var trail := Fx.wisp_trail()
	add_child(trail)
	(trail as Node).set("emitting", true)


func update_visual(wisp: Dictionary, alpha: float, time: float) -> void:
	var prev: Vector2 = wisp.get("prev", wisp["pos"])
	var pos: Vector2 = wisp["pos"]
	var p := prev.lerp(pos, alpha)
	var t := time * 1.6 + _phase
	if int(wisp.get("delay", 0)) > 0:
		position = Vector3(p.x + cos(t) * WAIT_RADIUS, WAIT_HEIGHT + sin(t * 1.7) * 0.2, p.y + sin(t) * WAIT_RADIUS)
	else:
		position = Vector3(p.x, FLY_HEIGHT + sin(t * 2.4) * 0.12, p.y)
	var pulse := 1.0 + 0.12 * sin(time * 7.0 + _phase)
	_halo.scale = Vector3.ONE * pulse
	_light.light_energy = 2.2 + 0.6 * sin(time * 7.0 + _phase)
