class_name Glyph
extends Control
## A small vector glyph drawn in one colour at any size. paint() draws one inside any control's
## _draw(). Names: close, chevron_down, chevron_up, chevron_left, chevron_right, plus, minus,
## check, lock, folder, git, up, dice, info, warning, clock, scroll, wisp, express, person, mana,
## diamond, star, merge, export, quill, hourglass, coin, seal, dot.

var glyph: String = "":
	set(value):
		glyph = value
		queue_redraw()
var color: Color = Color.WHITE:
	set(value):
		color = value
		queue_redraw()
## Stroke weight multiplier.
var weight: float = 1.0
## When above 0, the glyph is drawn this big in the middle of its rect (see inside()).
var px: float = 0.0


func _init(glyph_name: String = "", col: Color = Color.WHITE, px: float = 16.0) -> void:
	glyph = glyph_name
	color = col
	custom_minimum_size = Vector2(px, px)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_vertical = Control.SIZE_SHRINK_CENTER


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if px > 0.0:
		r = Rect2((size - Vector2(px, px)) * 0.5, Vector2(px, px))
	Glyph.paint(self, glyph, r, color, weight)


## A glyph `size_px` big centred in `parent` (a button, say), following its size.
static func inside(parent: Control, glyph_name: String, col: Color, size_px: float) -> Glyph:
	var g := Glyph.new(glyph_name, col, 0.0)
	g.px = size_px
	g.custom_minimum_size = Vector2.ZERO
	parent.add_child(g)
	g.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return g


static func _p(c: Vector2, s: float, x: float, y: float) -> Vector2:
	return c + Vector2(x, y) * s


static func _line(ci: CanvasItem, c: Vector2, s: float, pts: Array, col: Color, w: float) -> void:
	var out := PackedVector2Array()
	for p: Vector2 in pts:
		out.append(c + p * s)
	ci.draw_polyline(out, col, w, true)


static func _poly(ci: CanvasItem, c: Vector2, s: float, pts: Array, col: Color) -> void:
	var out := PackedVector2Array()
	for p: Vector2 in pts:
		out.append(c + p * s)
	ci.draw_colored_polygon(out, col)


