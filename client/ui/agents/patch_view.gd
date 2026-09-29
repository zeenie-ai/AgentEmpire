class_name PatchView
extends TextEdit
## A read-only unified diff on a dark slate: added lines green, removed lines red, hunk headers
## blue and file headers gold, each with a tinted line background. Large patches stay fast
## (TextEdit draws only the visible lines). jump_to_file(path) scrolls to a file's header.

const ADD := Color("#9fe6a8")
const DEL := Color("#ff9a8a")
const HUNK := Color("#8cc8ff")
const FILE := Color("#ffd27a")
const META := Color("#8fa0b8")
const PLAIN := Color("#d8dfea")

## path -> first line of that file's section.
var file_lines: Dictionary = {}


func _init(look: int = AgentTheme.DOCUMENT) -> void:
	editable = false
	context_menu_enabled = true
	selecting_enabled = true
	shortcut_keys_enabled = true
	wrap_mode = TextEdit.LINE_WRAPPING_NONE
	scroll_past_end_of_file = false
	highlight_current_line = false
	caret_blink = false
	add_theme_font_override("font", UiFonts.mono(500, 0))
	add_theme_font_size_override("font_size", 12)
	add_theme_constant_override("line_spacing", 3)
	var slate := AgentTheme.slate_box(look)
	slate.content_margin_left = 12
	add_theme_stylebox_override("normal", slate)
	add_theme_stylebox_override("read_only", slate)
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	add_theme_color_override("font_readonly_color", PLAIN)
	add_theme_color_override("font_color", PLAIN)
	add_theme_color_override("selection_color", Color(UiTokens.MINT, 0.22))
	add_theme_color_override("current_line_color", Color(0, 0, 0, 0))
	add_theme_color_override("background_color", Color(0, 0, 0, 0))
	syntax_highlighter = DiffHighlighter.new()
	placeholder_text = "No changes to show."


func set_patch(patch: String) -> void:
	text = patch
	file_lines.clear()
	var path := ""
	for i in get_line_count():
		var line := get_line(i)
		var bg := Color(0, 0, 0, 0)
		if line.begins_with("diff --git "):
			bg = Color(FILE, 0.1)
			path = _path_of(line)
			if path != "" and not file_lines.has(path):
				file_lines[path] = i
		elif line.begins_with("+++ ") or line.begins_with("--- "):
			bg = Color(FILE, 0.05)
			if line.begins_with("+++ ") and path == "":
				var p := line.substr(4).trim_prefix("b/")
				if not file_lines.has(p):
					file_lines[p] = i
		elif line.begins_with("@@"):
			bg = Color(HUNK, 0.1)
		elif line.begins_with("+"):
			bg = Color(ADD, 0.1)
		elif line.begins_with("-"):
			bg = Color(DEL, 0.1)
		set_line_background_color(i, bg)
	set_v_scroll(0)


## "diff --git a/src/x.ts b/src/x.ts" -> "src/x.ts"
static func _path_of(header: String) -> String:
	var at := header.rfind(" b/")
	if at >= 0:
		return header.substr(at + 3)
	var parts := header.split(" ")
	return parts[parts.size() - 1] if parts.size() > 0 else ""


## Scrolls to a file's section; false when the patch has none for `path`.
func jump_to_file(path: String) -> bool:
	if not file_lines.has(path):
		return false
	var line := int(file_lines[path])
	set_v_scroll(line)
	set_caret_line(line, false)
	return true


class DiffHighlighter:
	extends SyntaxHighlighter

	func _get_line_syntax_highlighting(line: int) -> Dictionary:
		var te := get_text_edit()
		if te == null:
			return {}
		var s := te.get_line(line)
		var col := PatchView.PLAIN
		if s.begins_with("diff --git ") or s.begins_with("+++ ") or s.begins_with("--- "):
			col = PatchView.FILE
		elif s.begins_with("@@"):
			col = PatchView.HUNK
		elif s.begins_with("+"):
			col = PatchView.ADD
		elif s.begins_with("-"):
			col = PatchView.DEL
		elif s.begins_with("index ") or s.begins_with("new file") or s.begins_with("deleted file") or s.begins_with("similarity") or s.begins_with("rename ") or s.begins_with("\\"):
			col = PatchView.META
		return {0: {"color": col}}
