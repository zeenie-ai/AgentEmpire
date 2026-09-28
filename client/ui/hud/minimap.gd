class_name Minimap
extends Control
## 128x128 minimap image, refreshed about twice a second: terrain and resources (redrawn when
## the grid changes), buildings, units, the build zone and the camera's view. Left-click or drag
## to move the camera; right-click to give the selection an order there.

const REFRESH_S := 0.5
const COL_GRASS := Color("#7d8b4f")
const COL_TREE := Color("#3f5a2e")
const COL_BUSH := Color("#b8324a")
const COL_STUMP := Color("#8a7a4a")
const COL_ROCK := Color("#8a8f86")
const COL_BUILDING := Color("#e8d8b0")
const COL_SITE := Color("#b99a6a")
const COL_KEEP := Color("#ffd27a")
const COL_UNIT := Color("#ffffff")
const COL_SELECTED := Color("#a9f0d0")

var camera: RtsCamera
var input: RtsInput
var selection: Selection

var _world: SimWorld
var _base: Image
var _img: Image
var _tex: ImageTexture
var _base_dirty: bool = true
var _timer: float = 0.0
var _dragging: bool = false


func _init() -> void:
	custom_minimum_size = Vector2(190, 190)
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = ""


func bind(w: SimWorld) -> void:
	_world = w
	var n := w.grid.size
	_base = Image.create(n, n, false, Image.FORMAT_RGBA8)
	_img = Image.create(n, n, false, Image.FORMAT_RGBA8)
	_tex = ImageTexture.create_from_image(_img)
	_base_dirty = true
	w.grid_changed.connect(func(_r: Rect2i) -> void: _base_dirty = true)
	_timer = 0.0


func _process(delta: float) -> void:
	if _world == null or Game.world != _world:
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = REFRESH_S
		_refresh()
	queue_redraw()


func _refresh() -> void:
	var w := _world
	if _base_dirty:
		_base_dirty = false
		_base.fill(COL_GRASS)
		for c in w.rocks:
			_base.set_pixel(c.x, c.y, COL_ROCK)
		for node: SimResourceNode in w.nodes.values():
			var col := COL_STUMP if node.depleted else (COL_TREE if node.kind == "tree" else COL_BUSH)
			_base.set_pixel(node.cell.x, node.cell.y, col)
	_img.copy_from(_base)
	var sel := selection.ids if selection != null else []
	for b: SimBuilding in w.buildings.values():
		var col := COL_KEEP if b.id == w.keep_id else (COL_BUILDING if b.complete else COL_SITE)
		if b.id in sel:
			col = COL_SELECTED
		_img.fill_rect(b.rect(), col)
	for u: SimUnit in w.units.values():
		var c := u.cell()
		if w.grid.in_bounds(c):
			_img.set_pixelv(c, COL_SELECTED if u.id in sel else COL_UNIT)
	_tex.update(_img)


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, UiTokens.HUD_INSET)
	if _world == null or _tex == null:
		return
	draw_texture_rect(_tex, r, false)
	var n := float(_world.grid.size)
	var k := size / n
	var c := _world.map_center() * k
	draw_arc(c, float(_world.build_radius()) * k.x, 0.0, TAU, 64, Color(UiTokens.GOLD, 0.55), 1.0, true)
	if camera != null:
		var pts := PackedVector2Array()
		for g in camera.ground_corners():
			pts.append(Vector2(clampf(g.x, -8.0, n + 8.0), clampf(g.z, -8.0, n + 8.0)) * k)
		pts.append(pts[0])
		draw_polyline(pts, Color(1, 1, 1, 0.9), 1.2, true)
	draw_rect(r, UiTokens.HUD_BORDER, false, 1.0)


func _cell_at(p: Vector2) -> Vector2i:
	var n := _world.grid.size
	var t := (p / size) * float(n)
	return Vector2i(clampi(floori(t.x), 0, n - 1), clampi(floori(t.y), 0, n - 1))


func _gui_input(event: InputEvent) -> void:
	if _world == null:
		return
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if mb.pressed:
				_jump(mb.position)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if input != null:
				input.right_click_cell(_cell_at(mb.position))
			accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm != null and _dragging:
		_jump(mm.position)
		accept_event()


func _jump(p: Vector2) -> void:
	if camera == null:
		return
	var c := _cell_at(p)
	camera.focus(Vector3(c.x + 0.5, 0.0, c.y + 0.5), true)
