class_name KitMaterials
extends RefCounted
## Gives imported models (GLB from art_src, KayKit atlas textures) the town's own shading: the
## kit shader (art/shaders/kit.gdshader) keeps each material's texture, colour and vertex
## colours, and adds wrapped diffuse, drifting cloud shadows, a little saturation, optional rim
## light and night-time window glow. Converted materials are cached per source material and
## profile, so every instance of a model shares them.
##
## A profile is a Dictionary of kit shader parameters, e.g. {"rim": 0.2} for characters or
## {"glow_cell_a": Vector4(...)} for a building's windows.

const SHADER := preload("res://art/shaders/kit.gdshader")
const SHADER_DOUBLE := preload("res://art/shaders/kit_double.gdshader")

static var _cache: Dictionary = {}


## Converts every surface of every MeshInstance3D under `root` (as surface override materials).
static func apply(root: Node, profile: Dictionary = {}) -> void:
	var list: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		list.append(root)
	for n in list:
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s)
			var has_colors := KitMaterials.mesh_has_colors(mi.mesh, s)
			var conv := converted(src, profile, has_colors)
			if conv != null:
				mi.set_surface_override_material(s, conv)


## The kit version of `src`, or null when it should stay as it is (transparent, custom shader).
## `mesh_has_colors`: whether the mesh carries a vertex colour array.
static func converted(src: Material, profile: Dictionary = {}, mesh_has_colors: bool = false) -> Material:
	if src is ShaderMaterial:
		var sh := (src as ShaderMaterial).shader
		return src if sh == SHADER or sh == SHADER_DOUBLE else null
	var key := "%d|%s|%s" % [src.get_instance_id() if src != null else 0, str(profile), mesh_has_colors]
	if _cache.has(key):
		return (_cache[key] as Array)[1]
	var sm := ShaderMaterial.new()
	sm.shader = SHADER
	if src == null:
		sm.set_shader_parameter("use_vertex_color", mesh_has_colors)
	elif src is BaseMaterial3D:
		var b := src as BaseMaterial3D
		if b.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA or b.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
			return null
		if b.cull_mode == BaseMaterial3D.CULL_DISABLED:
			sm.shader = SHADER_DOUBLE
		sm.set_shader_parameter("albedo", b.albedo_color)
		if b.albedo_texture != null:
			sm.set_shader_parameter("albedo_tex", b.albedo_texture)
		# Without a colour array COLOR is white times any MultiMesh instance colour, so tints work.
		sm.set_shader_parameter("use_vertex_color", b.vertex_color_use_as_albedo or not mesh_has_colors)
		sm.set_shader_parameter("vertex_color_srgb", b.vertex_color_use_as_albedo and b.vertex_color_is_srgb)
		sm.set_shader_parameter("roughness", clampf(b.roughness, 0.6, 1.0))
	else:
		return null
	for k: String in profile:
		sm.set_shader_parameter(k, profile[k])
	sm.resource_name = "Kit"
	_cache[key] = [src, sm]
	return sm


## True when surface `s` of `mesh` carries a vertex colour array.
static func mesh_has_colors(mesh: Mesh, s: int) -> bool:
	var am := mesh as ArrayMesh
	if am != null:
		return (am.surface_get_format(s) & Mesh.ARRAY_FORMAT_COLOR) != 0
	return mesh.surface_get_arrays(s)[Mesh.ARRAY_COLOR] != null


## A kit material for procedural vertex-coloured meshes (the fallback art).
static func vertex_colored(profile: Dictionary = {}) -> ShaderMaterial:
	var key := "vc|%s" % str(profile)
	if _cache.has(key):
		return (_cache[key] as Array)[1]
	var sm := ShaderMaterial.new()
	sm.shader = SHADER
	sm.set_shader_parameter("use_vertex_color", true)
	sm.set_shader_parameter("vertex_color_srgb", true)
	sm.set_shader_parameter("roughness", 0.92)
	for k: String in profile:
		sm.set_shader_parameter(k, profile[k])
	_cache[key] = [null, sm]
	return sm


static func clear_cache() -> void:
	_cache.clear()
