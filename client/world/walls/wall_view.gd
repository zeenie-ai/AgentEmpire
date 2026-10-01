class_name WallView
extends Node3D
## The town walls (SimWorld.walls, a WallLayout), drawn from the wall art with one MultiMesh per
## ring and kind of piece. Every piece is placed from the layout: curtains are scaled to their
## ring's thickness and stretched to fill the run between two towers, towers to their radius
## with the door toward the town, gates to their passage. Later rings use grander pieces (STYLES).
##
## A ring that rises while the town runs plays the handoff's wall-rise (city-scene.js): each
## piece grows out of the ground with easeOutCubic, the rise travelling both ways around the
## ring from its south gate (the one facing the camera) to the far side, with dust at each
## piece's foot and the "wall_rise" cue as each gatehouse goes up. A town that loads at Age N
## shows walls 1..N standing at once. A piece a building stands on is left out (a gap).

## A ring starts rising (after LEAD_S, so a camera glide can frame it first).
signal rise_started(ring: int, center: Vector3, radius: float, seconds: float)
signal rise_finished(ring: int)

const HIDDEN := Transform3D(Vector3(0.0001, 0, 0), Vector3(0, 0.0001, 0), Vector3(0, 0, 0.0001), Vector3(0, -50, 0))
## Pieces per ring: curtains, the wall towers in turn, the gate towers, and how wide the gate's
## door opening is drawn (tiles; the walkable passage is two cells).
const STYLES: Array[Dictionary] = [
	{"curtain": "wall/curtain", "towers": ["wall/tower_squat", "wall/tower"], "gate_towers": "wall/tower_roofed", "opening": 2.0},
	{"curtain": "wall/curtain", "towers": ["wall/tower", "wall/tower_roofed"], "gate_towers": "wall/tower_roofed", "opening": 2.1},
	{"curtain": "wall/curtain_tall", "towers": ["wall/tower", "wall/tower_catapult"], "gate_towers": "wall/tower_spire", "opening": 2.2},
	{"curtain": "wall/curtain_tall", "towers": ["wall/tower_roofed", "wall/tower_spire"], "gate_towers": "wall/tower_spire", "opening": 2.35},
]
const GATE_KEY := "wall/gate"
## Curtain pieces overlap their neighbours by this much, so a run reads as one wall.
const CURTAIN_OVERLAP := 1.04
## How long the camera has to frame a ring before it starts to rise.
const LEAD_S := 1.1
## Seconds one piece takes to rise, by kind.
const RISE_S := {WallLayout.CURTAIN: 1.25, WallLayout.TOWER: 1.55, WallLayout.GATE_TOWER: 1.75, WallLayout.GATE: 1.6}
## The rise travels half way round a ring (south to north) in this many seconds per tile of
## circumference, within SWEEP_MIN..SWEEP_MAX.
const SWEEP_PER_TILE := 0.022
const SWEEP_MIN := 1.6
const SWEEP_MAX := 3.6
## Towers stand a moment before the curtains beside them, and gatehouses before both.
const KIND_LEAD := {WallLayout.CURTAIN: 0.15, WallLayout.TOWER: 0.0, WallLayout.GATE_TOWER: -0.15, WallLayout.GATE: -0.1}

var world: SimWorld
## Ring -> RingDraw.
var rings: Dictionary = {}


class RingDraw:
	extends RefCounted
	var ring: int = 0
	var root: Node3D
	## Mesh key -> MultiMesh.
	var groups: Dictionary = {}
	## {"key", "index", "xform": Transform3D, "piece": int, "kind": int, "delay": float,
	##  "dur": float, "pos": Vector3, "size": float, "started": bool}
	var items: Array[Dictionary] = []
	## Seconds since the rise began (negative during the lead-in); < -999 when not rising.
	var clock: float = -1000.0
	var length: float = 0.0


