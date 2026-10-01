class_name Fx
extends RefCounted
## Particle effects built in code: GPUParticles3D on Forward+, CPUParticles3D on the web's
## Compatibility renderer, from the same description. Sprites come from WorldTextures.
##
## particles(cfg) keys (all optional): amount, lifetime, one_shot, explosiveness, preprocess,
## direction (Vector3), spread (degrees), velocity (Vector2 min, max), gravity (Vector3),
## damping (Vector2), scale (Vector2 min, max), scale_curve (Curve), colors (Gradient),
## texture, box (Vector3 emission box half extents) or radius (emission sphere), local_coords,
## additive, size (quad size).

static var _materials: Dictionary = {}


## Quality multiplier for particle counts.
static func amount_scale() -> float:
	return float(GraphicsQuality.current().get("particles", 1.0))


static func particles(cfg: Dictionary) -> GeometryInstance3D:
	var node: GeometryInstance3D = _gpu(cfg) if GraphicsQuality.use_gpu_particles() else _cpu(cfg)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


static func sprite_material(tex: Texture2D, additive: bool) -> StandardMaterial3D:
	var key := "%d:%s" % [tex.get_instance_id(), additive]
	if _materials.has(key):
		return _materials[key]
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = tex
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_materials[key] = m
	return m


static func _quad(cfg: Dictionary) -> QuadMesh:
	var q := QuadMesh.new()
	var s: float = cfg.get("size", 1.0)
	q.size = Vector2(s, s)
	var tex: Texture2D = cfg.get("texture", WorldTextures.puff())
	q.material = sprite_material(tex, bool(cfg.get("additive", false)))
	return q


static func _count(cfg: Dictionary) -> int:
	return maxi(1, int(round(float(cfg.get("amount", 16)) * amount_scale())))


static func _gpu(cfg: Dictionary) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	var m := ParticleProcessMaterial.new()
	m.direction = cfg.get("direction", Vector3.UP)
	m.spread = float(cfg.get("spread", 20.0))
	var v: Vector2 = cfg.get("velocity", Vector2(0.5, 1.0))
	m.initial_velocity_min = v.x
	m.initial_velocity_max = v.y
	m.gravity = cfg.get("gravity", Vector3.ZERO)
	var d: Vector2 = cfg.get("damping", Vector2.ZERO)
	m.damping_min = d.x
	m.damping_max = d.y
	var s: Vector2 = cfg.get("scale", Vector2.ONE)
	m.scale_min = s.x
	m.scale_max = s.y
	if cfg.has("scale_curve"):
		var ct := CurveTexture.new()
		ct.curve = cfg["scale_curve"]
		m.scale_curve = ct
	if cfg.has("colors"):
		var gt := GradientTexture1D.new()
		gt.gradient = cfg["colors"]
		m.color_ramp = gt
	m.angle_min = 0.0
	m.angle_max = 360.0
	if cfg.has("box"):
		m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		m.emission_box_extents = cfg["box"]
	elif cfg.has("radius"):
		m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		m.emission_sphere_radius = float(cfg["radius"])
	p.process_material = m
	p.draw_pass_1 = _quad(cfg)
	p.amount = _count(cfg)
	p.lifetime = float(cfg.get("lifetime", 2.0))
	p.one_shot = bool(cfg.get("one_shot", false))
	p.explosiveness = float(cfg.get("explosiveness", 0.0))
	p.preprocess = float(cfg.get("preprocess", 0.0))
	p.local_coords = bool(cfg.get("local_coords", false))
	p.visibility_aabb = AABB(Vector3(-8, -2, -8), Vector3(16, 14, 16))
	return p


