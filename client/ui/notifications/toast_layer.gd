class_name ToastLayer
extends VBoxContainer
## Toast notifications from Notify, stacked under the top bar in navy status windows. The
## border colour follows the kind: mint (info, good), amber (warn), red (error).

const LIFE_S := 3.6
const FADE_S := 0.5
const MAX_TOASTS := 5


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 6)
	alignment = BoxContainer.ALIGNMENT_BEGIN
	Notify.toast.connect(show_toast)


func show_toast(text: String, kind: String) -> void:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.theme_type_variation = "StatusPanel"
	var border := UiTokens.MINT
	match kind:
		"warn":
			border = UiTokens.WARN
		"error":
			border = UiTokens.BAD
		"good":
			border = UiTokens.GOLD_BRIGHT
	panel.add_theme_stylebox_override("panel", ThemeBuilder.status_box(border))
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var label := Label.new()
	label.theme_type_variation = "StatusLabel"
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)
	add_child(panel)
	while get_child_count() > MAX_TOASTS:
		var old := get_child(0)
		remove_child(old)
		old.queue_free()
	var tw := panel.create_tween()
	tw.tween_interval(LIFE_S)
	tw.tween_property(panel, "modulate:a", 0.0, FADE_S)
	tw.tween_callback(panel.queue_free)
