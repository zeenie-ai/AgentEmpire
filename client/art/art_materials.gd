class_name ArtMaterials
extends RefCounted
## Shared materials for the procedural art. night_amount drives the window glow (houses light
## up at night, as in the handoff's city-scene.js: emissive #ffb14a ramping 0 -> 1.1).

static var _base: StandardMaterial3D
static var _glow: StandardMaterial3D
static var _gold: StandardMaterial3D
static var _ring: StandardMaterial3D
static var _line: StandardMaterial3D
static var _ghost_ok: StandardMaterial3D
static var _ghost_bad: StandardMaterial3D
static var _bar_bg: StandardMaterial3D
static var _bar_fill: StandardMaterial3D
static var _night: float = 0.0


## Vertex-coloured, rough, lit. Used by nearly every mesh.
static func base() -> StandardMaterial3D:
	if _base == null:
		_base = StandardMaterial3D.new()
		_base.vertex_color_use_as_albedo = true
		_base.vertex_color_is_srgb = true
		_base.roughness = 0.92
		_base.metallic = 0.0
	return _base


## Windows: dark glass by day, warm glow at night.
static func glow() -> StandardMaterial3D:
	if _glow == null:
		_glow = StandardMaterial3D.new()
		_glow.albedo_color = Color("#4a3a2c")
		_glow.roughness = 0.4
		_glow.emission_enabled = true
		_glow.emission = Palette.WINDOW_GLOW
		_glow.emission_energy_multiplier = 0.0
	return _glow


## The golden Summoning Font ring above the Keep.
static func gold() -> StandardMaterial3D:
	if _gold == null:
		_gold = StandardMaterial3D.new()
		_gold.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_gold.albedo_color = Palette.GOLD_BRIGHT
	return _gold


## Unshaded, vertex/instance coloured (selection rings).
static func ring() -> StandardMaterial3D:
	if _ring == null:
		_ring = StandardMaterial3D.new()
		_ring.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ring.vertex_color_use_as_albedo = true
		_ring.vertex_color_is_srgb = true
		_ring.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ring.no_depth_test = false
		_ring.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _ring


## Faint line on the ground marking the build zone.
static func survey_line() -> StandardMaterial3D:
	if _line == null:
		_line = StandardMaterial3D.new()
		_line.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_line.albedo_color = Color(Palette.GOLD_BRIGHT, 0.75)
		_line.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_line.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _line


## Translucent placement ghost, green when the spot is valid and red when not.
static func ghost(ok: bool) -> StandardMaterial3D:
	if _ghost_ok == null:
		_ghost_ok = _make_ghost(Color(0.55, 0.95, 0.7, 0.45))
		_ghost_bad = _make_ghost(Color(1.0, 0.35, 0.3, 0.45))
	return _ghost_ok if ok else _ghost_bad


static func _make_ghost(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## World-space progress bars (always face the camera, drawn on top).
static func bar(fill: bool) -> StandardMaterial3D:
	if _bar_bg == null:
		_bar_bg = _make_bar(Color(0.106, 0.078, 0.055, 0.85))
		_bar_fill = _make_bar(Palette.GOLD)
	return _bar_fill if fill else _bar_bg


static func _make_bar(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	m.no_depth_test = true
	m.render_priority = 2
	return m


static func night_amount() -> float:
	return _night


## 0 = dawn, 1 = night. Windows glow as night falls.
static func set_night(n: float) -> void:
	_night = clampf(n, 0.0, 1.0)
	glow().emission_energy_multiplier = _night * 2.2
	glow().albedo_color = Color("#4a3a2c").lerp(Color("#2a2030"), _night)
