class_name GameMain
extends Node
## Main scene: the 3D town (WorldView), the RTS camera, input and the HUD around one offline
## town. The simulation itself lives in the Game autoload.

## When false the scene waits for someone else (a tool, a test) to call Game.new_town().
@export var autostart: bool = true

var world_view: WorldView
var camera: RtsCamera
var selection: Selection
var input: RtsInput
var hud: Hud


func _ready() -> void:
	world_view = WorldView.new()
	world_view.name = "World"
	add_child(world_view)
	camera = RtsCamera.new()
	camera.name = "RtsCamera"
	add_child(camera)
	selection = Selection.new()
	world_view.selection = selection
	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)
	input = RtsInput.new()
	input.name = "RtsInput"
	add_child(input)
	input.setup(world_view, camera, selection, hud)
	hud.setup(world_view, camera, selection, input)
	Game.world_started.connect(_on_world_started)
	if Game.world != null:
		_on_world_started(Game.world)
	elif autostart:
		Game.new_town(int(Settings.get_value("game/seed", 4127)))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--capture="):
			_capture_and_quit(a.substr(10))


## Debug aid: `-- --capture=<png path>` saves a screenshot of the normal startup after two
## seconds and quits, so the real game path can be checked from the command line.
func _capture_and_quit(path: String) -> void:
	await get_tree().create_timer(2.0).timeout
	for i in 5:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("capture: %s %dx%d %s" % [path, img.get_width(), img.get_height(), "ok" if err == OK else "error %d" % err])
	get_tree().quit()


func _on_world_started(w: SimWorld) -> void:
	world_view.bind(w)
	hud.bind_world(w)
	camera.map_size = float(w.grid.size)
	var k := w.keep()
	var c := k.center() if k != null else w.map_center()
	camera.set_view(Vector3(c.x, 0.0, c.y + 1.5), 30.0, 0.0)
