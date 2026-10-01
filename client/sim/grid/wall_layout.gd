class_name WallLayout
extends RefCounted
## Where the four town walls stand (economy.json map.ring_radii and map.gates_per_ring: the Keep
## Ring, the Merchant Ring, the Guild Ring and the Great Curtain) and which map cells each part
## covers. Pure geometry, identical for every town of a given map size and economy, cached per
## key. SimWorld uses it for pathing and placement; the views draw the walls from it.
##
## Each ring is a polygon of straight curtain walls between towers, the way town walls were
## built:
## - its gates are spread evenly around it, the first facing south (+y, toward the default
##   camera). A gate is a passage (GATE_HALF either side of its axis) between two gate towers,
##   and the road through it is kept clear GATE_APRON tiles in front of and behind the wall;
## - between two gatehouses, wall towers stand about TOWER_SPACING apart (by arc length), a
##   little outside the wall line (TOWER_OUT), as flanking towers do;
## - curtains run straight from post to post (the tower positions on the ring's circle) and are
##   split into pieces about PIECE_LENGTH long, so a gap in the wall stays small.
##
## Cells, claimed in this order (a cell belongs to one part only):
## 1. gate passages and their roads: reserved and always walkable;
## 2. gatehouses (the block from the passage to each gate tower, plus the tower) and towers;
## 3. curtains: every cell whose centre lies within half the curtain's thickness of it (never
##    less than MIN_HALF, so a curtain is at least 4-connected and nothing slips through it).
## Every claimed cell is reserved from the start, whether or not its ring stands yet, so no
## building can ever block a future wall. A ring stands from Age ring + 1 (SimWorld.walls_up).

const CURTAIN := 0
const TOWER := 1
const GATE_TOWER := 2
## The arch over a gate passage. Its cells (the passage and its road) never become solid.
const GATE := 3

## Per ring, in tiles: curtain thickness, tower radii, the target distance between towers and
## the length of one curtain piece. Later rings are grander.
const THICKNESS: Array[float] = [1.15, 1.25, 1.4, 1.55]
const TOWER_RADIUS: Array[float] = [0.9, 0.95, 1.0, 1.1]
const GATE_TOWER_RADIUS: Array[float] = [1.0, 1.1, 1.15, 1.3]
const TOWER_SPACING: Array[float] = [7.0, 8.0, 8.5, 9.0]
const PIECE_LENGTH: Array[float] = [2.9, 3.1, 3.4, 3.8]
## Half the walkable width of a gate (cell centres this close to the gate's axis stay open),
## the margin between the passage and a gate tower, and how far the road is kept clear in front
## of and behind the wall.
const GATE_HALF := 1.2
const GATE_CLEAR := 0.12
const GATE_APRON := 3.5
## Narrowest half-thickness of a curtain's band of cells.
const MIN_HALF := 0.72
## Towers stand this far outside the wall line.
const TOWER_OUT := 0.3
## Extra reach of a tower beyond its radius when claiming cells.
const TOWER_PAD := 0.1
## The first gate of every ring faces south (+y).
const FIRST_GATE_ANGLE := PI * 0.5


## One part of a wall.
class Piece:
	extends RefCounted
	var index: int = 0
	var kind: int = CURTAIN
	var ring: int = 0
	## Curtains and gates: the ends along the wall line. Towers: both are the tower's centre.
	var a: Vector2 = Vector2.ZERO
	var b: Vector2 = Vector2.ZERO
	var center: Vector2 = Vector2.ZERO
	## Unit vector pointing away from the town centre (the wall's field side).
	var outward: Vector2 = Vector2.DOWN
	## Towers: their radius. Curtains: half their thickness. Gates: half the passage width.
	var radius: float = 0.0
	## Curtains and gates: their length along the wall line.
	var length: float = 0.0
	## Angle of the piece's centre around the ring (radians, 0 = east, PI/2 = south), for
	## staggering the wall-rise.
	var angle: float = 0.0
	## Gate towers and gates: the gate they belong to (index around the ring), else -1.
	var gate: int = -1
	## Cell indices (y * size + x) this piece claims.
	var cells: Array[int] = []


