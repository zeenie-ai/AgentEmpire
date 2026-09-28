class_name GroundView
extends Node3D
## The ground: a map-sized plane textured from the simulation grid (grass with gentle
## variation, darker forest floor, a paved plaza around the Keep) and an outer plane that runs
## into the fog beyond the map edge.

const TEX_SCALE := 4
const PLAZA_RADIUS := 5.0

var _plane: MeshInstance3D
var _outer: MeshInstance3D


func build(w: SimWorld) -> void:
	for c in get_children():
		c.queue_free()
	var size := w.grid.size
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _texture(w)
	mat.roughness = 1.0
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var pm := PlaneMesh.new()
	pm.size = Vector2(size, size)
	_plane = MeshInstance3D.new()
	_plane.mesh = pm
	_plane.material_override = mat
	_plane.position = Vector3(size * 0.5, 0.0, size * 0.5)
	_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_plane)

	var outer_mat := StandardMaterial3D.new()
	outer_mat.albedo_color = Palette.FOREST_FLOOR.darkened(0.08)
	outer_mat.roughness = 1.0
	var om := PlaneMesh.new()
	om.size = Vector2(size * 12, size * 12)
	_outer = MeshInstance3D.new()
	_outer.mesh = om
	_outer.material_override = outer_mat
	_outer.position = Vector3(size * 0.5, -0.03, size * 0.5)
	_outer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_outer)


## One colour per tile, blurred up by bilinear resizing.
func _texture(w: SimWorld) -> ImageTexture:
	var size := w.grid.size
	var density := PackedFloat32Array()
	density.resize(size * size)
	for n: SimResourceNode in w.nodes.values():
		if n.kind != "tree":
			continue
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var c := n.cell + Vector2i(dx, dy)
				if w.grid.in_bounds(c):
					density[c.y * size + c.x] += 0.09 if (dx == 0 and dy == 0) else 0.045
	var noise := FastNoiseLite.new()
	noise.seed = w.map_seed + 17
	noise.frequency = 0.06
	noise.fractal_octaves = 2
	var centre := w.map_center()
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var col := Palette.GRASS
			var v := noise.get_noise_2d(float(x), float(y))
			col = col.lightened(v * 0.1) if v > 0.0 else col.darkened(-v * 0.12)
			col = col.lerp(Palette.FOREST_FLOOR, clampf(density[y * size + x], 0.0, 0.85))
			var d := Vector2(x + 0.5, y + 0.5).distance_to(centre)
			if d < PLAZA_RADIUS + 1.5:
				var t := clampf((PLAZA_RADIUS + 1.5 - d) / 1.5, 0.0, 1.0)
				col = col.lerp(Palette.PLAZA, t * 0.9)
			if w.grid.terrain_at(Vector2i(x, y)) == SimGrid.TERRAIN_ROCK:
				col = col.darkened(0.12)
			img.set_pixel(x, y, col)
	img.resize(size * TEX_SCALE, size * TEX_SCALE, Image.INTERPOLATE_BILINEAR)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
