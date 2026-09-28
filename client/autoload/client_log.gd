extends Node
## Client log (named ClientLog because Godot 4.5+ has a built-in Logger class). Prints to the
## console and keeps the most recent lines in memory for a future in-game log panel.

enum Level { DEBUG, INFO, WARN, ERROR }

const LEVEL_NAMES := ["DEBUG", "INFO", "WARN", "ERROR"]
const MAX_LINES := 500

var level: Level = Level.INFO
var lines: PackedStringArray = PackedStringArray()


func debug(tag: String, msg: String) -> void:
	_write(Level.DEBUG, tag, msg)


func info(tag: String, msg: String) -> void:
	_write(Level.INFO, tag, msg)


func warn(tag: String, msg: String) -> void:
	_write(Level.WARN, tag, msg)


func error(tag: String, msg: String) -> void:
	_write(Level.ERROR, tag, msg)


func _write(lv: Level, tag: String, msg: String) -> void:
	if lv < level:
		return
	var t := Time.get_time_dict_from_system()
	var line := "%02d:%02d:%02d %s [%s] %s" % [t.hour, t.minute, t.second, LEVEL_NAMES[lv], tag, msg]
	lines.append(line)
	if lines.size() > MAX_LINES:
		lines = lines.slice(lines.size() - MAX_LINES)
	if lv >= Level.WARN:
		printerr(line)
	else:
		print(line)
