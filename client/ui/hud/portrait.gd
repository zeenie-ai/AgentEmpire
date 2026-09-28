class_name Portrait
extends Control
## Layered placeholder portrait in the anime status-window style (navy disc, mint ring). Units
## get a head-and-shoulders figure in their tunic colour; buildings and resources get their icon
## on parchment. Real portraits replace this in a later art pass.

var kind: String = "none"
var icon: String = ""
var variant: int = 0


func _init(size_px: float = 96.0) -> void:
	custom_minimum_size = Vector2(size_px, size_px)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func show_unit(unit_variant: int) -> void:
	kind = "unit"
	variant = unit_variant
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
		draw_arc(c, r, 0.0, TAU, 48, UiTokens.MINT, 2.0, true)
	elif kind == "icon":
		draw_circle(c, r, UiTokens.PARCHMENT)
		draw_arc(c, r, 0.0, TAU, 48, UiTokens.GOLD, 2.0, true)
		IconDraw.draw(self, icon, Rect2(c - Vector2(r, r) * 0.62, Vector2(r, r) * 1.24))
	else:
		draw_circle(c, r, UiTokens.HUD_INSET)
		draw_arc(c, r, 0.0, TAU, 48, UiTokens.HUD_BORDER, 2.0, true)
