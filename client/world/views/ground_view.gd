class_name GroundView
extends Node3D
## The ground: one large plane with the stylised terrain shader (world/terrain/ground.gdshader)
## over the map and well beyond it, grass tufts and flowers (GrassField), and scenery past the
## map edge (Scenery). TerrainMask holds the forest floor, the Keep's paving and the worn dirt;
## new buildings wear the ground around them and walking townsfolk slowly wear footpaths.

const GROUND_SHADER := preload("res://world/terrain/ground.gdshader")
const GRASS_SHADER := preload("res://world/terrain/grass.gdshader")
## How far the ground plane reaches past the map on each side (fog hides its end).
const OUTER := 400.0
## Seconds between footstep stamps from walking units.
const STAMP_EVERY_S := 0.35

var mask: TerrainMask
var grass: GrassField
var scenery: Scenery
var ground_material: ShaderMaterial
var grass_material: ShaderMaterial

var _plane: MeshInstance3D
var _world: SimWorld
var _stamp_timer: float = 0.0


func build(w: SimWorld) -> void:
	for c in get_children():
		c.queue_free()
	_world = w
	mask = TerrainMask.new()
	mask.build(w)
	var size := float(w.grid.size)
	ground_material = ShaderMaterial.new()
	ground_material.shader = GROUND_SHADER
	grass_material = ShaderMaterial.new()
	grass_material.shader = GRASS_SHADER
	for m: ShaderMaterial in [ground_material, grass_material]:
		m.set_shader_parameter("static_mask", mask.static_texture)
		m.set_shader_parameter("wear_mask", mask.wear_texture)
		m.set_shader_parameter("mask_origin", mask.origin)
		m.set_shader_parameter("mask_size", mask.size_world())
	var pm := PlaneMesh.new()
	pm.size = Vector2(size + OUTER * 2.0, size + OUTER * 2.0)
	_plane = MeshInstance3D.new()
	_plane.name = "Terrain"
	_plane.mesh = pm
	_plane.material_override = ground_material
	_plane.position = Vector3(size * 0.5, 0.0, size * 0.5)
	_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_plane)
	grass = GrassField.new()
	grass.name = "Grass"
	add_child(grass)
	grass.build(w, mask, grass_material, float(GraphicsQuality.current().get("grass", 1.0)))
	scenery = Scenery.new()
	scenery.name = "Scenery"
	add_child(scenery)
	scenery.build(w)


func apply_quality(q: Dictionary) -> void:
	if grass != null:
		grass.set_density(float(q.get("grass", 1.0)))


## A new building or site: wear the ground around it now.
func building_added(b: SimBuilding) -> void:
	if mask == null:
		return
	mask.paint_building(b)
	mask.flush()


func _process(delta: float) -> void:
	if mask == null or _world == null or Game.world != _world:
		return
	_stamp_timer -= delta
	if _stamp_timer <= 0.0:
		_stamp_timer = STAMP_EVERY_S
		for u: SimUnit in _world.units.values():
			if u.prev_pos.distance_squared_to(u.pos) > 0.000001:
				mask.stamp(u.pos)
	mask.update(delta)