var size: int = 0
var center: Vector2 = Vector2.ZERO
var radii: Array[float] = []
var gate_counts: Array[int] = []
var pieces: Array[Piece] = []
## Per ring: indices into `pieces` (each an Array[int]).
var ring_pieces: Array = []
## Per ring: the gate angles (radians), first gate first.
var ring_gates: Array[PackedFloat32Array] = []
## Per ring: the wall line between gates, one polyline per stretch (from one gate's tower to
## the next gate's tower, through the towers between them). For stakes, ropes and the minimap.
var ring_lines: Array = []
## cell index -> piece index + 1, 0 for none.
var cell_piece: PackedInt32Array = PackedInt32Array()
## cell index -> ring + 1 for every reserved cell (wall parts, gate passages and roads), 0 for
## none.
var cell_ring: PackedByteArray = PackedByteArray()
## cell index -> 1 for gate passages and their roads (reserved, never solid).
var cell_gate: PackedByteArray = PackedByteArray()

static var _cache: Dictionary = {}


## The walls of a `map_size` map with the economy's rings (cached; never modify the result).
static func for_economy(econ: EconomyData, map_size: int) -> WallLayout:
	var radii_f: Array[float] = []
	for r in econ.ring_radii():
		radii_f.append(float(r))
	var gates: Array[int] = []
	for g: Variant in econ.section("map").get("gates_per_ring", []):
		gates.append(int(g))
	return build(map_size, radii_f, gates)


static func build(map_size: int, ring_radii: Array[float], gates_per_ring: Array[int]) -> WallLayout:
	var key := "%d|%s|%s" % [map_size, str(ring_radii), str(gates_per_ring)]
	if _cache.has(key):
		return _cache[key]
	var l := WallLayout.new()
	l._build(map_size, ring_radii, gates_per_ring)
	_cache[key] = l
	return l


func ring_count() -> int:
	return radii.size()


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < size and c.y < size


## Ring of the wall reserving cell `c`, or -1.
func ring_at(c: Vector2i) -> int:
	if not in_bounds(c):
		return -1
	return int(cell_ring[c.y * size + c.x]) - 1


## Index of the wall piece claiming cell `c`, or -1 (gate roads belong to their gate piece).
func piece_at(c: Vector2i) -> int:
	if not in_bounds(c):
		return -1
	return cell_piece[c.y * size + c.x] - 1


## True for gate passages and the roads through them.
func is_gate_cell(c: Vector2i) -> bool:
	return in_bounds(c) and cell_gate[c.y * size + c.x] != 0


func cell_of(i: int) -> Vector2i:
	return Vector2i(i % size, i / size)


## Every piece of ring `k` of the given kind.
func pieces_of(k: int, kind: int) -> Array[Piece]:
	var out: Array[Piece] = []
	for i: int in ring_pieces[k]:
		if pieces[i].kind == kind:
			out.append(pieces[i])
	return out


## Point on ring `k`'s circle at `angle`, `out` tiles outside it.
func ring_point(k: int, angle: float, out: float = 0.0) -> Vector2:
	return center + Vector2(cos(angle), sin(angle)) * (radii[k] + out)


# --- building --------------------------------------------------------------------------------

func _build(map_size: int, ring_radii: Array[float], gates_per_ring: Array[int]) -> void:
	size = maxi(map_size, 1)
	center = Vector2(size, size) * 0.5
	radii = ring_radii.duplicate()
	gate_counts = []
	for k in radii.size():
		gate_counts.append(maxi(gates_per_ring[k] if k < gates_per_ring.size() else 4, 1))
	cell_piece.resize(size * size)
	cell_ring.resize(size * size)
	cell_gate.resize(size * size)
	for k in radii.size():
		_build_ring(k)


