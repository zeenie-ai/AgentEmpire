class_name Portrait
extends Control
## A round portrait in the anime status-window style (navy disc, mint ring). Units show their
## character's rendered head-and-shoulders icon (res://art/icons/townsfolk_[a-d].png) clipped
## to the disc, or a layered placeholder figure in their tunic colour; buildings and resources
## show their icon on parchment.

var kind: String = "none"
var icon: String = ""
var variant: int = 0
var unit_kind: String = "townsfolk"


func _init(size_px: float = 96.0) -> void:
	custom_minimum_size = Vector2(size_px, size_px)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func show_unit(unit_variant: int, of_kind: String = "townsfolk") -> void:
	kind = "unit"
	variant = unit_variant
	unit_kind = of_kind
	queue_redraw()


func show_icon(icon_name: String) -> void:
	kind = "icon"
	icon = icon_name
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.5 - 2.0
	if kind == "unit":
		draw_circle(c, r, UiTokens.STATUS_BG)
		var tex := IconDraw.texture_for(AssetCatalog.character_icon_id(unit_kind, variant))
		if tex != null:
			_draw_clipped(tex, c, r - 1.0)
		else:
			_draw_figure(c, r)
		draw_arc(c, r, 0.0, TAU, 48, UiTokens.MINT, 2.0, true)
		draw_arc(c, r + 1.5, PI * 1.1, PI * 1.9, 24, Color(1, 1, 1, 0.25), 1.0, true)
	elif kind == "icon":
		draw_circle(c, r, UiTokens.PARCHMENT)
		draw_circle(c + Vector2(0, r * 0.08), r * 0.9, UiTokens.PARCHMENT_DARK)
		draw_arc(c, r, 0.0, TAU, 48, UiTokens.GOLD, 2.0, true)
		IconDraw.draw(self, icon, Rect2(c - Vector2(r, r) * 0.74, Vector2(r, r) * 1.48))
	else:
		draw_circle(c, r, UiTokens.HUD_INSET)
		draw_arc(c, r, 0.0, TAU, 48, UiTokens.HUD_BORDER, 2.0, true)


## `tex` filling a disc of radius `r` (a textured polygon, so it is clipped to the circle).
func _draw_clipped(tex: Texture2D, c: Vector2, r: float) -> void:
	var pts := PackedVector2Array()
	var uvs := PackedVector2Array()
	for i in 48:
		var a := TAU * float(i) / 48.0
		var d := Vector2(cos(a), sin(a))
		pts.append(c + d * r)
		# Zoom in a little on the head and shoulders.
		uvs.append(Vector2(0.5, 0.46) + d * 0.44)
	draw_colored_polygon(pts, Color.WHITE, uvs, tex)


func _draw_figure(c: Vector2, r: float) -> void:
	var tunic: Color = Palette.TUNICS[variant % Palette.TUNICS.size()]
	var hair: Color = Palette.HAIR[variant % Palette.HAIR.size()]
	var body := PackedVector2Array()
	for i in 21:
		var a := PI + PI * float(i) / 20.0
		body.append(c + Vector2(cos(a) * r * 0.62, r * 0.98 + sin(a) * r * 0.42))
	draw_colored_polygon(body, tunic)
	draw_rect(Rect2(c + Vector2(-r * 0.12, r * 0.08), Vector2(r * 0.24, r * 0.22)), Palette.SKIN.darkened(0.08))
	draw_circle(c + Vector2(0, -r * 0.12), r * 0.34, Palette.SKIN)
	draw_arc(c + Vector2(0, -r * 0.2), r * 0.35, PI * 1.02, TAU * 0.99, 18, hair, r * 0.2)
	draw_circle(c + Vector2(-r * 0.12, -r * 0.1), r * 0.035, UiTokens.INK)
	draw_circle(c + Vector2(r * 0.12, -r * 0.1), r * 0.035, UiTokens.INK)
