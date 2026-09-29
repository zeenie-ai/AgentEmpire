class_name CraftedTooltip
extends VBoxContainer
## Rich tooltip contents on the parchment tooltip panel: the first line as a Cinzel title with a
## rule under it, the rest as body text; "Cost:" lines show resource icons, "Hotkey:" lines a
## key cap. Fades in. Controls return it from _make_custom_tooltip().

const MAX_WIDTH := 300.0


static func make(text: String) -> Control:
	var t := CraftedTooltip.new()
	t.build(text)
	return t


func build(text: String) -> void:
	add_theme_constant_override("separation", 4)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lines := text.split("\n")
	if lines.is_empty():
		return
	var title := Label.new()
	title.text = lines[0]
	title.add_theme_font_override("font", UiFonts.cinzel(700, 1))
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", UiTokens.INK)
	add_child(title)
	if lines.size() > 1:
		var rule := ColorRect.new()
		rule.color = Color(UiTokens.SEPIA, 0.45)
		rule.custom_minimum_size = Vector2(0, 1)
		add_child(rule)
	for i in range(1, lines.size()):
		var line := lines[i]
		if line.begins_with("Cost: "):
			add_child(_cost_row(line.substr(6)))
		elif line.begins_with("Hotkey: "):
			add_child(_hotkey_row(line.substr(8)))
		else:
			var body := Label.new()
			body.text = line
			body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			body.custom_minimum_size = Vector2(minf(MAX_WIDTH, maxf(160.0, line.length() * 6.5)), 0)
			body.add_theme_font_override("font", UiFonts.spectral("Regular"))
			body.add_theme_font_size_override("font_size", 14)
			body.add_theme_color_override("font_color", UiTokens.INK_SOFT)
			add_child(body)


func _ready() -> void:
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.14)


## "20 Wood, 30 Stone" as icons and numbers.
func _cost_row(text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	for part in text.split(", "):
		var bits := part.split(" ")
		if bits.size() < 2:
			continue
		var res := bits[1].to_lower()
		var chip := HBoxContainer.new()
		chip.add_theme_constant_override("separation", 3)
		chip.add_child(IconView.new(res, 16))
		var n := Label.new()
		n.text = bits[0]
		n.add_theme_font_override("font", UiFonts.mono(700, 0))
		n.add_theme_font_size_override("font_size", 13)
		n.add_theme_color_override("font_color", UiTokens.INK)
		chip.add_child(n)
		row.add_child(chip)
	return row


func _hotkey_row(key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = "Hotkey"
	label.add_theme_font_override("font", UiFonts.mono(500, 2))
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", UiTokens.SEPIA)
	row.add_child(label)
	var cap := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = UiTokens.INK
	s.set_corner_radius_all(3)
	s.content_margin_left = 6
	s.content_margin_right = 6
	s.content_margin_top = 1
	s.content_margin_bottom = 1
	cap.add_theme_stylebox_override("panel", s)
	var k := Label.new()
	k.text = key
	k.add_theme_font_override("font", UiFonts.mono(700, 0))
	k.add_theme_font_size_override("font_size", 12)
	k.add_theme_color_override("font_color", UiTokens.GOLD_BRIGHT)
	cap.add_child(k)
	row.add_child(cap)
	return row
