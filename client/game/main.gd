class_name GameMain
extends Node
## Main scene: the 3D town (WorldView), the RTS camera, input and the HUD around one offline
## town. The simulation itself lives in the Game autoload.
##
## The camera sees the world through the space between the HUD's top bar and bottom panel
## (world_rect()): when a town starts it frames the Keep and the townsfolk around it there, at
## any window size or DPI, and focus jumps land in the middle of it. When a wall ring rises the
## camera glides out to show it, then back.
##
## Debug options after "--" (offline towns only; ages otherwise come from the Town Hall):
##   --age=<1..4>                    start at that age (its walls standing)
##   --advance-age-after=<seconds>   advance one age after that long (watch a wall rise)
##   --capture=<png path>            save a screenshot of the startup after two seconds and quit

## When false the scene waits for someone else (a tool, a test) to call Game.new_town().
@export var autostart: bool = true

## Townsfolk this close to the Keep are part of the opening view.
const OPENING_RADIUS := 14.0
## The opening view zooms out no further than this to fit everything.
const OPENING_MAX_DISTANCE := 48.0
## Window size changes this soon after a town starts re-frame the opening view (unless the
## player has moved the camera), so a window that maximises late still opens on the Keep.
const REFRAME_FOR_MS := 4000
## How tall the walls stand, for framing a ring while it rises.
const WALL_FRAME_HEIGHT := 5.5
const WALL_FRAME_OUT := 2.5

var world_view: WorldView
var camera: RtsCamera
var selection: Selection
var input: RtsInput
var hud: Hud

var _started_ms: int = 0


func _ready() -> void:
	world_view = WorldView.new()
	world_view.name = "World"
	add_child(world_view)
	camera = RtsCamera.new()
	camera.name = "RtsCamera"
	add_child(camera)
	camera.safe_rect_provider = world_rect
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
	world_view.wall_rise_started.connect(_on_wall_rise_started)
	get_viewport().size_changed.connect(_on_viewport_resized)
	Game.world_started.connect(_on_world_started)
	Game.link.plot_needed.connect(_on_plot_needed)
	if Game.world != null:
		_on_world_started(Game.world)
	elif autostart:
		Game.boot(int(Settings.get_value("game/seed", 4127)))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--capture="):
			_capture_and_quit(a.substr(10))


## The part of the screen the world is seen through: between the HUD's top bar and its bottom
## panel (the whole window while the HUD is hidden), in viewport coordinates.
func world_rect() -> Rect2:
	var full := get_viewport().get_visible_rect()
	if hud == null or not hud.visible or hud.top_bar == null or hud.bottom == null:
		return full
	var top := full.position.y
	var bottom := full.end.y
	if hud.top_bar.visible:
		top = maxf(top, hud.top_bar.get_global_rect().end.y)
	if hud.bottom.visible:
		bottom = minf(bottom, hud.bottom.get_global_rect().position.y)
	if bottom - top < 64.0:
		return full
	return Rect2(full.position.x, top, full.size.x, bottom - top)


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


## A newly trained agent needs a plot: select it and start placing, unless the player is busy
## placing something else.
func _on_plot_needed(agent_id: String) -> void:
	if input.mode != RtsInput.Mode.SELECT or hud.has_window():
		return
	input.focus_agent(agent_id)
	input.begin_plot_placement(agent_id)


func _on_world_started(w: SimWorld) -> void:
	world_view.bind(w)
	hud.bind_world(w)
	camera.map_size = float(w.grid.size)
	var k := w.keep()
	var c := k.center() if k != null else w.map_center()
	camera.set_view(Vector3(c.x, 0.0, c.y + 1.5), RtsCamera.DEFAULT_DISTANCE, 0.0)
	_started_ms = Time.get_ticks_msec()
	frame_town()
	_frame_after_layout.call_deferred()
	_apply_debug_age(w)


## Frames the Keep (up to its Font) and the townsfolk around it in the visible area.
func frame_town() -> void:
	var w := Game.world
	if w == null:
		return
	var k := w.keep()
	var c := k.center() if k != null else w.map_center()
	var pts := PackedVector3Array()
	if k != null:
		var r := k.rect()
		for corner: Vector2 in [Vector2(r.position), Vector2(r.end.x, r.position.y), Vector2(r.end), Vector2(r.position.x, r.end.y)]:
			pts.append(Vector3(corner.x, 0.0, corner.y))
		pts.append(Vector3(c.x, ModelLibrary.building_height("keep") + 1.4, c.y))
	else:
		pts.append(Vector3(c.x, 0.0, c.y))
	for u: SimUnit in w.units.values():
		if u.kind == "townsfolk" and u.pos.distance_to(c) <= OPENING_RADIUS:
			pts.append(Vector3(u.pos.x, 0.0, u.pos.y))
			pts.append(Vector3(u.pos.x, 1.1, u.pos.y))
	camera.frame(pts, RtsCamera.DEFAULT_DISTANCE, 0.06, true, OPENING_MAX_DISTANCE, 0.0)


## Frames again once the HUD has its final size (its panels lay out over the first frames).
func _frame_after_layout() -> void:
	for i in 2:
		await get_tree().process_frame
	if not camera.user_moved_since_frame and Game.world != null:
		frame_town()


func _on_viewport_resized() -> void:
	if Game.world == null or camera.user_moved_since_frame:
		return
	if Time.get_ticks_msec() - _started_ms > REFRAME_FOR_MS:
		return
	_frame_after_layout.call_deferred()


func _on_wall_rise_started(_ring: int, center: Vector3, radius: float, seconds: float) -> void:
	# The towers stand a little outside the ring's line.
	camera.frame_ring(center, radius + WALL_FRAME_OUT, seconds, WALL_FRAME_HEIGHT)


## `--age=N` starts an offline town at that age; `--advance-age-after=S` advances it one age
## after S seconds. Ages need the Town Hall otherwise.
func _apply_debug_age(w: SimWorld) -> void:
	if Game.is_online_town():
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--age="):
			w.allow_debug_commands = true
			Game.issue(GameCommands.debug_set_age(int(a.substr(6))))
		elif a.begins_with("--advance-age-after="):
			w.allow_debug_commands = true
			_advance_age_later(w, float(a.substr(20)))


func _advance_age_later(w: SimWorld, seconds: float) -> void:
	await get_tree().create_timer(maxf(seconds, 0.1)).timeout
	if Game.world == w:
		Game.issue(GameCommands.debug_set_age(w.age + 1))
