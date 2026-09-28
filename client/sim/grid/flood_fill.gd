class_name FloodFill
extends RefCounted
## 4-connected flood fill over walkable cells. AStarGrid2D only moves diagonally past two free
## orthogonal neighbours, so 4-connectivity is exactly what units can reach.


## Returns a byte per cell: 1 where reachable from any of `seeds`. Cells in `blocked` are
## treated as solid (used to test a building before placing it).
static func region(grid: SimGrid, seeds: Array[Vector2i], blocked: Rect2i = Rect2i()) -> PackedByteArray:
	var n := grid.size
	var mark := PackedByteArray()
	mark.resize(n * n)
	var solid := grid.solid
	# Pre-mark the blocked rect so the fill never enters it (value 2 = blocked).
	var b := blocked.intersection(grid.bounds())
	for y in range(b.position.y, b.end.y):
		for x in range(b.position.x, b.end.x):
			mark[y * n + x] = 2
	var queue := PackedInt32Array()
	for s in seeds:
		if grid.in_bounds(s):
			var i := s.y * n + s.x
			if mark[i] == 0 and solid[i] == 0:
				mark[i] = 1
				queue.append(i)
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		var x := i % n
		if x > 0:
			var j := i - 1
			if mark[j] == 0 and solid[j] == 0:
				mark[j] = 1
				queue.append(j)
		if x < n - 1:
			var j := i + 1
			if mark[j] == 0 and solid[j] == 0:
				mark[j] = 1
				queue.append(j)
		if i >= n:
			var j := i - n
			if mark[j] == 0 and solid[j] == 0:
				mark[j] = 1
				queue.append(j)
		if i < n * (n - 1):
			var j := i + n
			if mark[j] == 0 and solid[j] == 0:
				mark[j] = 1
				queue.append(j)
	# Blocked cells are not reachable.
	for y in range(b.position.y, b.end.y):
		for x in range(b.position.x, b.end.x):
			mark[y * n + x] = 0
	return mark


static func count(mark: PackedByteArray) -> int:
	var c := 0
	for v in mark:
		if v == 1:
			c += 1
	return c


## True when some cell of the ring around `r` (or of `r` itself when `include_inside`) is marked.
static func touches(grid: SimGrid, mark: PackedByteArray, r: Rect2i, include_inside: bool) -> bool:
	for c in Pathing.ring_cells(r):
		if grid.in_bounds(c) and mark[grid.index(c)] == 1:
			return true
	if include_inside:
		var clipped := r.intersection(grid.bounds())
		for y in range(clipped.position.y, clipped.end.y):
			for x in range(clipped.position.x, clipped.end.x):
				if mark[y * grid.size + x] == 1:
					return true
	return false
