class_name RtsInput
extends Node
## Mouse and keyboard in the world.
## - Left-click selects (Shift adds or removes); dragging past 6 px draws a selection box;
##   double-click selects everything of that type on screen.
## - Ctrl+1..9 assigns a control group, 1..9 recalls it, a double tap centres the camera.
## - Right-click resolves through RightClickRules (move, gather, build, deposit, rally).
## - The command card (card_0..card_14 = Q..B), "." cycles idle townsfolk, H selects the Keep.
## - Building placement shows a validated ghost with the reason when a spot is invalid.
## Everything that changes the game goes out as a GameCommands command via Game.issue().

## Emitted when the placement/rally hint changes (text "" hides it).
signal hint_changed(text: String, ok: bool)

enum Mode { SELECT, PLACE, RALLY }

const DRAG_PX := 6.0
const GROUP_DOUBLE_TAP_S := 0.4
const HOVER_EVERY_S := 0.06
const RECHECK_EVERY_S := 0.25

var view: WorldView
var camera: RtsCamera
var selection: Selection
var hud: Hud

var mode: Mode = Mode.SELECT
var place_type: String = ""
var place_cell: Vector2i = Pathing.NO_CELL
var place_check: Dictionary = {}

var _pressing: bool = false
var _dragging: bool = false
var _double: bool = false
var _press_pos: Vector2 = Vector2.ZERO
var _last_group: int = 0
var _last_group_time: float = -10.0
var _idle_cursor: int = 0
var _hover_timer: float = 0.0
var _recheck_timer: float = 0.0


func setup(world_view: WorldView, rts_camera: RtsCamera, sel: Selection, hud_layer: Hud) -> void:
	view = world_view
	camera = rts_camera
	selection = sel
	hud = hud_layer
	Game.world_started.connect(_on_world_started)
	if Game.world != null:
		_on_world_started(Game.world)


func world() -> SimWorld:
	return Game.world


func _on_world_started(w: SimWorld) -> void:
	cancel_mode()
	selection.clear()
	_idle_cursor = 0
	w.entity_removed.connect(func(_id: int, _cat: String) -> void: selection.prune(w))


# --- events ---------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if world() == null:
		return
	var mb := event as InputEventMouseButton
	if mb != null:
		_mouse_button(mb)
		return
	var mm := event as InputEventMouseMotion
	if mm != null:
		_mouse_motion(mm)
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		_key(key)


func _mouse_button(e: InputEventMouseButton) -> void:
	match e.button_index:
		MOUSE_BUTTON_LEFT:
			if e.pressed:
				if mode == Mode.PLACE:
					_try_place(e.shift_pressed)
					get_viewport().set_input_as_handled()
					return
				if mode == Mode.RALLY:
					_rally_at(e.position)
					cancel_mode()
					get_viewport().set_input_as_handled()
					return
				_pressing = true
				_dragging = false
				_double = e.double_click
				_press_pos = e.position
			elif _pressing:
				_pressing = false
				if _dragging:
					_dragging = false
					hud.set_box(Rect2())
					_box_select(Rect2(_press_pos, e.position - _press_pos).abs(), e.shift_pressed)
				else:
					_click_select(e.position, e.shift_pressed, _double)
				get_viewport().set_input_as_handled()
		MOUSE_BUTTON_RIGHT:
			if e.pressed:
				if mode != Mode.SELECT:
					cancel_mode()
				else:
					right_click_at(e.position)
				get_viewport().set_input_as_handled()


func _mouse_motion(e: InputEventMouseMotion) -> void:
	if _pressing and not _dragging and e.position.distance_to(_press_pos) > DRAG_PX:
		_dragging = true
	if _dragging:
		hud.set_box(Rect2(_press_pos, e.position - _press_pos).abs())
	if mode == Mode.PLACE:
		_update_ghost(e.position)


func _key(e: InputEventKey) -> void:
	var w := world()
	if e.is_action("cancel"):
		if mode != Mode.SELECT:
			cancel_mode()
		else:
			selection.clear()
	elif e.is_action("select_idle"):
		select_next_idle()
	elif e.is_action("select_keep"):
		select_keep()
	elif e.is_action("toggle_night"):
		view.environment_view.fade_night(0.0 if view.environment_view.night > 0.5 else 1.0)
	elif e.is_action("toggle_fps"):
		hud.toggle_fps()
	elif e.is_action("quick_save"):
		Game.save_offline()
	elif e.is_action("quick_load"):
		Game.load_offline()
	elif e.is_action("pause"):
		Game.paused = not Game.paused
		Notify.push("Paused." if Game.paused else "Resumed.", "info", "pause", 0)
	elif e.is_action("delete"):
		var b := selection.single_building(w)
		if b != null and not b.complete:
			Game.issue(GameCommands.cancel_site(b.id))
		elif b != null and not b.queue.is_empty():
			Game.issue(GameCommands.cancel_train(b.id, -1))
	else:
		for n in range(1, 10):
			if e.is_action(InputActions.group_action(n)):
				_group_key(n, e.ctrl_pressed)
				get_viewport().set_input_as_handled()
				return
		if e.ctrl_pressed or e.alt_pressed or e.meta_pressed:
			return
		for i in InputActions.CARD_SLOTS:
			if e.is_action(InputActions.card_action(i)):
				execute_slot(i)
				break
		return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	var w := world()
	if w == null:
		return
	_hover_timer -= delta
	if _hover_timer <= 0.0:
		_hover_timer = HOVER_EVERY_S
		_update_hover()
	if mode == Mode.PLACE:
		_recheck_timer -= delta
		if _recheck_timer <= 0.0:
			_recheck_timer = RECHECK_EVERY_S
			if place_cell != Pathing.NO_CELL:
				_set_check(Placement.check(w, place_type, place_cell))


