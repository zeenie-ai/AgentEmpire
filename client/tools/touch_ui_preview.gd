extends SceneTree
## Screenshots of the phone and tablet panels over a demo town, saved as out/touch_<shot>.png:
##   menu      the game menu
##   help      the touch help
##   card_tip  a command card held down (a long press shows its tip)
##   chip_tip  a top-bar chip's tip
##   hint      the placement hint
## Needs a real window, so do not pass --headless:
##   .tools/godot/Godot_v4.7.2-stable_win64_console.exe --path client -s res://tools/touch_ui_preview.gd -- --mobile --dpi=420 --size=2400x1080
## Options after "--": --out=<dir> --size=1600x900 --only=a,b --tag=<suffix>, and the game's own
## --mobile and --dpi=<n>. Without --mobile it takes the menu and the help on the desktop HUD.
##
## A script run with -s compiles before the autoloads exist, so everything that uses them (the
## HUD and its panels, Game) is loaded at run time and kept untyped here.

const DEFAULT_SIZE := Vector2i(1600, 900)
const SHOTS := ["menu", "help", "card_tip", "chip_tip", "hint"]
const TOUCH_ONLY := ["card_tip", "chip_tip", "hint"]

var _args: PackedStringArray
var _size: Vector2i = DEFAULT_SIZE
var _out: String = ""
var _tag: String = ""
var _main: Node
var _hud: Node
var _tip: GDScript


func _initialize() -> void:
	_args = OS.get_cmdline_user_args()
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	for a in _args:
		if a.begins_with("--%s=" % name):
			return a.get_slice("=", 1)
	return fallback


func _wanted(shot: String) -> bool:
	var only := _arg("only", "")
	return only == "" or shot in only.split(",")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("touch_ui_preview needs a real window: run it without --headless.")
		quit(2)
		return
	var sz := _arg("size", "%dx%d" % [DEFAULT_SIZE.x, DEFAULT_SIZE.y]).split("x")
	_size = Vector2i(int(sz[0]), int(sz[1]))
	_tag = _arg("tag", "")
	_out = _arg("out", ProjectSettings.globalize_path("res://").path_join("../out").simplify_path())
	DirAccess.make_dir_recursive_absolute(_out)
	_tip = load("res://ui/widgets/touch_tip.gd")
	await _fix_window()
	await _start_town()
	var mobile: bool = load("res://game/platform.gd").call("is_mobile")
	for shot: String in SHOTS:
		if _wanted(shot) and (mobile or not shot in TOUCH_ONLY):
			await _take(shot)
	quit(0)


func _start_town() -> void:
	_main = load("res://game/main.tscn").instantiate()
	_main.set("autostart", false)
	root.add_child(_main)
	await process_frame
	_hud = _main.get("hud")
	var game := root.get_node("Game")
	game.set("paused", true)
	var w: Variant = game.call("new_town", 4127, "demo")
	load("res://tools/demo_town.gd").call("build", w, 12, 70.0)
	var camera: Variant = _main.get("camera")
	camera.set("input_enabled", false)
	var c: Vector2 = w.call("keep").call("center")
	camera.call("set_view", Vector3(c.x + 2.0, 0.0, c.y + 2.5), 29.0, deg_to_rad(-20.0))
	game.set("paused", false)
	await _frames(30)


func _take(shot: String) -> void:
	match shot:
		"menu":
			_hud.call("open_game_menu")
			await _snap(shot)
			_hud.call("close_window")
		"help":
			_hud.call("open_window", load("res://ui/hud/help_panel.gd").new())
			await _snap(shot)
			_hud.call("close_window")
		"card_tip":
			await _shot_card_tip()
		"chip_tip":
			var chips: Dictionary = _hud.get("top_bar").get("_chips")
			_tip.call("show_for", chips["wood"])
			await _snap(shot)
			_tip.call("dismiss")
		"hint":
			# The builders selected, and the ghost in the middle of the view, where a touch
			# placement starts.
			await _select_townsfolk()
			var input: Variant = _main.get("input")
			input.call("begin_placement", "cottage")
			var band: Rect2 = _hud.call("world_rect")
			input.call("_update_ghost", band.get_center())
			await _snap(shot)
			input.call("cancel_mode")
			_main.get("selection").call("clear")
	await _frames(4)


func _select_townsfolk() -> void:
	var w: Variant = root.get_node("Game").get("world")
	var ids: Array = []
	for u: Variant in w.get("units").values():
		if String(u.get("kind")) == "townsfolk":
			ids.append(u.get("id"))
	_main.get("selection").call("set_ids", ids)
	await _frames(10)


## Selects the townsfolk and holds a finger on the Cottage card past the long-press time.
func _shot_card_tip() -> void:
	await _select_townsfolk()
	var card: Control = null
	for b: Node in _hud.get("bottom").get("command_card").get_children():
		var slot: Dictionary = b.get("slot")
		if String(slot.get("id", "")) == "build:cottage":
			card = b
	if card == null:
		printerr("touch_ui_preview: no Cottage card")
		return
	card.notification(Control.NOTIFICATION_MOUSE_ENTER)
	_push_press(card, true)
	await create_timer(0.6).timeout
	_push_press(card, false)
	if not _tip.call("showing"):
		printerr("touch_ui_preview: the long press showed no tip")
	await _snap("card_tip")
	_tip.call("dismiss")
	_main.get("selection").call("clear")


func _push_press(c: Control, down: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = down
	e.position = c.get_global_rect().get_center()
	e.global_position = e.position
	root.push_input(e, true)


func _frames(n: int) -> void:
	for i in n:
		_hold_window()
		await process_frame


func _snap(name: String, frames: int = 30) -> void:
	var img: Image = null
	for attempt in 4:
		await _frames(frames)
		img = root.get_viewport().get_texture().get_image()
		if img.get_size() == _size:
			break
		frames = 12
	var path := _out.path_join("touch_%s%s.png" % [name, ("_" + _tag) if _tag != "" else ""])
	var err := img.save_png(path)
	print("touch_ui_preview: %s %dx%d %s" % [path, img.get_width(), img.get_height(), "ok" if err == OK else "error %d" % err])


func _fix_window() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(_size)
	for i in 3:
		await process_frame


func _hold_window() -> void:
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if DisplayServer.window_get_size() != _size:
		DisplayServer.window_set_size(_size)
