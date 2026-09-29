class_name RankBadge
extends Control
## An agent's guild rank (F, E, D, C, B, A, S) on a small gem-cut hexagon in the rank's colour,
## after the age badge of the top bar. paint() draws one inside another control.

var rank: String = "F":
	set(value):
		rank = value
		tooltip_text = "Rank %s" % rank
		queue_redraw()


func _init(px: float = 26.0) -> void:
	custom_minimum_size = Vector2(px * 1.1, px)
	mouse_filter = Control.MOUSE_FILTER_PASS
	size_flags_vertical = Control.SIZE_SHRINK_CENTER


func _draw() -> void:
	RankBadge.paint(self, rank, Rect2(Vector2.ZERO, size))


static func paint(ci: CanvasItem, rank_text: String, rect: Rect2) -> void:
	var h := rect.size.y
	var w := minf(rect.size.x, h * 1.1)
	var o := rect.position + Vector2((rect.size.x - w) * 0.5, 0)
	var col := AgentUi.rank_color(rank_text)
	var hex := PackedVector2Array([
		o + Vector2(w * 0.25, 0), o + Vector2(w * 0.75, 0), o + Vector2(w, h * 0.5),
		o + Vector2(w * 0.75, h), o + Vector2(w * 0.25, h), o + Vector2(0, h * 0.5)])
	# Dark rim, then the gem: lighter at the top.
	var rim := PackedVector2Array()
	var ctr := o + Vector2(w, h) * 0.5
	for p in hex:
		rim.append(ctr + (p - ctr) * 1.12)
	ci.draw_colored_polygon(rim, Color(0.03, 0.02, 0.02, 0.85))
	ci.draw_polygon(hex, PackedColorArray([col.lightened(0.35), col.lightened(0.35), col, col.darkened(0.3), col.darkened(0.3), col]))
	# Facet highlight across the upper half.
	var shine := PackedVector2Array([hex[0], hex[1], o + Vector2(w * 0.86, h * 0.28), o + Vector2(w * 0.14, h * 0.28)])
	ci.draw_colored_polygon(shine, Color(1, 1, 1, 0.22))
	var f := UiFonts.cinzel(800, 0)
	var fs := int(round(h * 0.58))
	var tw := f.get_string_size(rank_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var base := ctr + Vector2(-tw * 0.5, fs * 0.36)
	ci.draw_string(f, base + Vector2(0, 1), rank_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.25))
	ci.draw_string(f, base, rank_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("#1a120b"))