# --- selection ------------------------------------------------------------------------------

func _click_select(pos: Vector2, shift: bool, double: bool) -> void:
	var w := world()
	var hit := Picking.pick(w, view, camera.camera, pos)
	var kind := String(hit["kind"])
	var id := int(hit["id"])
	if kind == "unit" or kind == "building":
		if double:
			selection.set_ids(Picking.same_kind_on_screen(w, view, camera.camera, id))
		elif shift and _same_category(id):
			selection.toggle(id)
		else:
			selection.set_ids([id])
	elif kind == "node":
		if not shift:
			selection.set_ids([id])
	elif not shift:
		selection.clear()


## Shift-click only mixes entities of the same category (units with units).
func _same_category(id: int) -> bool:
	var w := world()
	if selection.is_empty():
		return true
	return w.category_of(selection.ids[0]) == w.category_of(id)


func _box_select(rect: Rect2, shift: bool) -> void:
	var w := world()
	var ids := Picking.units_in_rect(w, view, camera.camera, rect)
	if shift:
		if not selection.is_empty() and w.category_of(selection.ids[0]) != SimWorld.CAT_UNIT:
			selection.set_ids(ids)
		else:
			selection.add(ids)
	elif not ids.is_empty():
		selection.set_ids(ids)
	else:
		selection.clear()


func select_next_idle() -> void:
	var w := world()
	var idle := w.idle_townsfolk()
	if idle.is_empty():
		Notify.push("No idle townsfolk.", "info", "no_idle", 1200)
		return
	var next := idle[0]
	for id in idle:
		if id > _idle_cursor:
			next = id
			break
	_idle_cursor = next
	selection.set_ids([next])
	camera.focus(view.unit_visual_position(next))


func select_keep() -> void:
	var k := world().keep()
	if k == null:
		return
	selection.set_ids([k.id])
	camera.focus(Vector3(k.center().x, 0.0, k.center().y))


func _group_key(n: int, assign: bool) -> void:
	if assign:
		if selection.is_empty():
			return
		selection.assign_group(n)
		Notify.push("Group %d set." % n, "info", "group", 300)
		return
	var members := selection.recall_group(n, world())
	if members.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _last_group == n and now - _last_group_time < GROUP_DOUBLE_TAP_S:
		camera.focus(_centroid(members))
	_last_group = n
	_last_group_time = now


func _centroid(ids: Array[int]) -> Vector3:
	var w := world()
	var sum := Vector3.ZERO
	for id in ids:
		if w.units.has(id):
			sum += view.unit_visual_position(id)
		elif w.buildings.has(id):
			var c: Vector2 = (w.buildings[id] as SimBuilding).center()
			sum += Vector3(c.x, 0, c.y)
	return sum / float(maxi(ids.size(), 1))


func _update_hover() -> void:
	var w := world()
	if mode != Mode.SELECT or get_viewport().gui_get_hovered_control() != null:
		view.hover_id = 0
		return
	var hit := Picking.pick(w, view, camera.camera, get_viewport().get_mouse_position())
	view.hover_id = int(hit["id"]) if String(hit["kind"]) in ["unit", "building", "node"] else 0


# --- orders -----------------------------------------------------------------------------------

func right_click_at(pos: Vector2) -> void:
	var w := world()
	if selection.is_empty():
		return
	var target := Picking.pick(w, view, camera.camera, pos)
	if String(target["kind"]) == "none":
		return
	_order(target)


## Right-click on the minimap: an order to a ground cell.
func right_click_cell(cell: Vector2i) -> void:
	if world() == null or selection.is_empty():
		return
	_order({"kind": "ground", "id": 0, "cell": cell})


func _order(target: Dictionary) -> void:
	var w := world()
	var ctx := RightClickRules.context_for(w, selection.ids, target)
	var action := RightClickRules.resolve(ctx)
	var cmd := RightClickRules.command_for(w, selection.ids, target, action)
	if cmd.is_empty():
		return
	Game.issue(cmd)
	var cell: Vector2i = target["cell"]
	view.ping(cell, action)


