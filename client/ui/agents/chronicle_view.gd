class_name ChronicleView
extends PanelContainer
## A task's Chronicle: its activity entries (local time, kind, text) on a dark slate, live from
## Realm.task_activity. It follows the newest entry unless the player has scrolled up, keeps the
## last `max_entries`, and ignores entries it already shows (so the get_task_detail history and
## the live feed can overlap).

const KINDS := {
	"message": ["SAYS", Color("#dfe8f7")],
	"tool_start": ["TOOL", Color("#ffd27a")],
	"tool_end": ["DONE", Color("#9fe6a8")],
	"error": ["ERROR", Color("#ff8a78")],
	"system": ["TOWN", Color("#8cc8ff")],
}

var task_id: String = ""
var max_entries: int = 200
var look: int = AgentTheme.DOCUMENT

var _scroll: ScrollContainer
var _list: VBoxContainer
var _empty: Label
var _seen: Dictionary = {}
var _follow: bool = true


func _init(view_look: int = AgentTheme.DOCUMENT) -> void:
	look = view_look
	theme = AgentTheme.theme(AgentTheme.STATUS)
	add_theme_stylebox_override("panel", AgentTheme.slate_box(look))
	custom_minimum_size = Vector2(0, 200)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 5)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)
	_empty = AgentUi.label("Nothing in the Chronicle yet.", "Hint", _list)
	_scroll.get_v_scroll_bar().changed.connect(_on_range_changed)
	_scroll.get_v_scroll_bar().value_changed.connect(_on_scrolled)


## Shows the task's history: `entries` (from get_task_detail) plus what Realm already holds.
func setup(id: String, entries: Array = []) -> ChronicleView:
	task_id = id
	add_entries(entries)
	add_entries(Realm.activity.get(id, []))
	return self


func _enter_tree() -> void:
	if not Realm.task_activity.is_connected(_on_activity):
		Realm.task_activity.connect(_on_activity)


func _exit_tree() -> void:
	if Realm.task_activity.is_connected(_on_activity):
		Realm.task_activity.disconnect(_on_activity)


func _on_activity(id: String, entry: Dictionary) -> void:
	if id == task_id:
		add_entry(entry)


func add_entries(entries: Array) -> void:
	var sorted: Array = entries.duplicate()
	sorted.sort_custom(func(a: Variant, b: Variant) -> bool: return J.gs(J.d(a), "time") < J.gs(J.d(b), "time"))
	for e: Variant in sorted:
		add_entry(J.d(e))


func add_entry(entry: Dictionary) -> void:
	if entry.is_empty():
		return
	var key := "%s|%s|%s" % [J.gs(entry, "time"), J.gs(entry, "kind"), J.gs(entry, "text").sha1_text()]
	if _seen.has(key):
		return
	_seen[key] = true
	_empty.visible = false
	_list.add_child(_row(entry))
	while _list.get_child_count() - 1 > max_entries:
		var old := _list.get_child(1)
		_list.remove_child(old)
		old.queue_free()


func entry_count() -> int:
	return _list.get_child_count() - 1


func _row(entry: Dictionary) -> Control:
	var kind := J.gs(entry, "kind", "system")
	var spec: Array = KINDS.get(kind, KINDS["system"])
	var col: Color = spec[1]
	var row := AgentUi.hbox(10)
	var time := AgentUi.label(AgentUi.local_clock(J.gs(entry, "time")), "MonoSmall", row)
	time.custom_minimum_size = Vector2(62, 0)
	time.add_theme_color_override("font_color", Color(0.56, 0.64, 0.78))
	time.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var tag := AgentUi.pill(String(spec[0]), col, false, row)
	tag.custom_minimum_size = Vector2(54, 0)
	tag.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	(tag.get_child(0) as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var text := AgentUi.para(J.gs(entry, "text"), "Body", row)
	var is_tool := kind == "tool_start" or kind == "tool_end"
	if is_tool:
		text.add_theme_font_override("font", UiFonts.mono(500, 0))
		text.add_theme_font_size_override("font_size", 12)
	else:
		text.add_theme_font_size_override("font_size", 14)
	text.add_theme_color_override("font_color", col if kind == "error" else (Color("#c9d7ee") if is_tool else Color("#e8eef8")))
	return row


func _on_scrolled(v: float) -> void:
	var bar := _scroll.get_v_scroll_bar()
	_follow = v >= bar.max_value - bar.page - 4.0


func _on_range_changed() -> void:
	if _follow:
		var bar := _scroll.get_v_scroll_bar()
		_scroll.scroll_vertical = int(bar.max_value)