func _build_ring(k: int) -> void:
	var r := radii[k]
	var gates := gate_counts[k]
	var half := maxf(_param(THICKNESS, k) * 0.5, MIN_HALF)
	var rt := _param(TOWER_RADIUS, k)
	var rg := _param(GATE_TOWER_RADIUS, k)
	var list: Array[int] = []
	ring_pieces.append(list)
	var gate_angles := PackedFloat32Array()
	# Posts around the ring: [angle, kind, gate], in increasing angle from the first gate.
	var gate_off := (GATE_HALF + GATE_CLEAR + rg) / r
	var posts: Array = []
	for g in gates:
		var ga := FIRST_GATE_ANGLE + TAU * float(g) / float(gates)
		gate_angles.append(ga)
		posts.append([ga - gate_off, GATE_TOWER, g])
		posts.append([ga + gate_off, GATE_TOWER, g])
		var span := TAU / float(gates) - 2.0 * gate_off
		var runs := maxi(1, int(round(span * r / _param(TOWER_SPACING, k))))
		for i in range(1, runs):
			posts.append([ga + gate_off + span * float(i) / float(runs), TOWER, -1])
	ring_gates.append(gate_angles)
	# 1. Gate passages and their roads.
	var depth_in := maxf(half, rg - TOWER_OUT)
	var depth_out := maxf(half, rg + TOWER_OUT)
	for g in gates:
		var ga := gate_angles[g]
		var p := _new_piece(GATE, k, list)
		p.gate = g
		p.outward = Vector2(cos(ga), sin(ga))
		p.center = ring_point(k, ga)
		var t := _tangent(ga)
		p.a = p.center - t * GATE_HALF
		p.b = p.center + t * GATE_HALF
		p.radius = GATE_HALF
		p.length = GATE_HALF * 2.0
		p.angle = ga
		_claim_box(p, t, -GATE_HALF, GATE_HALF, -(depth_in + GATE_APRON), depth_out + GATE_APRON, true)
	# 2. Gatehouses and towers.
	for post: Array in posts:
		var angle: float = post[0]
		var kind: int = post[1]
		var p := _new_piece(kind, k, list)
		p.gate = int(post[2])
		p.angle = angle
		p.outward = Vector2(cos(angle), sin(angle))
		p.center = ring_point(k, angle, TOWER_OUT)
		p.a = p.center
		p.b = p.center
		p.radius = rg if kind == GATE_TOWER else rt
		if kind == GATE_TOWER:
			# The block between the passage and the tower's centre, so the gatehouse is solid.
			var ga := gate_angles[p.gate]
			var t := _tangent(ga)
			var gc := ring_point(k, ga)
			var along := (p.center - gc).dot(t)
			if along < 0.0:
				_claim_box_at(p, gc, t, along, -GATE_HALF, -depth_in, depth_out)
			else:
				_claim_box_at(p, gc, t, GATE_HALF, along, -depth_in, depth_out)
		_claim_disc(p, p.center, p.radius + TOWER_PAD)
	# 3. Curtains between consecutive posts (not across a gate).
	var lines: Array[PackedVector2Array] = []
	var line := PackedVector2Array()
	for i in posts.size():
		var p0: Array = posts[i]
		var p1: Array = posts[(i + 1) % posts.size()]
		var a0: float = p0[0]
		var a1: float = p1[0]
		if i == posts.size() - 1:
			a1 += TAU
		var from := ring_point(k, a0)
		var to := ring_point(k, a1)
		if int(p0[1]) == GATE_TOWER and int(p1[1]) == GATE_TOWER and int(p0[2]) == int(p1[2]):
			# A gate: the wall line breaks here.
			if line.size() > 0:
				lines.append(line)
			line = PackedVector2Array()
			continue
		if line.is_empty():
			line.append(from)
		line.append(to)
		_add_curtain(k, list, from, to, half)
	if line.size() > 0:
		lines.append(line)
	ring_lines.append(lines)


