class_name ToastLayer
extends Control
## Toast notifications from Notify, stacked under the top bar in navy status windows whose trim
## follows the kind: mint (info), gold (good), amber (warn), red (error). New toasts pop in
## (fade and a slight overshoot), the stack glides to make room, and old ones fade up and away.

const LIFE_S := 3.8
const IN_S := 0.28
const OUT_S := 0.35
const MAX_TOASTS := 5
const GAP := 6.0

var _toasts: Array[Control] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	Notify.toast.connect(show_toast)
	resized.connect(_layout)


static func kind_color(kind: String) -> Color:
	match kind:
		"warn":
			return UiTokens.WARN
		"error":
			return UiTokens.BAD
		"good":
			return UiTokens.GOLD_BRIGHT
	return UiTokens.MINT


func show_toast(text: String, kind: String) -> void:
	var col := kind_color(kind)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", ThemeBuilder.status_box(col))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(row)
	var gem := _Gem.new()
	gem.color = col
	row.add_child(gem)
	var label := Label.new()
	label.theme_type_variation = "StatusLabel"
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)
	panel.modulate.a = 0.0
	add_child(panel)
	_toasts.append(panel)
	while _toasts.size() > MAX_TOASTS:
		_dismiss(_toasts[0])
	# Wait one frame for the panel's size, then place it and animate it in.
	await get_tree().process_frame
	if not is_instance_valid(panel):
		return
	panel.reset_size()
	panel.pivot_offset = Vector2(panel.size.x * 0.5, 0.0)
	panel.scale = Vector2(0.86, 0.86)
	_layout()
	panel.position.y = _target_y(panel) - 14.0
	var tw := panel.create_tween().set_parallel(true)
	tw.tween_property(panel, "modulate:a", 1.0, IN_S * 0.7)
	tw.tween_property(panel, "scale", Vector2.ONE, IN_S).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(panel, "position:y", _target_y(panel), IN_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	get_tree().create_timer(LIFE_S).timeout.connect(_dismiss.bind(panel))


func _dismiss(panel: Control) -> void:
	if not is_instance_valid(panel) or not _toasts.has(panel):
		return
	_toasts.erase(panel)
	var tw := panel.create_tween().set_parallel(true)
	tw.tween_property(panel, "modulate:a", 0.0, OUT_S)
	tw.tween_property(panel, "position:y", panel.position.y - 16.0, OUT_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_property(panel, "scale", Vector2(0.94, 0.94), OUT_S)
	tw.chain().tween_callback(panel.queue_free)
	_layout()


func _target_y(panel: Control) -> float:
	var y := 0.0
	for p in _toasts:
		if p == panel:
			return y
		y += p.size.y + GAP
	return y


## Glides every live toast to its slot, centred horizontally.
func _layout() -> void:
	var y := 0.0
	for p in _toasts:
		var x := (size.x - p.size.x) * 0.5
		p.position.x = x
		if absf(p.position.y - y) > 0.5 and p.modulate.a > 0.0:
			p.create_tween().tween_property(p, "position:y", y, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		elif p.modulate.a <= 0.0:
			p.position.y = y
		y += p.size.y + GAP


## A small faceted gem in the toast's colour.
class _Gem:
	extends Control
	var color: Color = Color.WHITE

	func _init() -> void:
		custom_minimum_size = Vector2(12, 14)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := 5.5
		draw_colored_polygon(PackedVector2Array([c + Vector2(0, -r - 1.2), c + Vector2(r + 1.2, 0), c + Vector2(0, r + 1.2), c + Vector2(-r - 1.2, 0)]), Color(0, 0, 0, 0.6))
		var pts := PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)])
		draw_polygon(pts, PackedColorArray([color.lightened(0.45), color, color.darkened(0.35), color.lightened(0.1)]))
