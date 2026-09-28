class_name AgeBadge
extends Control
## The age badge: a gold hexagon with the age numeral (the V6 Hex Realm era badge) and the age
## name in Cinzel.

const NUMERALS := ["I", "II", "III", "IV", "V"]

var age: int = 1
var age_name: String = "Founding"


func _init() -> void:
	custom_minimum_size = Vector2(190, 36)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_PASS


func set_age(n: int, label: String) -> void:
	if n == age and label == age_name and tooltip_text != "":
		return
	age = n
	age_name = label
	tooltip_text = "Age %s: %s\nAdvancing raises the next wall and opens more land to build on." % [NUMERALS[clampi(age - 1, 0, 4)], age_name]
	queue_redraw()


func _draw() -> void:
	var h := size.y
	var w := h * 1.1
	var c := Vector2(w * 0.5, h * 0.5)
	var hex := PackedVector2Array([
		Vector2(w * 0.25, 0), Vector2(w * 0.75, 0), Vector2(w, h * 0.5),
		Vector2(w * 0.75, h), Vector2(w * 0.25, h), Vector2(0, h * 0.5)])
	draw_colored_polygon(hex, UiTokens.GOLD)
	var numeral: String = NUMERALS[clampi(age - 1, 0, 4)]
	var f := UiFonts.cinzel(700, 0)
	var fs := 15
	var tw := f.get_string_size(numeral, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(f, Vector2(c.x - tw * 0.5, c.y + fs * 0.36), numeral, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UiTokens.HUD_BG)
	var title := "%s AGE" % age_name.to_upper()
	draw_string(UiFonts.cinzel(700, 2), Vector2(w + 10, c.y + 5), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, UiTokens.HUD_TEXT)