static func _cpu(cfg: Dictionary) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.mesh = _quad(cfg)
	p.direction = cfg.get("direction", Vector3.UP)
	p.spread = float(cfg.get("spread", 20.0))
	var v: Vector2 = cfg.get("velocity", Vector2(0.5, 1.0))
	p.initial_velocity_min = v.x
	p.initial_velocity_max = v.y
	p.gravity = cfg.get("gravity", Vector3.ZERO)
	var d: Vector2 = cfg.get("damping", Vector2.ZERO)
	p.damping_min = d.x
	p.damping_max = d.y
	var s: Vector2 = cfg.get("scale", Vector2.ONE)
	p.scale_amount_min = s.x
	p.scale_amount_max = s.y
	if cfg.has("scale_curve"):
		p.scale_amount_curve = cfg["scale_curve"]
	if cfg.has("colors"):
		p.color_ramp = cfg["colors"]
	p.angle_min = 0.0
	p.angle_max = 360.0
	if cfg.has("box"):
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		p.emission_box_extents = cfg["box"]
	elif cfg.has("radius"):
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		p.emission_sphere_radius = float(cfg["radius"])
	p.amount = _count(cfg)
	p.lifetime = float(cfg.get("lifetime", 2.0))
	p.one_shot = bool(cfg.get("one_shot", false))
	p.explosiveness = float(cfg.get("explosiveness", 0.0))
	p.preprocess = float(cfg.get("preprocess", 0.0))
	p.local_coords = bool(cfg.get("local_coords", false))
	return p


static func _curve(points: Array) -> Curve:
	var c := Curve.new()
	c.max_value = 3.0
	for pt: Vector2 in points:
		c.add_point(pt)
	return c


static func _gradient(stops: Array) -> Gradient:
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	for s: Array in stops:
		offs.append(float(s[0]))
		cols.append(s[1])
	g.offsets = offs
	g.colors = cols
	return g


## A one-shot burst of dust around a footprint of `size` tiles (construction finished).
static func dust_burst(size: Vector2) -> GeometryInstance3D:
	var col := Color(0.87, 0.79, 0.66)
	var p := particles({
		"amount": 18 + int(size.x * size.y * 2.0), "lifetime": 1.5, "one_shot": true, "explosiveness": 0.92,
		"direction": Vector3.UP, "spread": 75.0, "velocity": Vector2(0.6, 1.8), "gravity": Vector3(0, -0.5, 0),
		"damping": Vector2(1.6, 2.4), "scale": Vector2(0.55, 1.15), "size": 0.9,
		"scale_curve": _curve([Vector2(0, 0.35), Vector2(0.4, 1.0), Vector2(1, 1.35)]),
		"colors": _gradient([[0.0, Color(col, 0.0)], [0.08, Color(col, 0.8)], [0.6, Color(col, 0.45)], [1.0, Color(col, 0.0)]]),
		"box": Vector3(size.x * 0.5, 0.15, size.y * 0.5),
	})
	return p


## The dust a wall piece kicks up as it rises out of the ground: a low, rolling cloud along its
## foot (`length` along local x, `depth` across), slower and heavier than a building's burst.
static func wall_dust(length: float, depth: float) -> GeometryInstance3D:
	var col := Color(0.84, 0.77, 0.66)
	return particles({
		"amount": 22 + int(length * 7.0), "lifetime": 2.6, "one_shot": true, "explosiveness": 0.8,
		"direction": Vector3.UP, "spread": 85.0, "velocity": Vector2(0.5, 1.6), "gravity": Vector3(0, -0.22, 0),
		"damping": Vector2(0.9, 1.6), "scale": Vector2(0.8, 1.7), "size": 1.25,
		"scale_curve": _curve([Vector2(0, 0.3), Vector2(0.35, 1.0), Vector2(1, 1.6)]),
		"colors": _gradient([[0.0, Color(col, 0.0)], [0.07, Color(col, 0.75)], [0.55, Color(col, 0.42)], [1.0, Color(col, 0.0)]]),
		"box": Vector3(length * 0.5, 0.1, depth * 0.5 + 0.3),
	})