func _add_curtain(k: int, list: Array[int], from: Vector2, to: Vector2, half: float) -> void:
	var length := from.distance_to(to)
	var count := maxi(1, int(round(length / _param(PIECE_LENGTH, k))))
	var dir := (to - from) / maxf(length, 0.0001)
	var mid_out := ((from + to) * 0.5 - center).normalized()
	var made: Array[Piece] = []
	for j in count:
		var p := _new_piece(CURTAIN, k, list)
		p.a = from + dir * (length * float(j) / float(count))
		p.b = from + dir * (length * float(j + 1) / float(count))
		p.center = (p.a + p.b) * 0.5
		p.outward = mid_out
		p.radius = half
		p.length = length / float(count)
		var rel := p.center - center
		p.angle = atan2(rel.y, rel.x)
		made.append(p)
	# Cells: within `half` of the segment (round ends, which tuck into the towers).
	var lo := Vector2i(floori(minf(from.x, to.x) - half - 1.0), floori(minf(from.y, to.y) - half - 1.0))
	var hi := Vector2i(ceili(maxf(from.x, to.x) + half + 1.0), ceili(maxf(from.y, to.y) + half + 1.0))
	for y in range(maxi(lo.y, 0), mini(hi.y, size)):
		for x in range(maxi(lo.x, 0), mini(hi.x, size)):
			var i := y * size + x
			if cell_ring[i] != 0:
				continue
			var pc := Vector2(x + 0.5, y + 0.5)
			var t := clampf((pc - from).dot(dir), 0.0, length)
			if pc.distance_to(from + dir * t) > half:
				continue
			var j := clampi(floori(t / length * float(count)), 0, count - 1)
			_claim(made[j], i, false)


func _new_piece(kind: int, k: int, list: Array[int]) -> Piece:
	var p := Piece.new()
	p.index = pieces.size()
	p.kind = kind
	p.ring = k
	pieces.append(p)
	list.append(p.index)
	return p


func _claim(p: Piece, i: int, gate: bool) -> void:
	cell_piece[i] = p.index + 1
	cell_ring[i] = p.ring + 1
	if gate:
		cell_gate[i] = 1
	p.cells.append(i)


## Claims the unclaimed cells whose centres lie in the box spanned by `t0..t1` along `t` and
## `n0..n1` along the outward normal, around the piece's centre.
func _claim_box(p: Piece, t: Vector2, t0: float, t1: float, n0: float, n1: float, gate: bool) -> void:
	_claim_box_at(p, p.center, t, t0, t1, n0, n1, gate)


func _claim_box_at(p: Piece, origin: Vector2, t: Vector2, t0: float, t1: float, n0: float, n1: float,
		gate: bool = false) -> void:
	var n := Vector2(t.y, -t.x)
	if n.dot(origin - center) < 0.0:
		n = -n
	var reach := maxf(maxf(absf(t0), absf(t1)), maxf(absf(n0), absf(n1))) + 1.0
	var lo := Vector2i(floori(origin.x - reach), floori(origin.y - reach))
	var hi := Vector2i(ceili(origin.x + reach), ceili(origin.y + reach))
	for y in range(maxi(lo.y, 0), mini(hi.y, size)):
		for x in range(maxi(lo.x, 0), mini(hi.x, size)):
			var i := y * size + x
			if cell_ring[i] != 0:
				continue
			var d := Vector2(x + 0.5, y + 0.5) - origin
			var a := d.dot(t)
			var b := d.dot(n)
			if a >= t0 and a <= t1 and b >= n0 and b <= n1:
				_claim(p, i, gate)


func _claim_disc(p: Piece, c: Vector2, radius: float) -> void:
	var lo := Vector2i(floori(c.x - radius - 1.0), floori(c.y - radius - 1.0))
	var hi := Vector2i(ceili(c.x + radius + 1.0), ceili(c.y + radius + 1.0))
	for y in range(maxi(lo.y, 0), mini(hi.y, size)):
		for x in range(maxi(lo.x, 0), mini(hi.x, size)):
			var i := y * size + x
			if cell_ring[i] == 0 and Vector2(x + 0.5, y + 0.5).distance_to(c) <= radius:
				_claim(p, i, false)


## Unit tangent of the ring at `angle` (the direction of increasing angle).
static func _tangent(angle: float) -> Vector2:
	return Vector2(-sin(angle), cos(angle))


static func _param(values: Array[float], k: int) -> float:
	return values[clampi(k, 0, values.size() - 1)]