## Draws every standing ring of `w` at once.
func build(w: SimWorld) -> void:
	clear()
	world = w
	if w.walls == null:
		return
	for k in w.walls_up:
		_make_ring(k, false)


func clear() -> void:
	for d: RingDraw in rings.values():
		d.root.queue_free()
	rings.clear()


func is_rising() -> bool:
	for d: RingDraw in rings.values():
		if d.clock > -999.0:
			return true
	return false


## The sim says ring `ring` changed. `animate`: let a newly standing ring rise (a running town)
## rather than appear (a town just loaded or caught up with the Town Hall).
func on_walls_changed(ring: int, animate: bool) -> void:
	if world == null or world.walls == null:
		return
	var standing := ring < world.walls_up
	var drawn: RingDraw = rings.get(ring)
	if not standing:
		if drawn != null:
			drawn.root.queue_free()
			rings.erase(ring)
		return
	if drawn != null:
		if drawn.clock > -999.0:
			return
		# Already up: a piece opened or closed (a building came or went). Redraw in place.
		drawn.root.queue_free()
		rings.erase(ring)
		_make_ring(ring, false)
		return
	_make_ring(ring, animate)


func _process(delta: float) -> void:
	for d: RingDraw in rings.values():
		if d.clock > -999.0:
			_advance(d, delta)


# --- building a ring ----------------------------------------------------------------------------

func _make_ring(k: int, animate: bool) -> RingDraw:
	var l := world.walls
	var style: Dictionary = STYLES[clampi(k, 0, STYLES.size() - 1)]
	var d := RingDraw.new()
	d.ring = k
	d.root = Node3D.new()
	d.root.name = "Ring%d" % k
	add_child(d.root)
	rings[k] = d
	var thickness := WallLayout._param(WallLayout.THICKNESS, k)
	var curtain_key := String(style["curtain"])
	var curtain_len := maxf(ModelLibrary.mesh(curtain_key).get_aabb().size.x, 0.1)
	var tower_keys: Array = style["towers"]
	var opening := float(style["opening"])
	var tower_n := 0
	d.length = TAU * l.radii[k]
	var sweep := clampf(d.length * SWEEP_PER_TILE, SWEEP_MIN, SWEEP_MAX)
	for pi: int in l.ring_pieces[k]:
		var p := l.pieces[pi]
		var key := ""
		var xf := Transform3D.IDENTITY
		var size := 1.0
		match p.kind:
			WallLayout.CURTAIN:
				key = curtain_key
				var stretch := p.length * CURTAIN_OVERLAP / (curtain_len * thickness)
				xf = _place(p.center, p.outward, Vector3(stretch * thickness, thickness, thickness))
				size = p.length
			WallLayout.TOWER:
				key = String(tower_keys[tower_n % tower_keys.size()])
				tower_n += 1
				var s := p.radius * 2.0
				var lift := 1.0 + 0.035 * sin(float(p.index) * 12.9898)
				xf = _place(p.center, -p.outward, Vector3(s, s * lift, s))
				size = s
			WallLayout.GATE_TOWER:
				key = String(style["gate_towers"])
				var s := p.radius * 2.0
				xf = _place(p.center, -p.outward, Vector3(s, s, s))
				size = s
			WallLayout.GATE:
				key = GATE_KEY
				xf = _place(p.center, p.outward, Vector3.ONE * opening)
				size = opening * 2.2
		var stands := world.piece_stands(pi) or (p.kind == WallLayout.GATE and _gate_stands(k, p.gate))
		var item := {"key": key, "index": 0, "xform": xf, "piece": pi, "kind": p.kind,
			"delay": _delay(p, sweep), "dur": float(RISE_S.get(p.kind, 1.4)),
			"pos": Vector3(p.center.x, 0.0, p.center.y), "size": size, "started": false, "visible": stands}
		d.items.append(item)
	# One MultiMesh per mesh key.
	var counts := {}
	for item in d.items:
		var key := String(item["key"])
		item["index"] = int(counts.get(key, 0))
		counts[key] = int(item["index"]) + 1
	for key: String in counts:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = ModelLibrary.mesh(key)
		mm.instance_count = int(counts[key])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = key.get_slice("/", 1).to_pascal_case()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		d.root.add_child(mmi)
		d.groups[key] = mm
	for item in d.items:
		var mm: MultiMesh = d.groups[String(item["key"])]
		var shown := bool(item["visible"]) and not animate
		mm.set_instance_transform(int(item["index"]), item["xform"] if shown else HIDDEN)
	if animate:
		d.clock = -LEAD_S
		rise_started.emit(k, Vector3(l.center.x, 0.0, l.center.y), l.radii[k], LEAD_S + _total(d))
	return d