## Continuous chimney smoke that drifts with the wind.
static func chimney_smoke() -> GeometryInstance3D:
	var col := Color(0.94, 0.92, 0.89)
	return particles({
		"amount": 9, "lifetime": 4.6, "preprocess": 4.0, "direction": Vector3(0.15, 1.0, 0.05), "spread": 10.0,
		"velocity": Vector2(0.28, 0.42), "gravity": Vector3(0.1, 0.05, 0.04), "damping": Vector2(0.05, 0.1),
		"scale": Vector2(0.7, 1.0), "size": 0.55, "radius": 0.05,
		"scale_curve": _curve([Vector2(0, 0.3), Vector2(0.5, 0.95), Vector2(1, 1.6)]),
		"colors": _gradient([[0.0, Color(col, 0.0)], [0.12, Color(col, 0.55)], [0.6, Color(col, 0.3)], [1.0, Color(col, 0.0)]]),
	})


## Dark, heavy smoke over a home whose agent's task failed (an incident, not a fire).
static func trouble_smoke() -> GeometryInstance3D:
	var col := Color(0.32, 0.3, 0.29)
	return particles({
		"amount": 16, "lifetime": 3.8, "preprocess": 3.0, "direction": Vector3(0.1, 1.0, 0.05), "spread": 14.0,
		"velocity": Vector2(0.45, 0.7), "gravity": Vector3(0.12, 0.08, 0.04), "damping": Vector2(0.05, 0.12),
		"scale": Vector2(0.8, 1.2), "size": 0.75, "radius": 0.18,
		"scale_curve": _curve([Vector2(0, 0.4), Vector2(0.5, 1.1), Vector2(1, 1.9)]),
		"colors": _gradient([[0.0, Color(col, 0.0)], [0.1, Color(col, 0.7)], [0.6, Color(col, 0.4)], [1.0, Color(col, 0.0)]]),
	})


## A Font Wisp's trail: small cool sparks left behind as it flies.
static func wisp_trail() -> GeometryInstance3D:
	var col := Color(0.62, 0.92, 1.0)
	return particles({
		"amount": 40, "lifetime": 0.9, "direction": Vector3.UP, "spread": 180.0, "velocity": Vector2(0.02, 0.12),
		"gravity": Vector3(0, 0.1, 0), "scale": Vector2(0.4, 0.9), "size": 0.16, "radius": 0.08,
		"texture": WorldTextures.soft_dot(), "additive": true, "local_coords": false,
		"scale_curve": _curve([Vector2(0, 1.0), Vector2(1, 0.0)]),
		"colors": _gradient([[0.0, Color(col, 0.9)], [1.0, Color(col, 0.0)]]),
	})


## Soft motes of pollen drifting in the light (additive; gold by day, cool at night).
static func motes(extent: Vector3) -> GeometryInstance3D:
	var col := Color(1.0, 0.86, 0.55)
	return particles({
		"amount": 90, "lifetime": 9.0, "preprocess": 9.0, "direction": Vector3(0.3, 0.2, 0.1), "spread": 180.0,
		"velocity": Vector2(0.05, 0.25), "gravity": Vector3(0.06, 0.03, 0.02), "scale": Vector2(0.5, 1.0),
		"size": 0.1, "texture": WorldTextures.soft_dot(), "additive": true, "box": extent,
		"scale_curve": _curve([Vector2(0, 0.0), Vector2(0.2, 1.0), Vector2(0.8, 1.0), Vector2(1, 0.0)]),
		"colors": _gradient([[0.0, Color(col, 0.0)], [0.25, Color(col, 0.6)], [0.75, Color(col, 0.6)], [1.0, Color(col, 0.0)]]),
	})


## Frees a one-shot effect after it has played.
static func free_after(node: Node, seconds: float) -> void:
	var tree := node.get_tree()
	if tree == null:
		return
	tree.create_timer(seconds).timeout.connect(func() -> void:
		if is_instance_valid(node):
			node.queue_free())
