class_name MapGenerator
extends RefCounted
## Seeded map generation: grass, forests and starter groves, berry-bush patches, a few
## decorative rocks and the 4x4 Keep at the centre. Stone and Gold are not gathered in
## Aurelhaven; they come from the agents' work. The same seed always produces the same map.

## No trees this close to the map centre (the Keep's clearing).
const TREE_CLEAR_RADIUS := 11.0
## Noise forests start this far out; starter groves sit between here and the clearing.
const FOREST_START := 15.0
const FOREST_THRESHOLD := 0.2
const FOREST_FREQUENCY := 0.045
## Forests thicken within this many tiles of the map edge.
const EDGE_BAND := 8
const EDGE_BOOST := 0.07
const STRAY_TREE_CHANCE := 0.006
const NEAR_GROVES := 3
const NEAR_BERRY_PATCHES := 2
const FAR_BERRY_PATCHES := 8
const ROCKS := 26
## Cells kept free around the Keep footprint.
const KEEP_MARGIN := 2


static func generate(w: SimWorld, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var size := w.grid.size
	var centre := w.map_center()
	var keep := w.place_keep()
	var keep_zone := keep.rect().grow(KEEP_MARGIN)

	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = FOREST_FREQUENCY
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3

	# Forests: noise blobs beyond FOREST_START, thickening toward the map edge, plus strays.
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(centre)
			if d < TREE_CLEAR_RADIUS:
				continue
			var v := noise.get_noise_2d(float(x), float(y))
			var edge := mini(mini(x, y), mini(size - 1 - x, size - 1 - y))
			if edge < EDGE_BAND:
				v += float(EDGE_BAND - edge) * EDGE_BOOST
			if (d >= FOREST_START and v > FOREST_THRESHOLD) or rng.randf() < STRAY_TREE_CHANCE:
				_place(w, rng, "tree", Vector2i(x, y), keep_zone, false)

	# Starter groves between the first two rings, so wood is a short walk from the Keep.
	var base_angle := rng.randf() * TAU
	for i in NEAR_GROVES:
		var a := base_angle + TAU * float(i) / float(NEAR_GROVES) + rng.randf_range(-0.35, 0.35)
		var r := rng.randf_range(13.0, 17.0)
		_blob(w, rng, centre + Vector2(cos(a), sin(a)) * r, rng.randf_range(2.3, 3.3), 0.85, "tree", keep_zone, false)

	# Berry patches: two near the Keep, between the groves, and more further out.
	for i in NEAR_BERRY_PATCHES:
		var a := base_angle + PI / float(NEAR_GROVES) + PI * float(i) + rng.randf_range(-0.3, 0.3)
		var r := rng.randf_range(7.5, 9.0)
		_blob(w, rng, centre + Vector2(cos(a), sin(a)) * r, 1.6, 0.9, "berry_bush", keep_zone, true)
	for i in FAR_BERRY_PATCHES:
		var a := rng.randf() * TAU
		var r := rng.randf_range(20.0, 52.0)
		_blob(w, rng, centre + Vector2(cos(a), sin(a)) * r, rng.randf_range(1.4, 1.9), 0.8, "berry_bush", keep_zone, true)

	# Decorative rocks: solid, not gatherable.
	var placed := 0
	var tries := 0
	while placed < ROCKS and tries < ROCKS * 30:
		tries += 1
		var c := Vector2i(rng.randi_range(2, size - 3), rng.randi_range(2, size - 3))
		if Vector2(c.x + 0.5, c.y + 0.5).distance_to(centre) < 13.0:
			continue
		if w.grid.occupant_at(c) != 0 or w.grid.terrain_at(c) != SimGrid.TERRAIN_GRASS:
			continue
		w.add_rock(c)
		placed += 1
		if rng.randf() < 0.35:
			var n := c + Vector2i(rng.randi_range(-1, 1), rng.randi_range(-1, 1))
			if w.grid.in_bounds(n) and w.grid.occupant_at(n) == 0:
				w.add_rock(n)


static func _blob(w: SimWorld, rng: RandomNumberGenerator, centre: Vector2, radius: float,
		density: float, kind: String, keep_zone: Rect2i, replace_trees: bool) -> void:
	for y in range(floori(centre.y - radius), floori(centre.y + radius) + 1):
		for x in range(floori(centre.x - radius), floori(centre.x + radius) + 1):
			if Vector2(x + 0.5, y + 0.5).distance_to(centre) > radius:
				continue
			if rng.randf() > density:
				continue
			_place(w, rng, kind, Vector2i(x, y), keep_zone, replace_trees)


static func _place(w: SimWorld, rng: RandomNumberGenerator, kind: String, c: Vector2i,
		keep_zone: Rect2i, replace_trees: bool) -> void:
	var variant := rng.randi() & 0xffff
	if not w.grid.in_bounds(c) or keep_zone.has_point(c):
		return
	if w.grid.terrain_at(c) != SimGrid.TERRAIN_GRASS:
		return
	var occ := w.grid.occupant_at(c)
	if occ != 0:
		var n: SimResourceNode = w.nodes.get(occ)
		if replace_trees and n != null and n.kind == "tree":
			w.remove_node(occ)
		else:
			return
	w.add_node(kind, c, variant)
