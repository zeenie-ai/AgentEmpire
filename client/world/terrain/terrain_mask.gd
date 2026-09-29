class_name TerrainMask
extends RefCounted
## The two ground masks sampled by ground.gdshader and grass.gdshader (terrain.gdshaderinc).
## Both cover the map plus MARGIN tiles on each side.
## - static_texture (RG8, one pixel per tile): r = forest floor under trees (and rising toward
##   the backdrop forest outside the map), g = paving around the Keep.
## - wear_texture (R8, WEAR_PX pixels per tile): worn dirt under and around buildings, around the
##   plaza, and footpaths that townsfolk wear into the grass as they walk. It is updated in place
##   and re-uploaded at most every UPLOAD_EVERY_S seconds.

const MARGIN := 32
const WEAR_PX := 4
const PLAZA_RADIUS := 4.3
const UPLOAD_EVERY_S := 1.0
## Walking wears the grass a little per stamp, up to PATH_MAX: a trodden path, not bare dirt.
const PATH_STEP := 0.02
const PATH_MAX := 0.62

var origin: Vector2 = Vector2(-MARGIN, -MARGIN)
## Side of the covered square, in tiles.
var tiles: int = 0
var map_size: int = 0
var static_texture: ImageTexture
var wear_image: Image
var wear_texture: ImageTexture

var _dirty: bool = false
var _since_upload: float = 0.0


func build(w: SimWorld) -> void:
	map_size = w.grid.size
	tiles = map_size + MARGIN * 2
	origin = Vector2(-MARGIN, -MARGIN)
	_build_static(w)
	var px := tiles * WEAR_PX
	wear_image = Image.create(px, px, false, Image.FORMAT_R8)
	paint_ring(w.map_center(), PLAZA_RADIUS + 0.1, 0.9, 0.55)
	for b: SimBuilding in w.buildings.values():
		paint_building(b)
	wear_texture = ImageTexture.create_from_image(wear_image)
	_dirty = false


func size_world() -> Vector2:
	return Vector2(tiles, tiles)


func _build_static(w: SimWorld) -> void:
	var dens := PackedFloat32Array()
	dens.resize(tiles * tiles)
	for n: SimResourceNode in w.nodes.values():
		if n.kind != "tree":
			continue
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var x := n.cell.x + dx + MARGIN
				var y := n.cell.y + dy + MARGIN
				if x >= 0 and y >= 0 and x < tiles and y < tiles:
					dens[y * tiles + x] += 0.12 if (dx == 0 and dy == 0) else (0.07 if absi(dx) + absi(dy) <= 2 else 0.035)
	var centre := w.map_center()
	var data := PackedByteArray()
	data.resize(tiles * tiles * 2)
	var n := float(map_size)
	for y in tiles:
		for x in tiles:
			var i := y * tiles + x
			var wx := float(x - MARGIN) + 0.5
			var wy := float(y - MARGIN) + 0.5
			var f := dens[i]
			var outside := maxf(maxf(-wx, -wy), maxf(wx - n, wy - n))
			if outside > -2.0:
				f = maxf(f, clampf((outside + 2.0) / 7.0, 0.0, 1.0) * 0.75)
			var d := Vector2(wx, wy).distance_to(centre)
			var pave := clampf((PLAZA_RADIUS - d) / 1.1 + 0.5, 0.0, 1.0)
			data[i * 2] = int(clampf(f, 0.0, 1.0) * 255.0)
			data[i * 2 + 1] = int(pave * 255.0)
	var img := Image.create_from_data(tiles, tiles, false, Image.FORMAT_RG8, data)
	static_texture = ImageTexture.create_from_image(img)


## Worn earth under a building footprint and fading out around it.
func paint_building(b: SimBuilding) -> void:
	var r := Rect2(Vector2(b.cell), Vector2(b.size))
	var reach := 1.7 if b.type != "farm" else 1.0
	var inner := 0.95 if b.type != "farm" else 0.55
	_paint_rect(r, reach, inner)
	_dirty = true


## A dirt band of `width` around a circle of `radius` (the plaza edge).
func paint_ring(centre: Vector2, radius: float, width: float, strength: float) -> void:
	var box := Rect2(centre - Vector2.ONE * (radius + width), Vector2.ONE * (radius + width) * 2.0)
	var p0 := _to_px(box.position)
	var p1 := _to_px(box.end)
	for py in range(p0.y, p1.y + 1):
		for px in range(p0.x, p1.x + 1):
			if not _in_image(px, py):
				continue
			var wp := _to_world(px, py)
			var d := absf(wp.distance_to(centre) - radius)
			var v := clampf(1.0 - d / width, 0.0, 1.0)
			v = v * v * (3.0 - 2.0 * v) * strength
			_raise(px, py, v)
	_dirty = true


func _paint_rect(r: Rect2, reach: float, inner: float) -> void:
	var p0 := _to_px(r.position - Vector2.ONE * reach)
	var p1 := _to_px(r.end + Vector2.ONE * reach)
	for py in range(p0.y, p1.y + 1):
		for px in range(p0.x, p1.x + 1):
			if not _in_image(px, py):
				continue
			var wp := _to_world(px, py)
			var dx := maxf(maxf(r.position.x - wp.x, wp.x - r.end.x), 0.0)
			var dy := maxf(maxf(r.position.y - wp.y, wp.y - r.end.y), 0.0)
			var d := sqrt(dx * dx + dy * dy)
			var v := clampf(1.0 - d / reach, 0.0, 1.0)
			v = v * v * (3.0 - 2.0 * v) * inner
			_raise(px, py, v)


## Footsteps: wears the grass a little at a walking unit's position.
func stamp(pos: Vector2) -> void:
	var c := _to_px(pos)
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var px := c.x + ox
			var py := c.y + oy
			if not _in_image(px, py):
				continue
			var k := 1.0 if (ox == 0 and oy == 0) else (0.5 if ox == 0 or oy == 0 else 0.25)
			var cur := wear_image.get_pixel(px, py).r
			if cur >= PATH_MAX:
				continue
			wear_image.set_pixel(px, py, Color(minf(cur + PATH_STEP * k, PATH_MAX), 0, 0))
	_dirty = true


## Uploads the wear texture when it changed (throttled).
func update(delta: float) -> void:
	_since_upload += delta
	if _dirty and _since_upload >= UPLOAD_EVERY_S:
		flush()


func flush() -> void:
	if wear_texture != null and _dirty:
		wear_texture.update(wear_image)
	_dirty = false
	_since_upload = 0.0


func _raise(px: int, py: int, v: float) -> void:
	if v <= 0.0:
		return
	var cur := wear_image.get_pixel(px, py).r
	if v > cur:
		wear_image.set_pixel(px, py, Color(v, 0, 0))


func _to_px(p: Vector2) -> Vector2i:
	return Vector2i(floori((p.x - origin.x) * WEAR_PX), floori((p.y - origin.y) * WEAR_PX))


func _to_world(px: int, py: int) -> Vector2:
	return Vector2((float(px) + 0.5) / WEAR_PX + origin.x, (float(py) + 0.5) / WEAR_PX + origin.y)


func _in_image(px: int, py: int) -> bool:
	var s := tiles * WEAR_PX
	return px >= 0 and py >= 0 and px < s and py < s
