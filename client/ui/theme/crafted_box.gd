class_name CraftedBox
extends StyleBox
## A layered panel style in the handoff palette, drawn in code:
##   1. a soft drop shadow;
##   2. a dark outer frame;
##   3. the body: a vertical gradient with a faint wood grain;
##   4. an inner shadow along the edges and a bevel (light top-left, dark bottom-right; flipped
##      when `sunken`);
##   5. a thin gold trim inset from the edge, with small diamond studs at the corners.
## Used for the HUD panels, buttons, tooltips and toasts (ThemeBuilder).

## Body gradient, top and bottom.
@export var top_color: Color = Color("#2a1f15")
@export var bottom_color: Color = Color("#150f0a")
@export var frame_color: Color = Color("#0b0805")
@export var trim_color: Color = Color(0.878, 0.71, 0.376, 0.75)
## Width of the gold trim line (0 hides it) and its inset from the outer edge.
@export var trim_width: float = 1.0
@export var trim_inset: float = 3.0
@export var studs: bool = true
@export var bevel: float = 1.0
@export var sunken: bool = false
@export var inner_shadow: float = 10.0
@export var inner_shadow_alpha: float = 0.35
@export var shadow_size: float = 8.0
@export var shadow_alpha: float = 0.35
@export var shadow_offset: Vector2 = Vector2(0, 3)
@export var grain: float = 0.07
## Extra glow on the trim (hover states).
@export var glow: float = 0.0

static var _grain_tex: ImageTexture


func _init() -> void:
	set_content_margin_all(10.0)


func copy() -> CraftedBox:
	return duplicate() as CraftedBox


func _get_draw_rect(rect: Rect2) -> Rect2:
	return rect.grow(shadow_size)


func _draw(ci: RID, rect: Rect2) -> void:
	var rs := RenderingServer
	# 1. Drop shadow: a few expanding rings with falling alpha.
	if shadow_size > 0.0 and shadow_alpha > 0.0:
		var steps := 5
		for i in steps:
			var t := float(i + 1) / float(steps)
			var r := rect.grow(shadow_size * t)
			r.position += shadow_offset
			rs.canvas_item_add_rect(ci, r, Color(0, 0, 0, shadow_alpha * (1.0 - t) * 0.35))
	# 2. Outer frame.
	rs.canvas_item_add_rect(ci, rect, frame_color)
	var body := rect.grow(-1.0)
	# 3. Body gradient.
	_gradient_rect(ci, body, top_color, bottom_color)
	if grain > 0.0:
		rs.canvas_item_add_texture_rect(ci, body, grain_texture().get_rid(), true, Color(1, 0.9, 0.75, grain))
	# 4. Inner shadow and bevel.
	if inner_shadow > 0.0:
		var a := Color(0, 0, 0, inner_shadow_alpha)
		var z := Color(0, 0, 0, 0)
		var s := minf(inner_shadow, minf(body.size.x, body.size.y) * 0.5)
		_gradient_rect(ci, Rect2(body.position, Vector2(body.size.x, s)), a, z)
		_gradient_rect(ci, Rect2(Vector2(body.position.x, body.end.y - s), Vector2(body.size.x, s)), z, a)
		_hgradient_rect(ci, Rect2(body.position, Vector2(s, body.size.y)), a, z)
		_hgradient_rect(ci, Rect2(Vector2(body.end.x - s, body.position.y), Vector2(s, body.size.y)), z, a)
	if bevel > 0.0:
		var light := Color(1.0, 0.92, 0.75, 0.13)
		var dark := Color(0, 0, 0, 0.45)
		if sunken:
			var t := light
			light = dark
			dark = t
		rs.canvas_item_add_rect(ci, Rect2(body.position, Vector2(body.size.x, bevel)), light)
		rs.canvas_item_add_rect(ci, Rect2(body.position, Vector2(bevel, body.size.y)), light)
		rs.canvas_item_add_rect(ci, Rect2(Vector2(body.position.x, body.end.y - bevel), Vector2(body.size.x, bevel)), dark)
		rs.canvas_item_add_rect(ci, Rect2(Vector2(body.end.x - bevel, body.position.y), Vector2(bevel, body.size.y)), dark)
	# 5. Gold trim and corner studs.
	if trim_width > 0.0:
		var tr := rect.grow(-trim_inset)
		if tr.size.x > 4.0 and tr.size.y > 4.0:
			var tc := trim_color
			if glow > 0.0:
				_outline(ci, tr.grow(1.0), Color(tc, tc.a * glow * 0.5), 2.0)
				tc = tc.lightened(glow * 0.3)
			_outline(ci, tr, tc, trim_width)
			if studs and tr.size.x > 24.0 and tr.size.y > 24.0:
				for c in [tr.position, Vector2(tr.end.x, tr.position.y), tr.end, Vector2(tr.position.x, tr.end.y)]:
					_stud(ci, c, 3.5, tc)


func _outline(ci: RID, r: Rect2, c: Color, w: float) -> void:
	var rs := RenderingServer
	rs.canvas_item_add_rect(ci, Rect2(r.position, Vector2(r.size.x, w)), c)
	rs.canvas_item_add_rect(ci, Rect2(Vector2(r.position.x, r.end.y - w), Vector2(r.size.x, w)), c)
	rs.canvas_item_add_rect(ci, Rect2(Vector2(r.position.x, r.position.y + w), Vector2(w, r.size.y - w * 2.0)), c)
	rs.canvas_item_add_rect(ci, Rect2(Vector2(r.end.x - w, r.position.y + w), Vector2(w, r.size.y - w * 2.0)), c)


func _stud(ci: RID, c: Vector2, r: float, col: Color) -> void:
	var outer := PackedVector2Array([c + Vector2(0, -r - 1.2), c + Vector2(r + 1.2, 0), c + Vector2(0, r + 1.2), c + Vector2(-r - 1.2, 0)])
	RenderingServer.canvas_item_add_polygon(ci, outer, PackedColorArray([frame_color]))
	var inner := PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)])
	var hi := col.lightened(0.35)
	RenderingServer.canvas_item_add_polygon(ci, inner, PackedColorArray([hi, col, col.darkened(0.3), col]))


func _gradient_rect(ci: RID, r: Rect2, top: Color, bottom: Color) -> void:
	var pts := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	RenderingServer.canvas_item_add_polygon(ci, pts, PackedColorArray([top, top, bottom, bottom]))


func _hgradient_rect(ci: RID, r: Rect2, left: Color, right: Color) -> void:
	var pts := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	RenderingServer.canvas_item_add_polygon(ci, pts, PackedColorArray([left, right, right, left]))


## A tileable, mostly horizontal wood grain (white; modulated by the caller).
static func grain_texture() -> ImageTexture:
	if _grain_tex == null:
		var w := 256
		var h := 128
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.seed = 77
		n.frequency = 1.0 / 16.0
		n.fractal_octaves = 3
		# Seamless noise stretched along x into streaks, then banded like growth rings.
		var img := n.get_seamless_image(w / 4, h, false, false, 0.1, true)
		img.convert(Image.FORMAT_L8)
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)
		var data := img.get_data()
		var out := PackedByteArray()
		out.resize(w * h * 4)
		for y in h:
			for x in w:
				var v := float(data[y * w + x]) / 255.0
				var ring := 0.5 + 0.5 * sin(v * 22.0)
				var a := int(clampf(ring * 255.0, 0.0, 255.0))
				var i := (y * w + x) * 4
				out[i] = 255
				out[i + 1] = 255
				out[i + 2] = 255
				out[i + 3] = a
		_grain_tex = ImageTexture.create_from_image(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, out))
	return _grain_tex