func execute_slot(i: int) -> void:
	var w := world()
	if w == null:
		return
	var slots := CommandCardModel.slots(w, selection.ids)
	if i >= 0 and i < slots.size() and not slots[i].is_empty():
		activate(slots[i])


func activate(slot: Dictionary) -> void:
	var w := world()
	var id := String(slot.get("id", ""))
	var b := selection.single_building(w)
	if id.begins_with("build:"):
		var t := id.substr(6)
		var missing := w.ledger.missing(w.econ.building_cost(t))
		if not missing.is_empty():
			Notify.push("Need %s more." % Placement.format_cost(missing), "warn", "not_enough", 800)
			return
		begin_placement(t)
	elif id == "stop":
		Game.issue(GameCommands.stop(selection.units(w)))
	elif id == "return":
		_return_goods()
	elif id == "auto_gather":
		Game.issue(GameCommands.auto_gather(selection.units(w)))
	elif id.begins_with("train:") and b != null:
		Game.issue(GameCommands.train(b.id, id.substr(6)))
	elif id == "summon":
		Notify.push("Summoning agents needs the Town Hall. It arrives in the next phase.", "info", "summon", 1500)
	elif id == "rally" and b != null:
		mode = Mode.RALLY
		hint_changed.emit("Click to set the rally point. Right-click cancels.", true)
	elif id.begins_with("focus:") and b != null:
		Game.issue(GameCommands.set_gather_focus(b.id, id.substr(6)))
	elif id == "cancel_train" and b != null:
		Game.issue(GameCommands.cancel_train(b.id, -1))
	elif id == "cancel_site" and b != null:
		Game.issue(GameCommands.cancel_site(b.id))
	elif id == "dismantle" and b != null:
		Game.issue(GameCommands.dismantle(b.id))


func _return_goods() -> void:
	var w := world()
	var by_drop := {}
	for id in selection.units(w):
		var u: SimUnit = w.units[id]
		if not u.is_carrying():
			continue
		var d := w.nearest_dropoff(u.pos, u.carry_res)
		if d != null:
			if not by_drop.has(d.id):
				by_drop[d.id] = []
			(by_drop[d.id] as Array).append(id)
	for drop_id: int in by_drop:
		Game.issue(GameCommands.deposit(by_drop[drop_id], drop_id))


func _rally_at(pos: Vector2) -> void:
	var w := world()
	var b := selection.single_building(w)
	if b == null:
		return
	var target := Picking.pick(w, view, camera.camera, pos)
	if String(target["kind"]) == "none":
		return
	Game.issue(RightClickRules.command_for(w, [b.id], target, RightClickRules.ACTION_RALLY))


# --- placement --------------------------------------------------------------------------------

func begin_placement(type: String) -> void:
	var w := world()
	mode = Mode.PLACE
	place_type = type
	place_cell = Pathing.NO_CELL
	view.ghost.show_type(type, w.econ.building_footprint(type))
	_update_ghost(get_viewport().get_mouse_position())


func cancel_mode() -> void:
	mode = Mode.SELECT
	place_type = ""
	place_cell = Pathing.NO_CELL
	if view != null:
		view.ghost.clear()
	hint_changed.emit("", true)


func _update_ghost(screen: Vector2) -> void:
	var w := world()
	var g: Variant = camera.screen_to_ground(screen)
	var fp := w.econ.building_footprint(place_type)
	if g == null:
		view.ghost.visible = false
		return
	var gp: Vector3 = g
	var cell := Vector2i(floori(gp.x - fp.x * 0.5 + 0.5), floori(gp.z - fp.y * 0.5 + 0.5))
	if cell != place_cell:
		place_cell = cell
		_set_check(Placement.check(w, place_type, cell))
	view.ghost.visible = true
	view.ghost.place_at(place_cell, fp, bool(place_check.get("ok", false)))


func _set_check(check: Dictionary) -> void:
	place_check = check
	var w := world()
	var ok := bool(check.get("ok", false))
	var bname := w.econ.building_name(place_type)
	var text := "%s: click to place. Shift places more; right-click cancels." % bname if ok else "%s: %s" % [bname, String(check.get("reason", ""))]
	hint_changed.emit(text, ok)
	if view.ghost.visible and place_cell != Pathing.NO_CELL:
		view.ghost.place_at(place_cell, w.econ.building_footprint(place_type), ok)


func _try_place(keep_placing: bool) -> void:
	var w := world()
	if place_cell == Pathing.NO_CELL:
		return
	_set_check(Placement.check(w, place_type, place_cell))
	if not bool(place_check.get("ok", false)):
		Notify.push(String(place_check.get("reason", "Can't build there.")), "warn", "placement", 600)
		return
	Game.issue(GameCommands.place_building(selection.units(w), place_type, place_cell))
	view.ping(place_cell + w.econ.building_footprint(place_type) / 2, "build")
	if not keep_placing or not w.ledger.can_afford(w.econ.building_cost(place_type)):
		cancel_mode()