## Gatehouse arches stand with their towers: left out only when both towers are gaps.
func _gate_stands(k: int, gate: int) -> bool:
	for p in world.walls.pieces_of(k, WallLayout.GATE_TOWER):
		if p.gate == gate and world.piece_stands(p.index):
			return true
	return false


## Transform for a piece at `at` whose model front (+Z) faces `front` (a ground direction).
static func _place(at: Vector2, front: Vector2, scale: Vector3) -> Transform3D:
	var z := Vector3(front.x, 0.0, front.y).normalized()
	var y := Vector3.UP
	var x := y.cross(z).normalized()
	return Transform3D(Basis(x * scale.x, y * scale.y, z * scale.z), Vector3(at.x, 0.0, at.y))


## When a piece starts to rise: by how far round the ring it stands from the south gate (both
## ways), so the rise sweeps from the front of the town to the back.
func _delay(p: WallLayout.Piece, sweep: float) -> float:
	var from_south := absf(wrapf(p.angle - WallLayout.FIRST_GATE_ANGLE, -PI, PI)) / PI
	return maxf(from_south * sweep + float(KIND_LEAD.get(p.kind, 0.0)), 0.0)


func _total(d: RingDraw) -> float:
	var t := 0.0
	for item in d.items:
		t = maxf(t, float(item["delay"]) + float(item["dur"]))
	return t


# --- the rise ---------------------------------------------------------------------------------------

func _advance(d: RingDraw, delta: float) -> void:
	d.clock += delta
	var done := true
	for item in d.items:
		if not bool(item["visible"]):
			continue
		var mm: MultiMesh = d.groups[String(item["key"])]
		var t := (d.clock - float(item["delay"])) / float(item["dur"])
		if t < 1.0:
			done = false
		if t <= 0.0:
			continue
		if not bool(item["started"]):
			item["started"] = true
			_on_piece_starts(item)
		var e := BuildingView.ease_out_cubic(t)
		var xf: Transform3D = item["xform"]
		if t < 1.0:
			xf.basis.y = xf.basis.y * maxf(e, 0.002)
		mm.set_instance_transform(int(item["index"]), xf)
	if done:
		d.clock = -1000.0
		rise_finished.emit(d.ring)


## A piece begins to rise: dust rolls out along its foot, and the wall rumbles at each gatehouse.
func _on_piece_starts(item: Dictionary) -> void:
	var kind := int(item["kind"])
	var pos: Vector3 = item["pos"]
	var size := float(item["size"])
	var xf: Transform3D = item["xform"]
	var dust := Fx.wall_dust(size, size * 0.5 if kind != WallLayout.CURTAIN else 1.2)
	dust.position = pos
	dust.basis = Basis(xf.basis.x.normalized(), Vector3.UP, xf.basis.z.normalized())
	add_child(dust)
	(dust as Node).set("emitting", true)
	Fx.free_after(dust, 3.2)
	if kind == WallLayout.GATE:
		var audio := get_node_or_null("/root/Audio")
		if audio != null and audio.has_method("play_at"):
			audio.call("play_at", "wall_rise", pos)
