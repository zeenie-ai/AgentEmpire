class_name RtsInput
extends Node
## Mouse and keyboard in the world.
## - Left-click selects (Shift adds or removes); dragging past 6 px draws a selection box;
##   double-click selects everything of that type on screen.
## - Ctrl+1..9 assigns a control group, 1..9 recalls it, a double tap centres the camera.
## - Right-click resolves through RightClickRules (move, gather, build, deposit, rally).
## - The command card (card_0..card_14 = Q..B), "." cycles idle townsfolk, H selects the Keep.
## - Building placement shows a validated ghost with the reason when a spot is invalid; an
##   agent's plot (PLACE_PLOT) is placed the same way and goes to the Town Hall first.
## - Agents: their card offers tasks, review, approvals, add-ons; townsfolk right-clicked onto
##   an agent's home carry its scroll; Space jumps to the approval that has waited longest.
## Everything that changes the game goes out as a GameCommands command via Game.issue(), or
## through TownLink when the Town Hall must agree first.

## Emitted when the placement/rally hint changes (text "" hides it).
signal hint_changed(text: String, ok: bool)

enum Mode { SELECT, PLACE, RALLY, PLACE_PLOT }

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
## PLACE_PLOT: the agent whose plot is being chosen.
var place_agent_id: String = ""

var _plot_pending: bool = false
var _bell_cursor: int = 0

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
	if world() == null or (hud != null and hud.has_window()):
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
				if mode == Mode.PLACE_PLOT:
					_try_place_plot()
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
	elif mode == Mode.PLACE_PLOT:
		_update_plot_ghost(e.position)


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
	elif e.is_action("next_bell"):
		jump_to_next_bell()
	elif e.is_action("mana"):
		hud.open_budget()
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
	if mode == Mode.PLACE or mode == Mode.PLACE_PLOT:
		_recheck_timer -= delta
		if _recheck_timer <= 0.0:
			_recheck_timer = RECHECK_EVERY_S
			if place_cell != Pathing.NO_CELL:
				if mode == Mode.PLACE:
					_set_check(Placement.check(w, place_type, place_cell))
				else:
					_set_plot_check(Placement.check_plot(w, place_type, place_cell))


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
	if action == RightClickRules.ACTION_DELIVER:
		_deliver(target)
		return
	var cmd := RightClickRules.command_for(w, selection.ids, target, action)
	if cmd.is_empty():
		return
	Game.issue(cmd)
	var cell: Vector2i = target["cell"]
	view.ping(cell, action)


## Townsfolk right-clicked onto an agent's home carry its waiting scroll, or the next one.
func _deliver(target: Dictionary) -> void:
	var w := world()
	var b: SimBuilding = w.buildings.get(int(target.get("id", 0)))
	if b == null or b.owner_agent_id == "":
		return
	var units := selection.units(w)
	var cell: Vector2i = target["cell"]
	view.ping(cell, RightClickRules.ACTION_BUILD)
	if Game.link.manual_courier(units, b.owner_agent_id):
		Notify.push("Carrying the scroll to %s." % J.gs(Realm.agent(b.owner_agent_id), "name", "the agent"), "info", "deliver", 800)
	else:
		Notify.push("No scroll waits for %s. This townsperson will carry the next task you write." % J.gs(Realm.agent(b.owner_agent_id), "name", "the agent"), "info", "deliver", 800)
		hud.open_task_composer(b.owner_agent_id)


## The agent the selection is about: a selected agent figure, or a selected home or add-on.
func selected_agent_id() -> String:
	var w := world()
	if selection.is_empty():
		return ""
	var u: SimUnit = w.units.get(selection.ids[0])
	if u != null:
		return u.agent_id
	var b: SimBuilding = w.buildings.get(selection.ids[0])
	return b.owner_agent_id if b != null else ""


## Space: centres on the home of the agent whose approval has waited longest, then the next.
func jump_to_next_bell() -> void:
	var pending := Realm.pending_approvals()
	if pending.is_empty():
		Notify.push("No approvals are waiting.", "info", "no_bells", 1200)
		return
	_bell_cursor = _bell_cursor % pending.size()
	var agent_id := J.gs(pending[_bell_cursor], "agent_id")
	_bell_cursor += 1
	focus_agent(agent_id)
	hud.focus_approvals(agent_id)


