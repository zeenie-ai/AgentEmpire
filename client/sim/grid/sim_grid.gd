class_name SimGrid
extends RefCounted
## Square tile grid: terrain, occupancy and the AStarGrid2D used for pathfinding.
##
## Solid cells are rocks, live resource nodes and building footprints (except walkable fields).
## A PackedByteArray mirror of the solid flags keeps flood fills fast.

const TERRAIN_GRASS := 0
const TERRAIN_ROCK := 1

var size: int = 0
var astar: AStarGrid2D
## Building or resource node id per cell (0 = none). Used for placement and picking.
var occupant: PackedInt32Array = PackedInt32Array()
var terrain: PackedByteArray = PackedByteArray()
## 1 where the cell is solid; mirrors astar.
var solid: PackedByteArray = PackedByteArray()
## Increments on every solidity change; caches key on it.
var solid_version: int = 0


func _init(map_size: int) -> void:
	size = maxi(map_size, 1)
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, size, size)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	occupant.resize(size * size)
	terrain.resize(size * size)
	solid.resize(size * size)


func bounds() -> Rect2i:
	return Rect2i(0, 0, size, size)


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < size and c.y < size


func rect_in_bounds(r: Rect2i) -> bool:
	return r.position.x >= 0 and r.position.y >= 0 and r.end.x <= size and r.end.y <= size \
		and r.size.x > 0 and r.size.y > 0


func index(c: Vector2i) -> int:
	return c.y * size + c.x


func is_solid(c: Vector2i) -> bool:
	return not in_bounds(c) or solid[c.y * size + c.x] != 0


func is_walkable(c: Vector2i) -> bool:
	return in_bounds(c) and solid[c.y * size + c.x] == 0


func is_walkable_pos(p: Vector2) -> bool:
	return is_walkable(Vector2i(floori(p.x), floori(p.y)))


## Marks a rect solid or free, in both the A* grid and the byte mirror.
func set_solid(r: Rect2i, value: bool) -> void:
	var clipped := r.intersection(bounds())
	if not clipped.has_area():
		return
	astar.fill_solid_region(clipped, value)
	var v := 1 if value else 0
	for y in range(clipped.position.y, clipped.end.y):
		var row := y * size
		for x in range(clipped.position.x, clipped.end.x):
			solid[row + x] = v
	solid_version += 1


func occupant_at(c: Vector2i) -> int:
	if not in_bounds(c):
		return 0
	return occupant[c.y * size + c.x]


func set_occupant(r: Rect2i, id: int) -> void:
	var clipped := r.intersection(bounds())
	for y in range(clipped.position.y, clipped.end.y):
		for x in range(clipped.position.x, clipped.end.x):
			occupant[y * size + x] = id


## Clears cells of `r` that still belong to `id`.
func clear_occupant(r: Rect2i, id: int) -> void:
	var clipped := r.intersection(bounds())
	for y in range(clipped.position.y, clipped.end.y):
		for x in range(clipped.position.x, clipped.end.x):
			var i := y * size + x
			if occupant[i] == id:
				occupant[i] = 0


func terrain_at(c: Vector2i) -> int:
	if not in_bounds(c):
		return TERRAIN_ROCK
	return terrain[c.y * size + c.x]


func set_terrain(c: Vector2i, t: int) -> void:
	if in_bounds(c):
		terrain[c.y * size + c.x] = t
