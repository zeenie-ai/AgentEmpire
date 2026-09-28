class_name CardButton
extends Button
## One command-card slot: icon, hotkey letter, short label and cost. Unaffordable slots stay
## clickable (so the player hears why) but draw dimmed; the active choice has a mint border.

var slot_index: int = 0
var slot: Dictionary = {}


func _init(index: int = 0) -> void:
	slot_index = index
	theme_type_variation = "CardButton"
	custom_minimum_size = Vector2(60, 56)
	focus_mode = Control.FOCUS_NONE
	set_slot({})


func set_slot(s: Dictionary) -> void:
	if s == slot and not s.is_empty():
		return
	slot = s
	var empty := s.is_empty()
	disabled = empty
	modulate = Color(1, 1, 1, 0.45) if empty else Color.WHITE
	mouse_default_cursor_shape = Control.CURSOR_ARROW if empty else Control.CURSOR_POINTING_HAND
	tooltip_text = "" if empty else _tooltip(s)
	queue_redraw()


func _tooltip(s: Dictionary) -> String:
	var text := String(s.get("tooltip", ""))
	var cost: Dictionary = s.get("cost", {})
	if not cost.is_empty():
		text += "\nCost: " + Placement.format_cost(cost)
	var key := InputActions.key_label(InputActions.card_action(slot_index))
	if key != "":
		text += "\nHotkey: " + key
	return text


func _draw() -> void:
	if slot.is_empty():
		return
	var enabled := bool(slot.get("enabled", true))
	var icon_rect := Rect2(Vector2(13, 6), Vector2(size.x - 26, size.y - 24))
	IconDraw.draw(self, String(slot.get("icon", "")), icon_rect, not enabled)
	var key := InputActions.key_label(InputActions.card_action(slot_index))
	draw_string(UiFonts.mono(700, 0), Vector2(5, 14), key, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UiTokens.GOLD_BRIGHT)
	var cost: Dictionary = slot.get("cost", {})
	var label := String(slot.get("label", ""))
	if not cost.is_empty():
		var res := String(cost.keys()[0])
		label = str(int(cost[res]))
		var tw := UiFonts.mono(500, 0).get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		var x := (size.x - tw - 9.0) * 0.5
		draw_circle(Vector2(x + 3.0, size.y - 9.0), 3.5, Palette.resource(res))
		draw_string(UiFonts.mono(500, 0), Vector2(x + 9.0, size.y - 5.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			UiTokens.BTN_TEXT if enabled else UiTokens.BAD.lightened(0.2))
	else:
		draw_string(UiFonts.mono(500, 0), Vector2(0, size.y - 5.0), label, HORIZONTAL_ALIGNMENT_CENTER, size.x, 10,
			UiTokens.BTN_TEXT if enabled else UiTokens.HUD_MUTED)
	if bool(slot.get("active", false)):
		draw_rect(Rect2(Vector2(2, 2), size - Vector2(4, 4)), UiTokens.MINT, false, 2.0)
