class_name Cursors
extends RefCounted
## Custom mouse cursors drawn in code (no image assets): a gold arrow with a dark-wood outline,
## and context variants with a small badge: gather (a green sprig), build (a hammer) and move
## (a mint waypoint). Shapes are filled at 4x and downsampled for smooth edges.
## RtsInput picks the context from what a right-click would do under the cursor.

const DEFAULT := "default"
const GATHER := "gather"
const BUILD := "build"
const MOVE := "move"
const SIZE := 32
const SS := 4
const HOTSPOT := Vector2(2, 2)

const WOOD := Color("#1b140e")
const GOLD_HI := Color("#fff0b8")
const GOLD := Color("#ffd27a")
const GOLD_DEEP := Color("#c98f2e")

static var _textures: Dictionary = {}
static var _current: String = ""


## Sets the default cursor (and the pointing hand) once at startup.
static func install() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_current = ""
	set_context(DEFAULT)
	Input.set_custom_mouse_cursor(texture(DEFAULT), Input.CURSOR_POINTING_HAND, HOTSPOT)


static func set_context(context: String) -> void:
	if context == _current or DisplayServer.get_name() == "headless":
		return
	_current = context
	Input.set_custom_mouse_cursor(texture(context), Input.CURSOR_ARROW, HOTSPOT)


static func current() -> String:
	return _current


static func texture(context: String) -> ImageTexture:
	if not _textures.has(context):
		_textures[context] = ImageTexture.create_from_image(render(context))
	return _textures[context]


## The cursor image for `context` (SIZE x SIZE, RGBA).
static func render(context: String) -> Image:
	var big := Image.create(SIZE * SS, SIZE * SS, false, Image.FORMAT_RGBA8)
	var arrow := PackedVector2Array([Vector2(2, 2), Vector2(2, 23), Vector2(7, 18.2), Vector2(10.6, 26.2),
		Vector2(14.2, 24.6), Vector2(10.8, 16.8), Vector2(17.4, 16.8)])
	_fill_outlined(big, arrow, 1.6, WOOD, func(p: Vector2) -> Color:
		var t := clampf((p.y - 2.0) / 22.0, 0.0, 1.0)
		var c := GOLD.lerp(GOLD_DEEP, t)
		# Brighter along the left edge, like light catching a bevel.
		return c.lerp(GOLD_HI, clampf(1.0 - (p.x - 2.0) / 3.5, 0.0, 1.0) * 0.6))
	match context:
		GATHER:
			_badge(big, Color("#2f4a1c"), func(img: Image) -> void:
				var leaf := _ellipse(Vector2(23.5, 22.5), Vector2(5.8, 3.0), -0.8, 14)
				_fill_outlined(img, leaf, 1.3, WOOD, func(_p: Vector2) -> Color: return Color("#8fcf5a"))
				_fill(img, PackedVector2Array([Vector2(19.5, 27.5), Vector2(20.5, 28.3), Vector2(24.5, 23.5), Vector2(23.6, 22.8)]), Color("#3c6b24")))
		BUILD:
			_badge(big, Color("#3a2a1c"), func(img: Image) -> void:
				var handle := _rot_rect(Vector2(22.5, 24.5), Vector2(2.2, 10.0), 0.75)
				_fill_outlined(img, handle, 1.1, WOOD, func(_p: Vector2) -> Color: return Color("#b0804f"))
				var head := _rot_rect(Vector2(25.2, 21.2), Vector2(7.0, 3.4), 0.75)
				_fill_outlined(img, head, 1.1, WOOD, func(p: Vector2) -> Color: return Color("#c9ccd2").lerp(Color("#8d9097"), clampf((p.y - 18.0) / 6.0, 0.0, 1.0))))
		MOVE:
			_badge(big, Color("#16303a"), func(img: Image) -> void:
				var outer := _ellipse(Vector2(23.5, 23.5), Vector2(5.4, 5.4), 0.0, 20)
				var inner := _ellipse(Vector2(23.5, 23.5), Vector2(3.0, 3.0), 0.0, 16)
				_fill_outlined(img, outer, 1.2, WOOD, func(_p: Vector2) -> Color: return Color("#a9f0d0"))
				_fill(img, inner, Color("#2f7f6a"))
				_fill(img, _ellipse(Vector2(23.5, 23.5), Vector2(1.3, 1.3), 0.0, 10), Color("#e9fff6")))
	big.resize(SIZE, SIZE, Image.INTERPOLATE_LANCZOS)
	return big


## A dark disc behind a badge so it reads on any ground.
static func _badge(img: Image, back: Color, draw: Callable) -> void:
	_fill(img, _ellipse(Vector2(23.5, 23.5), Vector2(8.2, 8.2), 0.0, 24), Color(back, 0.9))
	draw.call(img)


static func _ellipse(c: Vector2, r: Vector2, rot: float, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		out.append(c + Vector2(cos(a) * r.x, sin(a) * r.y).rotated(rot))
	return out


static func _rot_rect(c: Vector2, s: Vector2, rot: float) -> PackedVector2Array:
	var h := s * 0.5
	var out := PackedVector2Array()
	for p: Vector2 in [Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)]:
		out.append(c + p.rotated(rot))
	return out


## Fills `pts` (in cursor pixels) grown by `outline` in `line`, then shaded by `shade(p)`.
static func _fill_outlined(img: Image, pts: PackedVector2Array, outline: float, line: Color, shade: Callable) -> void:
	for grown in Geometry2D.offset_polygon(pts, outline, Geometry2D.JOIN_ROUND):
		_fill(img, grown, line)
	_fill_shaded(img, pts, shade)


static func _fill(img: Image, pts: PackedVector2Array, col: Color) -> void:
	_fill_shaded(img, pts, func(_p: Vector2) -> Color: return col)


## Even-odd scanline fill at SS times the cursor size; blends over what is there.
static func _fill_shaded(img: Image, pts: PackedVector2Array, shade: Callable) -> void:
	var n := pts.size()
	if n < 3:
		return
	var ymin := INF
	var ymax := -INF
	for p in pts:
		ymin = minf(ymin, p.y)
		ymax = maxf(ymax, p.y)
	var h := img.get_height()
	var w := img.get_width()
	for py in range(maxi(0, int(floor(ymin * SS))), mini(h, int(ceil(ymax * SS)) + 1)):
		var y := (float(py) + 0.5) / float(SS)
		var xs: Array[float] = []
		for i in n:
			var a := pts[i]
			var b := pts[(i + 1) % n]
			if (a.y <= y and b.y > y) or (b.y <= y and a.y > y):
				xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
		xs.sort()
		for k in range(0, xs.size() - 1, 2):
			var x0 := maxi(0, int(round(xs[k] * SS)))
			var x1 := mini(w - 1, int(round(xs[k + 1] * SS)) - 1)
			for px in range(x0, x1 + 1):
				var c: Color = shade.call(Vector2((float(px) + 0.5) / float(SS), y))
				if c.a >= 0.999:
					img.set_pixel(px, py, c)
				else:
					img.set_pixel(px, py, img.get_pixel(px, py).blend(c))
