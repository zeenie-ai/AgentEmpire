class_name CardButton
extends Button
## One command-card slot: icon, hotkey letter, short label and cost. Unaffordable slots stay
## clickable (so the player hears why) but draw dimmed; the active choice has a mint border.
## Hovering lifts the button a little and brightens it; pressing squashes it; tooltips are the
## rich parchment kind (CraftedTooltip).

const HOVER_SCALE := 1.07
const PRESS_SCALE := 0.92

var slot_index: int = 0
var slot: Dictionary = {}

var _tween: Tween
var _hovered: bool = false
var _pulse: float = 0.0


func _init(index: int = 0) -> void:
	slot_index = index
	theme_type_variation = "CardButton"
	custom_minimum_size = Vector2(60, 56)
	focus_mode = Control.FOCUS_NONE
	set_slot({})


func _ready() -> void:
	resized.connect(func() -> void: pivot_offset = size * 0.5)
	pivot_offset = size * 0.5
	mouse_entered.connect(_on_hover.bind(true))
	mouse_exited.connect(_on_hover.bind(false))
	button_down.connect(_to_scale.bind(PRESS_SCALE, 0.06))
	button_up.connect(func() -> void: _to_scale(HOVER_SCALE if _hovered else 1.0, 0.18))


func _on_hover(on: bool) -> void:
	_hovered = on and not disabled
	_to_scale(HOVER_SCALE if _hovered else 1.0, 0.16)


func _to_scale(s: float, seconds: float) -> void:
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "scale", Vector2.ONE * s, seconds)
	_tween.parallel().tween_property(self, "self_modulate", Color(1.12, 1.1, 1.05) if s > 1.0 else Color.WHITE, seconds)


func set_slot(s: Dictionary) -> void:
	if s == slot and not s.is_empty():
		return
	var was_empty := slot.is_empty()
	slot = s
	var empty := s.is_empty()
	disabled = empty
	modulate = Color(1, 1, 1, 0.55) if empty else Color.WHITE
	mouse_default_cursor_shape = Control.CURSOR_ARROW if empty else Control.CURSOR_POINTING_HAND
	tooltip_text = "" if empty else _tooltip(s)
	if was_empty and not empty and is_inside_tree():
		# New orders pop in.
		scale = Vector2.ONE * 0.85
		_to_scale(1.0, 0.25)
	queue_redraw()


func _make_custom_tooltip(for_text: String) -> Object:
	if for_text == "":
		return null
	return CraftedTooltip.make(for_text)


func _tooltip(s: Dictionary) -> String:
	var text := String(s.get("tooltip", ""))
	var cost: Dictionary = s.get("cost", {})
	if not cost.is_empty():
		text += "\nCost: " + Placement.format_cost(cost)
	var key := InputActions.key_label(InputActions.card_action(slot_index))
	if key != "":
		text += "\nHotkey: " + key
	return text


func _process(delta: float) -> void:
	if not slot.is_empty() and bool(slot.get("active", false)):
		_pulse += delta
		queue_redraw()


func _draw() -> void:
	if slot.is_empty():
		return
	var enabled := bool(slot.get("enabled", true))
	var icon_rect := Rect2(Vector2(12, 7), Vector2(size.x - 24, size.y - 25))
	IconDraw.draw(self, String(slot.get("icon", "")), icon_rect, not enabled)
	var key := InputActions.key_label(InputActions.card_action(slot_index))
	# Hotkey cap in the top-left corner.
	var f := UiFonts.mono(700, 0)
	var kw := f.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
	draw_rect(Rect2(Vector2(4, 4), Vector2(kw + 6, 13)), Color(0.05, 0.03, 0.02, 0.75))
	draw_string(f, Vector2(7, 14), key, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UiTokens.GOLD_BRIGHT)
	var cost: Dictionary = slot.get("cost", {})
	var label := String(slot.get("label", ""))
	var shadow := Color(0, 0, 0, 0.7)
	if not cost.is_empty():
		var res := String(cost.keys()[0])
		label = str(int(cost[res]))
		var tw := UiFonts.mono(700, 0).get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		var x := (size.x - tw - 13.0) * 0.5
		IconDraw.draw(self, res, Rect2(Vector2(x - 1.0, size.y - 16.0), Vector2(11, 11)), not enabled)
		draw_string(UiFonts.mono(700, 0), Vector2(x + 12.0, size.y - 5.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, shadow)
		draw_string(UiFonts.mono(700, 0), Vector2(x + 11.0, size.y - 6.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			UiTokens.BTN_TEXT if enabled else UiTokens.BAD.lightened(0.25))
	else:
		draw_string(UiFonts.mono(500, 0), Vector2(1, size.y - 5.0), label, HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, shadow)
		draw_string(UiFonts.mono(500, 0), Vector2(0, size.y - 6.0), label, HORIZONTAL_ALIGNMENT_CENTER, size.x, 10,
			UiTokens.BTN_TEXT if enabled else UiTokens.HUD_MUTED)
	if bool(slot.get("active", false)):
		var a := 0.65 + 0.35 * sin(_pulse * 4.0)
		draw_rect(Rect2(Vector2(2, 2), size - Vector2(4, 4)), Color(UiTokens.MINT, a), false, 2.0)
