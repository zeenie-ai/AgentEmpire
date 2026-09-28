class_name ManaOrb
extends Control
## Placeholder Mana orb. Mana is the real-money budget (1 Mana = $0.01) owned by the Town Hall;
## until that connection exists (Phase 3) the orb is dim and reads "offline".

var level: String = "offline"
var _time: float = 0.0


func _init() -> void:
	custom_minimum_size = Vector2(128, 36)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_PASS
	tooltip_text = "Mana is your real budget (1 Mana = $0.01).\nIt appears here once the Town Hall is connected."


func set_level(value: String) -> void:
	if value != level:
		level = value
		queue_redraw()


func _process(delta: float) -> void:
	_time += delta
	queue_redraw()


func _draw() -> void:
	var r := size.y * 0.45
	var c := Vector2(r + 2, size.y * 0.5)
	var online := level != "offline"
	var glow := 0.5 + 0.5 * sin(_time * 1.6)
	draw_circle(c, r, UiTokens.STATUS_BG.lightened(0.05))
	var fill := UiTokens.MINT if online else UiTokens.MINT.darkened(0.55)
	draw_circle(c + Vector2(0, r * 0.25), r * 0.62, Color(fill, 0.35 + glow * (0.2 if online else 0.08)))
	draw_circle(c + Vector2(-r * 0.3, -r * 0.35), r * 0.18, Color(1, 1, 1, 0.35))
	draw_arc(c, r, 0.0, TAU, 40, Color(UiTokens.MINT, 0.9 if online else 0.45), 1.5, true)
	var x := c.x + r + 10
	draw_string(UiFonts.mono(500, 2), Vector2(x, c.y - 3), "MANA", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UiTokens.HUD_MUTED)
	draw_string(UiFonts.mono(500, 1), Vector2(x, c.y + 12), level, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
		UiTokens.MINT if online else UiTokens.HUD_SUBTLE)
