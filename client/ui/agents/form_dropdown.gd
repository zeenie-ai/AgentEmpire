class_name FormDropdown
extends OptionButton
## A dropdown field in the window's look (the theme gives the field box and the chevron). Each
## entry carries a string value; entries can be disabled with a reason in their tooltip.


func _init() -> void:
	focus_mode = Control.FOCUS_NONE
	fit_to_longest_item = false
	clip_text = true
	text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(120, 36)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func add_entry(label_text: String, value: String, tip: String = "", is_disabled: bool = false) -> int:
	add_item(label_text)
	var idx := item_count - 1
	set_item_metadata(idx, value)
	if tip != "":
		set_item_tooltip(idx, tip)
	set_item_disabled(idx, is_disabled)
	return idx


func value() -> String:
	if selected < 0:
		return ""
	var v: Variant = get_item_metadata(selected)
	return String(v) if v != null else ""


func index_of(v: String) -> int:
	for i in item_count:
		var m: Variant = get_item_metadata(i)
		if m != null and String(m) == v:
			return i
	return -1


## Selects the entry with value `v`; returns false when there is none.
func select_value(v: String) -> bool:
	var i := index_of(v)
	if i < 0:
		return false
	select(i)
	return true


func _make_custom_tooltip(for_text: String) -> Object:
	if for_text == "":
		return null
	return CraftedTooltip.make(for_text)
