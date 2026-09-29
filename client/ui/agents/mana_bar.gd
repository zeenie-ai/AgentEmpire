class_name ManaBar
extends Control
## A Mana gauge: a slim crystal tube filled to spent / total, the reserved part as a lighter band
## after it, quarter ticks, and a caption on the right ("42 / 150 MANA", with "≈" when the use is
## an estimate). The fill turns amber past 80% and red at the seal.

var total: float = 0.0
var spent: float = 0.0
var reserved: float = 0.0
var estimate: bool = false
var show_caption: bool = true
## The caption's unit ("MANA", "XP", "%"); "" hides it.
var unit: String = "MANA"
## Fixed caption width in pixels (0 measures it).
var caption_width: float = 0.0
var look: int = AgentTheme.HUD
## Colours of the normal fill (top, bottom); amber and red take over near and at the end.
var fill_top: Color = Color("#b8fff0")
var fill_bottom: Color = Color("#2a9d90")
## False keeps the normal fill colours at any ratio (XP bars).
var warn_colors: bool = true
var bar_height: float = 10.0


func _init(px_width: float = 180.0, px_height: float = 16.0) -> void:
	custom_minimum_size = Vector2(px_width, px_height)
	mouse_filter = Control.MOUSE_FILTER_PASS
	size_flags_vertical = Control.SIZE_SHRINK_CENTER


func set_values(spent_value: float, total_value: float, reserved_value: float = 0.0, is_estimate: bool = false) -> void:
	spent = maxf(spent_value, 0.0)
	total = maxf(total_value, 0.0)
	reserved = maxf(reserved_value, 0.0)
	estimate = is_estimate
	queue_redraw()


func ratio() -> float:
	return spent / total if total > 0.0 else 0.0


func caption() -> String:
	if unit == "":
		return ""
	var s := "%s / %s %s" % [AgentUi.group(roundi(spent)), AgentUi.group(roundi(total)), unit]
	return ("≈ " + s) if estimate else s


func _draw() -> void:
	var font := UiFonts.mono(600, 1)
	var fs := 11
	var text := caption() if show_caption else ""
	var cw := 0.0
	if text != "":
		cw = caption_width if caption_width > 0.0 else font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		cw += 10.0
	var bw := maxf(size.x - cw, 8.0)
	var h := minf(bar_height, size.y)
	var y := floorf((size.y - h) * 0.5)
	var track := Rect2(Vector2(0, y), Vector2(bw, h))
	# Track: sunken glass.
	draw_rect(track.grow(1.0), Color(0, 0, 0, 0.55))
	draw_rect(track, Color(0.02, 0.03, 0.07, 0.9) if look != AgentTheme.DOCUMENT else Color("#2b2119"))
	var r := clampf(ratio(), 0.0, 1.0)
	var top := fill_top
	var bottom := fill_bottom
	if warn_colors and ratio() >= 1.0:
		top = Color("#ffa08e")
		bottom = Color("#b8321f")
	elif warn_colors and ratio() >= 0.8:
		top = Color("#ffe19a")
		bottom = Color("#c9791f")
	if r > 0.0:
		var fr := Rect2(track.position, Vector2(bw * r, h))
		draw_polygon(PackedVector2Array([fr.position, Vector2(fr.end.x, fr.position.y), fr.end, Vector2(fr.position.x, fr.end.y)]),
			PackedColorArray([top, top, bottom, bottom]))
		draw_rect(Rect2(fr.position + Vector2(0, 1), Vector2(fr.size.x, 1)), Color(1, 1, 1, 0.35))
	if reserved > 0.0 and total > 0.0:
		var rs := clampf((spent + reserved) / total, 0.0, 1.0)
		if rs > r:
			var band := Rect2(Vector2(track.position.x + bw * r, y), Vector2(bw * (rs - r), h))
			draw_rect(band, Color(UiTokens.GOLD_BRIGHT, 0.28))
			# Hatching marks the reserved part.
			var x := band.position.x + 3.0
			while x < band.end.x:
				draw_line(Vector2(x, band.end.y - 1.0), Vector2(minf(x + 4.0, band.end.x), band.position.y + 1.0), Color(UiTokens.GOLD_BRIGHT, 0.55), 1.0)
				x += 5.0
	for q in [0.25, 0.5, 0.75]:
		var tx := floorf(track.position.x + bw * float(q)) + 0.5
		draw_line(Vector2(tx, y + 1.0), Vector2(tx, y + h - 1.0), Color(1, 1, 1, 0.1), 1.0)
	draw_rect(track, Color(1, 1, 1, 0.08), false, 1.0)
	if text != "":
		var col := AgentTheme.c(look, "soft")
		if warn_colors and ratio() >= 1.0:
			col = AgentTheme.c(look, "bad")
		draw_string(font, Vector2(bw + 10.0, size.y * 0.5 + fs * 0.36), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
