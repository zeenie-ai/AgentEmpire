class_name NumberField
extends HBoxContainer
## A number in a field with − and + steppers and a unit after it ("150 MANA", "5.00 USD").
## Typing is filtered to digits (and a decimal point when `decimals` > 0); the value is clamped
## to min_value..max_value when the field loses focus or Enter is pressed.

signal value_changed(value: float)

var min_value: float = 0.0
var max_value: float = 1000000.0
var step: float = 1.0
var decimals: int = 0
var value: float = 0.0

var edit: LineEdit
var _minus: Button
var _plus: Button
var _unit: Label


func _init(unit_text: String = "", look: int = AgentTheme.STATUS) -> void:
	add_theme_constant_override("separation", 4)
	_minus = _stepper("minus", look)
	_minus.pressed.connect(_nudge.bind(-1.0))
	add_child(_minus)
	edit = LineEdit.new()
	edit.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	edit.custom_minimum_size = Vector2(76, 34)
	edit.add_theme_font_override("font", UiFonts.mono(600, 0))
	edit.add_theme_font_size_override("font_size", 14)
	edit.select_all_on_focus = true
	edit.text_changed.connect(_on_typed)
	edit.text_submitted.connect(func(_t: String) -> void: _commit())
	edit.focus_exited.connect(_commit)
	add_child(edit)
	_plus = _stepper("plus", look)
	_plus.pressed.connect(_nudge.bind(1.0))
	add_child(_plus)
	if unit_text != "":
		_unit = AgentUi.label(unit_text.to_upper(), "MonoSmall", self)
		_unit.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_show()


func _stepper(glyph: String, look: int) -> Button:
	var b := Button.new()
	b.theme_type_variation = "IconButton"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(26, 34)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	Glyph.inside(b, glyph, AgentTheme.c(look, "soft"), 11)
	return b


func set_value(v: float, emit: bool = false) -> void:
	var nv := clampf(snappedf(v, pow(10.0, -decimals)) if decimals > 0 else roundf(v), min_value, max_value)
	var changed := not is_equal_approx(nv, value)
	value = nv
	_show()
	if changed and emit:
		value_changed.emit(value)


func _show() -> void:
	if edit == null:
		return
	var t := String.num(value, decimals) if decimals > 0 else str(int(value))
	if decimals > 0 and not t.contains("."):
		t += "." + "0".repeat(decimals)
	elif decimals > 0:
		var frac := t.get_slice(".", 1)
		if frac.length() < decimals:
			t += "0".repeat(decimals - frac.length())
	if edit.text != t:
		var caret := edit.caret_column
		edit.text = t
		edit.caret_column = mini(caret, t.length())


func _on_typed(t: String) -> void:
	var clean := ""
	var dot := false
	for ch in t:
		if ch >= "0" and ch <= "9":
			clean += ch
		elif ch == "." and decimals > 0 and not dot:
			clean += ch
			dot = true
	if clean != t:
		var caret := edit.caret_column
		edit.text = clean
		edit.caret_column = mini(caret, clean.length())
	if clean != "" and clean != ".":
		var v := clampf(float(clean), min_value, max_value)
		if not is_equal_approx(v, value):
			value = v
			value_changed.emit(value)


func _commit() -> void:
	var t := edit.text
	set_value(float(t) if t != "" and t != "." else min_value, true)
	_show()


func _nudge(dir: float) -> void:
	set_value(value + step * dir, true)
