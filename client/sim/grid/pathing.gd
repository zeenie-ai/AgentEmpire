class_name Pathing
extends RefCounted
## Path queries over SimGrid's AStarGrid2D (diagonals only past free corners, octile heuristic).
##
## A* runs with allow_partial_path, and a path that stops short of its goal means "can't reach".
## When the goal is solid (a tree, a building), the path goes to a free cell on its edge.

const NO_CELL := Vector2i(-1, -1)


static func cell_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x), floori(p.y))


static func center_of(c: Vector2i) -> Vector2:
	return Vector2(c.x + 0.5, c.y + 0.5)


## Euclidean distance from a point to a rect of cells (0 when inside).
static func rect_distance(p: Vector2, r: Rect2i) -> float:
	var dx := maxf(maxf(float(r.position.x) - p.x, 0.0), p.x - float(r.end.x))
	var dy := maxf(maxf(float(r.position.y) - p.y, 0.0), p.y - float(r.end.y))
	return sqrt(dx * dx + dy * dy)


## The ring of cells around `r`, clockwise from the top-left corner. Consecutive cells are
## 4-adjacent, so a run of free ring cells is connected.
static func ring_cells(r: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var x0 := r.position.x - 1
	var y0 := r.position.y - 1
	var x1 := r.end.x
	var y1 := r.end.y
	for x in range(x0, x1 + 1):
		out.append(Vector2i(x, y0))
	for y in range(y0 + 1, y1 + 1):
		out.append(Vector2i(x1, y))
	for x in range(x1 - 1, x0 - 1, -1):
		out.append(Vector2i(x, y1))
	for y in range(y1 - 1, y0, -1):
		out.append(Vector2i(x0, y))
	return out


static func free_edge_cells(grid: SimGrid, r: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in ring_cells(r):
		if grid.is_walkable(c):
			out.append(c)
	return out


## Number of separate runs of free cells around `r`. 0 or 1 means blocking `r` cannot split
## the walkable area (any path through `r` can go around it along the ring).
static func ring_segments(grid: SimGrid, r: Rect2i) -> int:
	var cells := ring_cells(r)
	var n := cells.size()
	var free: Array[bool] = []
	free.resize(n)
	var count := 0
	for i in n:
		free[i] = grid.is_walkable(cells[i])
		if free[i]:
			count += 1
	if count == 0:
		return 0
	if count == n:
		return 1
	var segs := 0
	for i in n:
		if free[i] and not free[(i - 1 + n) % n]:
			segs += 1
	return segs


## Closest walkable cell to `c` within Chebyshev distance `max_r` (c itself if walkable).
static func nearest_walkable(grid: SimGrid, c: Vector2i, max_r: int) -> Vector2i:
	if grid.is_walkable(c):
		return c
	for r in range(1, max_r + 1):
		var best := NO_CELL
		var best_d := INF
		for cell in ring_cells(Rect2i(c - Vector2i(r - 1, r - 1), Vector2i(2 * r - 1, 2 * r - 1))):
			if grid.is_walkable(cell):
				var d := Vector2(cell - c).length_squared()
				if d < best_d:
					best_d = d
					best = cell
		if best != NO_CELL:
			return best
	return NO_CELL


## Finds a path from `from` toward the goal. Returns {"path": Array[Vector2i], "reached": bool}.
## The path starts with `from`. `reached` is false when the goal cannot be reached; the path
## then ends at the closest reachable point (a partial path).
static func find_path(grid: SimGrid, from: Vector2i, mode: int, goal: Rect2i) -> Dictionary:
	if not grid.is_walkable(from):
		return _result([], false)
	match mode:
		SimConst.GOAL_CELL:
			var target := goal.position
			if grid.is_walkable(target):
				return _single(grid, from, target)
			return _to_edge(grid, from, Rect2i(target, Vector2i.ONE))
		SimConst.GOAL_INSIDE:
			if goal.has_point(from):
				return _result([from], true)
			var best := NO_CELL
			var best_d := INF
			for y in range(goal.position.y, goal.end.y):
				for x in range(goal.position.x, goal.end.x):
					var c := Vector2i(x, y)
					if grid.is_walkable(c):
						var d := Vector2(c - from).length_squared()
						if d < best_d:
							best_d = d
							best = c
			if best == NO_CELL:
				return _to_edge(grid, from, goal)
			return _single(grid, from, best)
		_:
			return _to_edge(grid, from, goal)


static func _single(grid: SimGrid, from: Vector2i, to: Vector2i) -> Dictionary:
	if from == to:
		return _result([from], true)
	var p: Array[Vector2i] = grid.astar.get_id_path(from, to, true)
	return _result(p, not p.is_empty() and p[p.size() - 1] == to)


static func _to_edge(grid: SimGrid, from: Vector2i, r: Rect2i) -> Dictionary:
	var candidates := free_edge_cells(grid, r)
	if candidates.is_empty():
		return _result([], false)
	if from in candidates:
		return _result([from], true)
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := Vector2(a - from).length_squared()
		var db := Vector2(b - from).length_squared()
		if da == db:
			return a.y < b.y or (a.y == b.y and a.x < b.x)
		return da < db)
	var best_path: Array[Vector2i] = []
	var best_d := INF
	for i in mini(candidates.size(), SimConst.MAX_EDGE_CANDIDATES):
		var res := _single(grid, from, candidates[i])
		if res["reached"]:
			return res
		var p: Array[Vector2i] = res["path"]
		if not p.is_empty():
			var d := rect_distance(center_of(p[p.size() - 1]), r)
			if d < best_d:
				best_d = d
				best_path = p
	return _result(best_path, false)


static func _result(path: Array[Vector2i], reached: bool) -> Dictionary:
	return {"path": path, "reached": reached}


## Up to `count` distinct walkable cells around `target`, nearest first (4-connected BFS from
## the target, or from the closest walkable cell when the target is solid). Group moves spread
## their units over these.
static func formation_cells(grid: SimGrid, target: Vector2i, count: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if count <= 0:
		return out
	var start := nearest_walkable(grid, target, 8)
	if start == NO_CELL:
		return out
	var seen := {start: true}
	var queue: Array[Vector2i] = [start]
	var head := 0
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]
	while head < queue.size() and out.size() < count and head < SimConst.FORMATION_SEARCH_CELLS:
		var c := queue[head]
		head += 1
		out.append(c)
		for d in dirs:
			var n := c + d
			if not seen.has(n) and grid.is_walkable(n):
				seen[n] = true
				queue.append(n)
	return out
