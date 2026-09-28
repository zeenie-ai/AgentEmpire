class_name SpatialHash
extends RefCounted
## Uniform bucket grid for unit neighbour queries (steering, picking). Rebuilt every tick.

var cell_size: float = 2.0
var _buckets: Dictionary = {}


func _init(cell: float = 2.0) -> void:
	cell_size = maxf(cell, 0.1)


func clear() -> void:
	_buckets.clear()


func insert(id: int, p: Vector2) -> void:
	var k := Vector2i(floori(p.x / cell_size), floori(p.y / cell_size))
	var arr: Variant = _buckets.get(k)
	if arr == null:
		_buckets[k] = [id]
	else:
		(arr as Array).append(id)


## Ids in buckets overlapping the circle; callers filter by exact distance.
func query(p: Vector2, radius: float) -> Array[int]:
	var out: Array[int] = []
	var x0 := floori((p.x - radius) / cell_size)
	var x1 := floori((p.x + radius) / cell_size)
	var y0 := floori((p.y - radius) / cell_size)
	var y1 := floori((p.y + radius) / cell_size)
	for ky in range(y0, y1 + 1):
		for kx in range(x0, x1 + 1):
			var arr: Variant = _buckets.get(Vector2i(kx, ky))
			if arr != null:
				for id: int in arr:
					out.append(id)
	return out
