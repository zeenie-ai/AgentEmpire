class_name MapGenerator
extends RefCounted
## Seeded map generation: grass, forests and starter groves, berry-bush patches, a few
## decorative rocks and the 4x4 Keep at the centre. Stone and Gold are not gathered in
## Aurelhaven; they come from the agents' work. The same seed always produces the same map.
## Nothing grows on the town walls' line or their gate roads (SimWorld.walls), and the starter
## groves stand just outside the Keep Ring beside its gates, so wood stays a short walk away.

## No trees this close to the map centre (the Keep's clearing).
const TREE_CLEAR_RADIUS := 11.0
## Noise forests start this far out: just past the first age's build zone (the Merchant Ring,
## 22 tiles), so the meadow between the Keep Ring and it has room for the agents' 7 x 7 plots,
## cottages and farms. The starter groves sit in that meadow, beside the Keep Ring's gates.
const FOREST_START := 23.0
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

	# Forests: noise blobs beyond FOREST_START, thickening toward the map edge, plus strays, all
	# outside the first age's build zone (a lone tree there would block every plot over it).
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(centre)
			if d < TREE_CLEAR_RADIUS:
				continue
			var v := noise.get_noise_2d(float(x), float(y))
			var edge := mini(mini(x, y), mini(size - 1 - x, size - 1 - y))
			if edge < EDGE_BAND:
				v += float(EDGE_BAND - edge) * EDGE_BOOST
			var stray := rng.randf() < STRAY_TREE_CHANCE
			if d >= FOREST_START and (v > FOREST_THRESHOLD or stray):
				_place(w, rng, "tree", Vector2i(x, y), keep_zone, false)

	# Starter groves between the first two rings, so wood is a short walk from the Keep: beside
	# the Keep Ring's gates (but off their roads) when the town has walls.
	var base_angle := rng.randf() * TAU
	var gates := _grove_gates(w, rng)
	for i in NEAR_GROVES:
		var a := base_angle + TAU * float(i) / float(NEAR_GROVES) + rng.randf_range(-0.35, 0.35)
		var r := rng.randf_range(13.0, 17.0)
		if i < gates.size():
			a = gates[i] + (1.0 if rng.randf() < 0.5 else -1.0) * rng.randf_range(0.32, 0.5)
			r = rng.randf_range(14.0, 16.5)
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

	# Decorative rocks: solid, not gatherable; outside the first age's build zone, like the forests.
	var placed := 0
	var tries := 0
	while placed < ROCKS and tries < ROCKS * 30:
		tries += 1
		var c := Vector2i(rng.randi_range(2, size - 3), rng.randi_range(2, size - 3))
		if Vector2(c.x + 0.5, c.y + 0.5).distance_to(centre) < FOREST_START:
			continue
		if w.grid.occupant_at(c) != 0 or w.grid.terrain_at(c) != SimGrid.TERRAIN_GRASS or w.wall_ring_at(c) >= 0:
			continue
		w.add_rock(c)
		placed += 1
		if rng.randf() < 0.35:
			var n := c + Vector2i(rng.randi_range(-1, 1), rng.randi_range(-1, 1))
			if w.grid.in_bounds(n) and w.grid.occupant_at(n) == 0 and w.wall_ring_at(n) < 0:
				w.add_rock(n)


## Angles of the Keep Ring gates that get a starter grove (every gate but the south one, which
## faces the camera and keeps the meadow in front of the Keep open), shuffled by the seed.
static func _grove_gates(w: SimWorld, rng: RandomNumberGenerator) -> Array[float]:
	var out: Array[float] = []
	if w.walls == null or w.walls.ring_count() == 0:
		return out
	for a in w.walls.ring_gates[0]:
		if absf(wrapf(a - PI * 0.5, -PI, PI)) > 0.2:
			out.append(a)
	for i in range(out.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := out[i]
		out[i] = out[j]
		out[j] = t
	return out


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
	if not w.grid.in_bounds(c) or keep_zone.has_point(c) or w.wall_ring_at(c) >= 0:
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