static func paint(ci: CanvasItem, glyph_name: String, rect: Rect2, col: Color, weight: float = 1.0) -> void:
	var c := rect.get_center()
	var s := minf(rect.size.x, rect.size.y) * 0.5
	var w := maxf(s * 0.17 * weight, 1.3)
	match glyph_name:
		"close":
			_line(ci, c, s, [Vector2(-0.55, -0.55), Vector2(0.55, 0.55)], col, w)
			_line(ci, c, s, [Vector2(0.55, -0.55), Vector2(-0.55, 0.55)], col, w)
		"chevron_down":
			_line(ci, c, s, [Vector2(-0.55, -0.22), Vector2(0, 0.3), Vector2(0.55, -0.22)], col, w)
		"chevron_up":
			_line(ci, c, s, [Vector2(-0.55, 0.22), Vector2(0, -0.3), Vector2(0.55, 0.22)], col, w)
		"chevron_right":
			_line(ci, c, s, [Vector2(-0.22, -0.55), Vector2(0.3, 0), Vector2(-0.22, 0.55)], col, w)
		"chevron_left":
			_line(ci, c, s, [Vector2(0.22, -0.55), Vector2(-0.3, 0), Vector2(0.22, 0.55)], col, w)
		"plus":
			_line(ci, c, s, [Vector2(-0.6, 0), Vector2(0.6, 0)], col, w)
			_line(ci, c, s, [Vector2(0, -0.6), Vector2(0, 0.6)], col, w)
		"minus":
			_line(ci, c, s, [Vector2(-0.6, 0), Vector2(0.6, 0)], col, w)
		"check":
			_line(ci, c, s, [Vector2(-0.62, 0.02), Vector2(-0.18, 0.46), Vector2(0.64, -0.5)], col, w * 1.1)
		"lock":
			_poly(ci, c, s, [Vector2(-0.58, -0.08), Vector2(0.58, -0.08), Vector2(0.58, 0.78), Vector2(-0.58, 0.78)], col)
			ci.draw_arc(_p(c, s, 0, -0.1), s * 0.36, PI, TAU, 16, col, w, true)
			ci.draw_circle(_p(c, s, 0, 0.3), s * 0.13, Color(0, 0, 0, 0.55))
		"folder":
			_poly(ci, c, s, [Vector2(-0.85, -0.62), Vector2(-0.28, -0.62), Vector2(-0.12, -0.44), Vector2(0.85, -0.44),
				Vector2(0.85, 0.66), Vector2(-0.85, 0.66)], col.darkened(0.25))
			_poly(ci, c, s, [Vector2(-0.85, -0.22), Vector2(0.85, -0.22), Vector2(0.85, 0.66), Vector2(-0.85, 0.66)], col)
		"git", "branch":
			ci.draw_arc(_p(c, s, -0.38, -0.58), s * 0.2, 0.0, TAU, 16, col, w * 0.85, true)
			ci.draw_arc(_p(c, s, -0.38, 0.6), s * 0.2, 0.0, TAU, 16, col, w * 0.85, true)
			ci.draw_arc(_p(c, s, 0.42, -0.2), s * 0.2, 0.0, TAU, 16, col, w * 0.85, true)
			_line(ci, c, s, [Vector2(-0.38, -0.38), Vector2(-0.38, 0.4)], col, w * 0.85)
			_line(ci, c, s, [Vector2(0.42, 0.0), Vector2(0.4, 0.14), Vector2(0.2, 0.3), Vector2(-0.2, 0.36), Vector2(-0.34, 0.4)], col, w * 0.85)
		"up":
			_line(ci, c, s, [Vector2(0, 0.62), Vector2(0, -0.55)], col, w)
			_line(ci, c, s, [Vector2(-0.45, -0.1), Vector2(0, -0.6), Vector2(0.45, -0.1)], col, w)
		"dice":
			var r := Rect2(_p(c, s, -0.68, -0.68), Vector2(1.36, 1.36) * s)
			ci.draw_rect(r, col, false, w * 0.8)
			for p: Vector2 in [Vector2(-0.32, -0.32), Vector2(0, 0), Vector2(0.32, 0.32)]:
				ci.draw_circle(c + p * s, s * 0.12, col)
		"info":
			ci.draw_arc(c, s * 0.82, 0.0, TAU, 32, col, w * 0.8, true)
			ci.draw_circle(_p(c, s, 0, -0.4), s * 0.11, col)
			_line(ci, c, s, [Vector2(0, -0.1), Vector2(0, 0.48)], col, w)
		"warning":
			_line(ci, c, s, [Vector2(0, -0.82), Vector2(0.88, 0.72), Vector2(-0.88, 0.72), Vector2(0, -0.82)], col, w * 0.8)
			_line(ci, c, s, [Vector2(0, -0.28), Vector2(0, 0.2)], col, w)
			ci.draw_circle(_p(c, s, 0, 0.45), s * 0.1, col)
		"clock":
			ci.draw_arc(c, s * 0.82, 0.0, TAU, 32, col, w * 0.8, true)
			_line(ci, c, s, [Vector2(0, -0.5), Vector2(0, 0), Vector2(0.36, 0.14)], col, w * 0.9)
		"scroll":
			_poly(ci, c, s, [Vector2(-0.5, -0.56), Vector2(0.5, -0.56), Vector2(0.5, 0.56), Vector2(-0.5, 0.56)], Color(col, 0.6))
			_poly(ci, c, s, [Vector2(-0.72, -0.82), Vector2(0.72, -0.82), Vector2(0.72, -0.5), Vector2(-0.72, -0.5)], col)
			_poly(ci, c, s, [Vector2(-0.72, 0.5), Vector2(0.72, 0.5), Vector2(0.72, 0.82), Vector2(-0.72, 0.82)], col)
			for y in [-0.2, 0.05, 0.3]:
				_line(ci, c, s, [Vector2(-0.3, y), Vector2(0.3, y)], col.darkened(0.35), maxf(w * 0.5, 1.0))
		"wisp":
			var flame: Array = [Vector2(0, -0.92), Vector2(0.28, -0.45), Vector2(0.55, 0.0), Vector2(0.55, 0.3), Vector2(0.38, 0.62),
				Vector2(0, 0.78), Vector2(-0.38, 0.62), Vector2(-0.55, 0.3), Vector2(-0.5, -0.05), Vector2(-0.18, -0.35)]
			_poly(ci, c, s, flame, Color(col, 0.55))
			ci.draw_circle(_p(c, s, 0, 0.3), s * 0.32, col)
			ci.draw_circle(_p(c, s, -0.08, 0.22), s * 0.12, Color(1, 1, 1, 0.8))
		"express":
			_poly(ci, c, s, [Vector2(0.18, -0.9), Vector2(-0.52, 0.12), Vector2(-0.04, 0.12), Vector2(-0.22, 0.9),
				Vector2(0.52, -0.16), Vector2(0.05, -0.16)], col)
		"person":
			ci.draw_circle(_p(c, s, 0, -0.42), s * 0.3, col)
			_poly(ci, c, s, [Vector2(-0.66, 0.84), Vector2(-0.5, 0.12), Vector2(-0.2, -0.04), Vector2(0.2, -0.04),
				Vector2(0.5, 0.12), Vector2(0.66, 0.84)], col)
		"mana":
			var drop := PackedVector2Array()
			drop.append(_p(c, s, 0, -0.9))
			for i in 17:
				var a := deg_to_rad(-35.0 + 250.0 * float(i) / 16.0)
				drop.append(c + (Vector2(0, 0.22) + Vector2(cos(a), sin(a)) * 0.55) * s)
			ci.draw_colored_polygon(drop, col)
			ci.draw_circle(_p(c, s, -0.18, 0.12), s * 0.12, Color(1, 1, 1, 0.55))
		"diamond":
			var pts := PackedVector2Array([_p(c, s, 0, -0.8), _p(c, s, 0.62, 0), _p(c, s, 0, 0.8), _p(c, s, -0.62, 0)])
			ci.draw_polygon(pts, PackedColorArray([col.lightened(0.45), col, col.darkened(0.35), col.lightened(0.1)]))
		"star":
			var star := PackedVector2Array()
			for i in 10:
				var a := -PI * 0.5 + TAU * float(i) / 10.0
				star.append(c + Vector2(cos(a), sin(a)) * s * (0.86 if i % 2 == 0 else 0.38))
			ci.draw_colored_polygon(star, col)
		"merge":
			ci.draw_arc(_p(c, s, -0.45, -0.62), s * 0.18, 0.0, TAU, 16, col, w * 0.85, true)
			ci.draw_arc(_p(c, s, 0.45, -0.62), s * 0.18, 0.0, TAU, 16, col, w * 0.85, true)
			_line(ci, c, s, [Vector2(-0.45, -0.44), Vector2(-0.45, -0.1), Vector2(0, 0.25), Vector2(0, 0.8)], col, w * 0.85)
			_line(ci, c, s, [Vector2(0.45, -0.44), Vector2(0.45, -0.1), Vector2(0, 0.25)], col, w * 0.85)
			_line(ci, c, s, [Vector2(-0.3, 0.52), Vector2(0, 0.82), Vector2(0.3, 0.52)], col, w * 0.85)
		"export":
			_line(ci, c, s, [Vector2(-0.72, 0.05), Vector2(-0.72, 0.76), Vector2(0.72, 0.76), Vector2(0.72, 0.05)], col, w * 0.85)
			_line(ci, c, s, [Vector2(0, 0.42), Vector2(0, -0.8)], col, w * 0.85)
			_line(ci, c, s, [Vector2(-0.36, -0.44), Vector2(0, -0.82), Vector2(0.36, -0.44)], col, w * 0.85)
		"quill":
			_poly(ci, c, s, [Vector2(0.78, -0.86), Vector2(0.3, -0.62), Vector2(-0.12, -0.2), Vector2(-0.4, 0.3),
				Vector2(-0.18, 0.28), Vector2(0.22, -0.05), Vector2(0.56, -0.44)], col)
			_line(ci, c, s, [Vector2(-0.4, 0.3), Vector2(-0.7, 0.85)], col, w * 0.8)
		"hourglass":
			_poly(ci, c, s, [Vector2(-0.55, -0.8), Vector2(0.55, -0.8), Vector2(0.08, 0.0), Vector2(-0.08, 0.0)], col)
			_poly(ci, c, s, [Vector2(-0.08, 0.0), Vector2(0.08, 0.0), Vector2(0.55, 0.8), Vector2(-0.55, 0.8)], Color(col, 0.55))
		"seal":
			var wax := PackedVector2Array()
			for i in 24:
				var ang := TAU * float(i) / 24.0
				wax.append(c + Vector2(cos(ang), sin(ang)) * s * (0.9 if i % 2 == 0 else 0.8))
			ci.draw_colored_polygon(wax, col)
			ci.draw_arc(c, s * 0.56, 0.0, TAU, 32, col.lightened(0.35), maxf(s * 0.08, 1.0), true)
			var st := PackedVector2Array()
			for i in 10:
				var ang := -PI * 0.5 + TAU * float(i) / 10.0
				st.append(c + Vector2(cos(ang), sin(ang)) * s * (0.36 if i % 2 == 0 else 0.15))
			ci.draw_colored_polygon(st, col.lightened(0.35))
		"coin":
			ci.draw_circle(c, s * 0.82, col.darkened(0.2))
			ci.draw_circle(c, s * 0.64, col)
			ci.draw_arc(c, s * 0.46, 0.0, TAU, 24, col.darkened(0.25), maxf(s * 0.1, 1.0), true)
		"dot":
			ci.draw_circle(c, s * 0.62, col)
			ci.draw_circle(c + Vector2(-0.18, -0.2) * s, s * 0.2, Color(1, 1, 1, 0.35))
		_:
			ci.draw_circle(c, s * 0.4, col)