## Selects an agent's home (or its figure while it has none) and centres the camera on it.
func focus_agent(agent_id: String) -> void:
	var w := world()
	var home := w.agent_home(agent_id)
	if home != null:
		selection.set_ids([home.id])
		camera.focus(Vector3(home.center().x, 0.0, home.center().y))
		return
	var u := w.agent_unit(agent_id)
	if u != null:
		selection.set_ids([u.id])
		camera.focus(view.unit_visual_position(u.id))


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
		if not bool(slot.get("enabled", false)):
			Notify.push(String(slot.get("tooltip", "")).get_slice("\n", 1), "info", "summon", 1500)
		else:
			hud.open_summon()
	elif id == "task":
		if bool(slot.get("enabled", false)):
			hud.open_task_composer(selected_agent_id())
		else:
			Notify.push(String(slot.get("tooltip", "")).get_slice("\n", 2), "info", "task", 1500)
	elif id == "review":
		if bool(slot.get("enabled", false)):
			hud.open_review_for_agent(selected_agent_id())
	elif id == "approvals":
		hud.focus_approvals(selected_agent_id())
	elif id == "place_home":
		begin_plot_placement(selected_agent_id())
	elif id.begins_with("add_tool:"):
		_add_tool(selected_agent_id(), id.substr(9), slot)
	elif id.begins_with("resume:"):
		_notify_result(Game.link.resume_task(id.substr(7)), "Resuming.")
	elif id.begins_with("cancel_task:"):
		_notify_result(Game.link.cancel_task(id.substr(12)), "Task cancelled.")
	elif id == "cancel_summon":
		Game.link.cancel_summon(selected_agent_id())
	elif id == "retire":
		hud.confirm("Retire %s?" % J.gs(Realm.agent(selected_agent_id()), "name", "this agent"),
			"They finish their current task first. Their home and add-ons leave with them.",
			_retire.bind(selected_agent_id()))
	elif id.begins_with("detach:"):
		_notify_result(Game.link.detach_tool(id.substr(7)), "Dismantled.")
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


func _add_tool(agent_id: String, type: String, slot: Dictionary) -> void:
	if not bool(slot.get("enabled", false)):
		var why := String(slot.get("tooltip", "")).get_slice("\n", 2)
		var missing := world().ledger.missing(world().econ.building_cost(type))
		Notify.push(why if why != "" else "Need %s more." % Placement.format_cost(missing), "warn", "add_tool", 800)
		return
	var req := Game.link.attach_tool(agent_id, type)
	if req != null:
		_notify_result(req, "%s will build the %s." % [J.gs(Realm.agent(agent_id), "name", "The agent"), world().econ.building_name(type)])


func _retire(agent_id: String) -> void:
	_notify_result(Game.link.retire_agent(agent_id), "%s will retire after their current task." % J.gs(Realm.agent(agent_id), "name", "The agent"))


## Toasts a request's outcome when it finishes.
func _notify_result(req: NetRequest, ok_text: String) -> void:
	if req == null:
		return
	await req.done
	if req.ok:
		Notify.push(ok_text, "good", "", 0)
	else:
		Notify.push(req.error_message(), "warn", "", 0)


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


## Chooses a plot for an agent's home: a 7x7 ghost with the home in its middle.
func begin_plot_placement(agent_id: String) -> void:
	var w := world()
	if agent_id == "" or w.agent_home(agent_id) != null:
		return
	if not Game.link.is_live():
		Notify.push("The Town Hall is not connected.", "warn", "plot", 1500)
		return
	mode = Mode.PLACE_PLOT
	place_agent_id = agent_id
	place_type = Game.link.home_type(agent_id)
	place_cell = Pathing.NO_CELL
	view.ghost.show_plot(place_type)
	_update_plot_ghost(get_viewport().get_mouse_position())


func _update_plot_ghost(screen: Vector2) -> void:
	var w := world()
	var g: Variant = camera.screen_to_ground(screen)
	if g == null:
		view.ghost.visible = false
		return
	var gp: Vector3 = g
	var cell := HomeLayout.home_cell_at(Vector2i(floori(gp.x), floori(gp.z)))
	if cell != place_cell:
		place_cell = cell
		_set_plot_check(Placement.check_plot(w, place_type, cell))
	view.ghost.visible = true
	view.ghost.place_at(place_cell, Vector2i(HomeLayout.HOME, HomeLayout.HOME), bool(place_check.get("ok", false)))


func _set_plot_check(check: Dictionary) -> void:
	place_check = check
	var ok := bool(check.get("ok", false))
	var who := J.gs(Realm.agent(place_agent_id), "name", "The agent")
	var bname := world().econ.building_name(place_type)
	hint_changed.emit("%s's %s: click to choose this plot. Right-click cancels." % [who, bname] if ok else "%s: %s" % [bname, String(check.get("reason", ""))], ok)
	if view.ghost.visible and place_cell != Pathing.NO_CELL:
		view.ghost.place_at(place_cell, Vector2i(HomeLayout.HOME, HomeLayout.HOME), ok)


func _try_place_plot() -> void:
	var w := world()
	if place_cell == Pathing.NO_CELL or _plot_pending:
		return
	_set_plot_check(Placement.check_plot(w, place_type, place_cell))
	if not bool(place_check.get("ok", false)):
		Notify.push(String(place_check.get("reason", "Can't build there.")), "warn", "placement", 600)
		return
	var agent_id := place_agent_id
	var cell := place_cell
	_plot_pending = true
	var req := Game.link.place_home(agent_id, cell)
	await req.done
	_plot_pending = false
	if not req.ok:
		Notify.push(req.error_message(), "warn", "plot", 0)
		return
	view.ping(cell + Vector2i.ONE, "build")
	Notify.push("%s heads to the plot to build." % J.gs(Realm.agent(agent_id), "name", "The agent"), "good", "plot", 0)
	if mode == Mode.PLACE_PLOT and place_agent_id == agent_id:
		cancel_mode()


func cancel_mode() -> void:
	mode = Mode.SELECT
	place_type = ""
	place_agent_id = ""
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
