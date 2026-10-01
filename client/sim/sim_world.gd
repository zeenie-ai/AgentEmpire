class_name SimWorld
extends RefCounted
## The town simulation: plain data, no nodes, stepped at a fixed rate (economy.json tick_rate).
##
## Every change to game state arrives as a serializable command (GameCommands) that is applied
## at the start of the next tick; that command log is what makes replays and shared team towns
## possible later. Visual nodes follow the signals below and interpolate between prev_pos and pos.
## Game (autoload) drives step() from an accumulator in _process; tests call step(n) directly.

## A unit, building or resource node appeared. category is CAT_UNIT, CAT_BUILDING or CAT_NODE.
signal entity_spawned(id: int, category: String)
signal entity_removed(id: int, category: String)
## Structural change (job, completion, depletion, queue). Per-tick values (positions,
## progress) are read directly by the views each frame.
signal entity_changed(id: int, category: String)
## Gameplay events for the HUD and audio: need_houses, not_enough, queue_full,
## placement_invalid, storage_full, built, trained, deposited, cant_reach, farm_busy, ...
signal notice(kind: String, data: Dictionary)
signal ticked(tick: int)
## Solidity or occupancy changed inside rect (minimap, placement ghost).
signal grid_changed(rect: Rect2i)
## Town wall ring `ring` rose or fell, or one of its pieces opened (a building stands on it) or
## closed again. WallView redraws that ring.
signal walls_changed(ring: int)

const CAT_UNIT := "unit"
const CAT_BUILDING := "building"
const CAT_NODE := "node"
## Buildings that train units, and what. Agents are summoned through the Town Hall, which
## charges for them; the Keep then trains them like townsfolk (queue_agent).
const TRAINERS := {"keep": ["townsfolk"]}
## The building type whose count raises the Food and Wood caps (storage.storehouse_bonus).
const STOREHOUSE_TYPE := "storehouse"
const NODE_CHUNK_SHIFT := 3

var econ: EconomyData
var ledger: Ledger
var commands: GameCommands
var grid: SimGrid
var path_service: PathService
var spatial: SpatialHash

var town_id: String = "town"
var map_seed: int = 0
var tick: int = 0
var age: int = 1
var next_id: int = 1
var op_seq: int = 0
## Random per run and never saved: ledger op ids stay unique even when a town is reloaded from
## a snapshot older than its last operations (the Town Hall remembers every op id).
var session: String = ""
var tick_rate: int = 20
var dt: float = 0.05
## Allows debug_spawn (perf and capture tools). Never enabled in normal play.
var allow_debug_commands: bool = false

var units: Dictionary[int, SimUnit] = {}
var buildings: Dictionary[int, SimBuilding] = {}
var nodes: Dictionary[int, SimResourceNode] = {}
var rocks: Array[Vector2i] = []
## Depleted node ids waiting to regrow.
var regrowing: Array[int] = []
var keep_id: int = 0
## Font Wisps in flight: {"id", "task_id", "agent_id", "building", "pos": Vector2,
## "prev": Vector2, "delay": int}. They carry scrolls nobody else could.
var wisps: Array[Dictionary] = []
## The town walls (WallLayout): every ring's cells are reserved from the start, and ring k
## stands from Age k + 1. Null on a sandbox map (create_empty), which has none.
var walls: WallLayout = null
## How many rings stand now.
var walls_up: int = 0
## Per WallLayout piece: 1 while a building stands on one of its cells (towns laid out before
## the walls existed). Such a piece is left out of its standing ring: a gap, never solid.
var wall_gaps: PackedByteArray = PackedByteArray()
## Wanderers (economy.json anti_deadlock.wanderer): free townsfolk who walk in from the map
## edge when the town has none left and too little Food to train one. Off on sandbox maps.
var wanderers_enabled: bool = false
## Ticks until the next wanderer while a rescue is under way; -1 when there is none.
var wanderer_wait: int = -1
## Wanderers who came so far (each enters through the next outer gate).
var wanderers_sent: int = 0

var _node_chunks: Dictionary = {}
var _region: PackedByteArray = PackedByteArray()
var _region_version: int = -1
var _work_cache: Dictionary = {}
var _step_cache: Dictionary = {}


func _init(economy: EconomyData, resource_ledger: Ledger) -> void:
	econ = economy
	ledger = resource_ledger
	tick_rate = maxi(econ.tick_rate(), 1)
	dt = 1.0 / float(tick_rate)
	commands = GameCommands.new()
	session = "%06x" % (randi() & 0xffffff)
	grid = SimGrid.new(econ.map_size())
	path_service = PathService.new()
	spatial = SpatialHash.new(SimConst.HASH_CELL)
	age = maxi(econ.start_age(), 1)


## A new town: generated map, the Keep at the centre and the starting townsfolk. The walls are
## laid out first, so nothing grows on their line, and the current age's rings stand.
static func create_new(economy: EconomyData, resource_ledger: Ledger, seed_value: int, id: String = "town") -> SimWorld:
	var w := SimWorld.new(economy, resource_ledger)
	w.town_id = id
	w.map_seed = seed_value
	w.ledger.set_age(w.age)
	w.wanderers_enabled = true
	w.enable_walls()
	MapGenerator.generate(w, seed_value)
	w.spawn_start_units()
	return w


## An empty map with only the Keep (tests and tools): no walls and no wanderers unless a test
## turns them on (enable_walls(), wanderers_enabled).
static func create_empty(economy: EconomyData, resource_ledger: Ledger, id: String = "test") -> SimWorld:
	var w := SimWorld.new(economy, resource_ledger)
	w.town_id = id
	w.ledger.set_age(w.age)
	w.place_keep()
	return w


func place_keep() -> SimBuilding:
	var fp := econ.building_footprint("keep")
	var c := grid.size >> 1
	return add_building("keep", Vector2i(c - (fp.x >> 1), c - (fp.y >> 1)), true, "")


func spawn_start_units() -> void:
	var k := keep()
	if k == null:
		return
	var cells := exit_cells(k, Vector2(k.center().x, float(k.rect().end.y) + 3.0))
	for i in econ.start_townsfolk():
		if cells.is_empty():
			break
		add_unit("townsfolk", Pathing.center_of(cells[i % cells.size()]))


# --- stepping -------------------------------------------------------------------------------

func step(n: int = 1) -> void:
	for i in n:
		_tick_once()


func _tick_once() -> void:
	for cmd in commands.take_pending():
		commands.record(tick, cmd)
		CommandApplier.apply(self, cmd)
	path_service.process(self)
	for u: SimUnit in units.values():
		u.prev_pos = u.pos
	UnitSystem.tick(self)
	ConstructionSystem.tick(self)
	TrainingSystem.tick(self)
	RegrowSystem.tick(self)
	WispSystem.tick(self)
	WandererSystem.tick(self)
	tick += 1
	ticked.emit(tick)


# --- ids --------------------------------------------------------------------------------------

func new_id() -> int:
	var i := next_id
	next_id += 1
	return i


## Unique ledger op id for this town (the Town Hall uses op ids as idempotency keys).
func next_op_id(kind: String) -> String:
	op_seq += 1
	return "%s:%s:%s:%d" % [town_id, session, kind, op_seq]


# --- entities -------------------------------------------------------------------------------

func add_unit(kind: String, p: Vector2) -> SimUnit:
	var u := SimUnit.new()
	u.id = new_id()
	u.kind = kind
	u.pos = p
	u.prev_pos = p
	units[u.id] = u
	entity_spawned.emit(u.id, CAT_UNIT)
	return u


## Adds a building or site. Agent homes and add-ons pass their owner (and tool id); a home also
## reserves its plot. Nodes under the footprint are cleared for good (the placement checks keep
## live ones out; a home placed to catch up with the Town Hall clears whatever is there).
func add_building(type: String, cell: Vector2i, complete: bool, spend_op: String,
		owner_agent_id: String = "", tool_id: String = "") -> SimBuilding:
	var b := SimBuilding.new()
	b.id = new_id()
	b.type = type
	b.cell = cell
	b.size = econ.building_footprint(type)
	b.complete = complete
	b.work = SimConst.WORK_SCALE if complete else 0
	b.spend_op = spend_op
	b.walkable = econ.building_is_field(type)
	b.owner_agent_id = owner_agent_id
	b.tool_id = tool_id
	if owner_agent_id != "" and tool_id == "":
		b.plot = HomeLayout.plot_rect(cell)
	var r := b.rect()
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var occ := grid.occupant_at(Vector2i(x, y))
			if occ != 0 and nodes.has(occ):
				remove_node(occ)
	_restore_building(b)
	if not b.walkable:
		_on_cells_blocked(r)
	_refresh_wall_gaps(r)
	entity_spawned.emit(b.id, CAT_BUILDING)
	grid_changed.emit(r)
	return b


func _restore_building(b: SimBuilding) -> void:
	buildings[b.id] = b
	grid.set_occupant(b.rect(), b.id)
	if not b.walkable:
		grid.set_solid(b.rect(), true)
	if b.type == "keep" and keep_id == 0:
		keep_id = b.id


func remove_building(id: int) -> void:
	var b: SimBuilding = buildings.get(id)
	if b == null:
		return
	var r := b.rect()
	buildings.erase(id)
	grid.clear_occupant(r, id)
	if not b.walkable:
		grid.set_solid(r, false)
	if keep_id == id:
		keep_id = 0
	_refresh_wall_gaps(r)
	entity_removed.emit(id, CAT_BUILDING)
	grid_changed.emit(r)


func add_node(kind: String, cell: Vector2i, variant: int = 0) -> SimResourceNode:
	var n := SimResourceNode.new()
	n.id = new_id()
	n.kind = kind
	n.cell = cell
	n.variant = variant
	n.max_m = maxi(econ.node_amount(kind), 0) * 1000
	n.amount_m = n.max_m
	_restore_node(n)
	entity_spawned.emit(n.id, CAT_NODE)
	return n


func _restore_node(n: SimResourceNode) -> void:
	nodes[n.id] = n
	grid.set_occupant(n.rect(), n.id)
	if not n.depleted:
		grid.set_solid(n.rect(), true)
	var k := Vector2i(n.cell.x >> NODE_CHUNK_SHIFT, n.cell.y >> NODE_CHUNK_SHIFT)
	var arr: Variant = _node_chunks.get(k)
	if arr == null:
		_node_chunks[k] = [n.id]
	else:
		(arr as Array).append(n.id)


func remove_node(id: int) -> void:
	var n: SimResourceNode = nodes.get(id)
	if n == null:
		return
	nodes.erase(id)
	grid.clear_occupant(n.rect(), id)
	if not n.depleted:
		grid.set_solid(n.rect(), false)
	var k := Vector2i(n.cell.x >> NODE_CHUNK_SHIFT, n.cell.y >> NODE_CHUNK_SHIFT)
	var arr: Variant = _node_chunks.get(k)
	if arr != null:
		(arr as Array).erase(id)
	regrowing.erase(id)
	entity_removed.emit(id, CAT_NODE)
	grid_changed.emit(n.rect())


func add_rock(c: Vector2i) -> void:
	if not grid.in_bounds(c) or grid.terrain_at(c) == SimGrid.TERRAIN_ROCK:
		return
	rocks.append(c)
	grid.set_terrain(c, SimGrid.TERRAIN_ROCK)
	grid.set_solid(Rect2i(c, Vector2i.ONE), true)


func deplete_node(n: SimResourceNode) -> void:
	n.depleted = true
	n.amount_m = 0
	grid.set_solid(n.rect(), false)
	var ticks := int(round(econ.node_regrow_s(n.kind) * float(tick_rate)))
	if ticks <= 0:
		remove_node(n.id)
		return
	n.regrow_ticks = ticks
	regrowing.append(n.id)
	entity_changed.emit(n.id, CAT_NODE)
	grid_changed.emit(n.rect())


func regrow_node(n: SimResourceNode) -> void:
	n.depleted = false
	n.amount_m = n.max_m
	n.regrow_ticks = 0
	grid.set_solid(n.rect(), true)
	_on_cells_blocked(n.rect())
	entity_changed.emit(n.id, CAT_NODE)
	grid_changed.emit(n.rect())


func complete_building(b: SimBuilding) -> void:
	b.complete = true
	b.work = SimConst.WORK_SCALE
	entity_changed.emit(b.id, CAT_BUILDING)
	emit_notice("built", {"building": b.id, "type": b.type, "agent_id": b.owner_agent_id})
	if b.owner_agent_id == "":
		return
	if b.tool_id != "":
		emit_notice("tool_complete", {"building": b.id, "agent_id": b.owner_agent_id, "tool_id": b.tool_id, "type": b.type})
	else:
		emit_notice("home_complete", {"building": b.id, "agent_id": b.owner_agent_id, "type": b.type})


func finish_training(b: SimBuilding, item: Dictionary) -> void:
	var kind := String(item.get("unit", "townsfolk"))
	var cells := exit_cells(b, rally_point(b))
	var c := cells[0] if not cells.is_empty() else Pathing.nearest_walkable(grid, Vector2i(b.center()), 12)
	if c == Pathing.NO_CELL:
		c = Vector2i(b.center())
	if kind == "agent":
		var a := add_agent_unit(String(item.get("agent_id", "")), String(item.get("role", "")), Pathing.center_of(c))
		emit_notice("agent_trained", {"building": b.id, "unit": a.id, "agent_id": a.agent_id, "role": a.role})
		entity_changed.emit(b.id, CAT_BUILDING)
		return
	var u := add_unit(kind, Pathing.center_of(c))
	emit_notice("trained", {"building": b.id, "unit": u.id, "kind": kind})
	entity_changed.emit(b.id, CAT_BUILDING)
	send_to_rally(b, u)


## An agent's walking figure. It builds its home and add-ons, then lives on its plot (AgentJob).
func add_agent_unit(agent_id: String, role: String, p: Vector2) -> SimUnit:
	var u := SimUnit.new()
	u.id = new_id()
	u.kind = "agent"
	u.agent_id = agent_id
	u.role = role
	u.pos = p
	u.prev_pos = p
	var home := agent_home(agent_id)
	u.home_id = home.id if home != null else 0
	units[u.id] = u
	entity_spawned.emit(u.id, CAT_UNIT)
	return u


## Where new units from `b` head: its rally point, or just outside its south side.
func rally_point(b: SimBuilding) -> Vector2:
	if b.rally.is_empty():
		return Vector2(b.center().x, float(b.rect().end.y) + 2.0)
	return Pathing.center_of(Vector2i(int(b.rally["x"]), int(b.rally["y"])))


## Sends a freshly trained unit to the rally point; a resource there means "go gather it".
func send_to_rally(b: SimBuilding, u: SimUnit) -> void:
	if b.rally.is_empty():
		return
	var target := int(b.rally.get("target", 0))
	if target != 0:
		var tb: SimBuilding = buildings.get(target)
		if tb != null and not tb.complete:
			if BuildJob.start(self, u, target):
				return
		elif GatherJob.target_kind(self, target) != "":
			if GatherJob.start(self, u, target):
				return
	MoveJob.start(self, u, Vector2i(int(b.rally["x"]), int(b.rally["y"])), false)


## Moves a unit's carried load into the treasury (clipped to the storage caps). Fractions of a
## unit (a node that ran out mid-load) are dropped.
func deposit_carry(u: SimUnit, b: SimBuilding) -> void:
	var amt := u.carry_amount()
	var res := u.carry_res
	u.carry_m = 0
	u.carry_res = ""
	if amt <= 0 or res == "":
		entity_changed.emit(u.id, CAT_UNIT)
		return
	var accepted := ledger.deposit(next_op_id("gather"), {res: amt}, storehouse_count())
	var got := int(accepted.get(res, 0))
	emit_notice("deposited", {"unit": u.id, "building": b.id, "res": res, "amount": got})
	if got < amt:
		emit_notice("storage_full", {"res": res, "lost": amt - got})
	entity_changed.emit(u.id, CAT_UNIT)


# --- queries ----------------------------------------------------------------------------------

func keep() -> SimBuilding:
	return buildings.get(keep_id)


# --- agents -----------------------------------------------------------------------------------

## The walking figure of a Town Hall agent, or null.
func agent_unit(agent_id: String) -> SimUnit:
	if agent_id == "":
		return null
	for u: SimUnit in units.values():
		if u.agent_id == agent_id:
			return u
	return null


## The agent's home (complete or under construction), or null.
func agent_home(agent_id: String) -> SimBuilding:
	if agent_id == "":
		return null
	for b: SimBuilding in buildings.values():
		if b.owner_agent_id == agent_id and b.tool_id == "":
			return b
	return null


## The agent's add-ons (complete or under construction), oldest first.
func agent_tools(agent_id: String) -> Array[SimBuilding]:
	var out: Array[SimBuilding] = []
	if agent_id == "":
		return out
	for b: SimBuilding in buildings.values():
		if b.owner_agent_id == agent_id and b.tool_id != "":
			out.append(b)
	out.sort_custom(func(x: SimBuilding, y: SimBuilding) -> bool: return x.id < y.id)
	return out


func tool_building(tool_id: String) -> SimBuilding:
	if tool_id == "":
		return null
	for b: SimBuilding in buildings.values():
		if b.tool_id == tool_id:
			return b
	return null


## The agent's first unfinished building: the home first, then add-ons in the order placed.
func agent_next_site(agent_id: String) -> SimBuilding:
	var home := agent_home(agent_id)
	if home != null and not home.complete:
		return home
	for t in agent_tools(agent_id):
		if not t.complete:
			return t
	return null


## The queue entry of an agent in training ({} when it is not queued anywhere).
func queued_agent(agent_id: String) -> Dictionary:
	for b: SimBuilding in buildings.values():
		for item in b.queue:
			if String(item.get("agent_id", "")) == agent_id:
				return item
	return {}


## Every home plot, as {agent_id: Rect2i}.
func plots() -> Dictionary:
	var out := {}
	for b: SimBuilding in buildings.values():
		if b.owner_agent_id != "" and b.tool_id == "" and b.plot.size != Vector2i.ZERO:
			out[b.owner_agent_id] = b.plot
	return out


## The agent whose plot covers `c`, or "".
func plot_owner_at(c: Vector2i) -> String:
	var ps := plots()
	for id: String in ps:
		if (ps[id] as Rect2i).has_point(c):
			return id
	return ""


func get_entity(id: int) -> Object:
	if units.has(id):
		return units[id]
	if buildings.has(id):
		return buildings[id]
	if nodes.has(id):
		return nodes[id]
	return null


func category_of(id: int) -> String:
	if units.has(id):
		return CAT_UNIT
	if buildings.has(id):
		return CAT_BUILDING
	if nodes.has(id):
		return CAT_NODE
	return ""


func building_at(c: Vector2i) -> SimBuilding:
	var occ := grid.occupant_at(c)
	return buildings.get(occ) if occ != 0 else null


func node_at(c: Vector2i) -> SimResourceNode:
	var occ := grid.occupant_at(c)
	return nodes.get(occ) if occ != 0 else null


func unit_count(kind: String) -> int:
	var n := 0
	for u: SimUnit in units.values():
		if u.kind == kind:
			n += 1
	return n


func pop_used() -> int:
	var total := 0
	for u: SimUnit in units.values():
		total += econ.unit_pop(u.kind)
	return total


## Population room from completed buildings, before the age limit.
func pop_capacity() -> int:
	var total := 0
	for b: SimBuilding in buildings.values():
		if b.complete:
			total += econ.building_pop(b.type)
	return total


func pop_cap() -> int:
	return mini(pop_capacity(), econ.pop_limit(age))


func storehouse_count() -> int:
	var n := 0
	for b: SimBuilding in buildings.values():
		if b.complete and b.type == STOREHOUSE_TYPE:
			n += 1
	return n


func gather_focus() -> String:
	var k := keep()
	return k.gather_focus if k != null else "auto"


func build_radius() -> int:
	return econ.build_radius(age)


func map_center() -> Vector2:
	return Vector2(grid.size, grid.size) * 0.5


## True when every cell of `r` lies inside the current build zone.
func in_build_zone(r: Rect2i) -> bool:
	var rad := float(build_radius())
	var c := map_center()
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if Vector2(x + 0.5, y + 0.5).distance_to(c) > rad:
				return false
	return true


func accepts(b: SimBuilding, res: String) -> bool:
	return b != null and b.complete and res != "" and res in econ.building_dropoffs(b.type)


func nearest_dropoff(p: Vector2, res: String) -> SimBuilding:
	var best: SimBuilding = null
	var best_d := INF
	for b: SimBuilding in buildings.values():
		if not accepts(b, res):
			continue
		var d := Pathing.rect_distance(p, b.rect())
		if d < best_d:
			best_d = d
			best = b
	return best


## Node ids whose centre lies within `radius` of `p` (chunk index, no full scan).
func nodes_near(p: Vector2, radius: float) -> Array[int]:
	var out: Array[int] = []
	var cs := float(1 << NODE_CHUNK_SHIFT)
	var r2 := radius * radius
	for ky in range(floori((p.y - radius) / cs), floori((p.y + radius) / cs) + 1):
		for kx in range(floori((p.x - radius) / cs), floori((p.x + radius) / cs) + 1):
			var arr: Variant = _node_chunks.get(Vector2i(kx, ky))
			if arr == null:
				continue
			for id: int in arr:
				var n: SimResourceNode = nodes[id]
				if n.center().distance_squared_to(p) <= r2:
					out.append(id)
	return out


## Nearest live node of one of `kinds` within `radius` that has a free cell next to it.
func find_nearest_node(p: Vector2, kinds: Array, radius: float, exclude: Array[int] = []) -> SimResourceNode:
	var best: SimResourceNode = null
	var best_d := INF
	for id in nodes_near(p, radius):
		var n: SimResourceNode = nodes[id]
		if n.depleted or not n.kind in kinds or id in exclude:
			continue
		var d := n.center().distance_squared_to(p)
		if d > best_d or (d == best_d and best != null and n.id > best.id):
			continue
		if Pathing.free_edge_cells(grid, n.rect()).is_empty():
			continue
		best = n
		best_d = d
	return best


## True when `b` (a field) is unclaimed, claimed by `for_unit`, or its claim is stale.
func farm_is_free(b: SimBuilding, for_unit: int) -> bool:
	if b.farmer_id == 0 or b.farmer_id == for_unit:
		return true
	var f: SimUnit = units.get(b.farmer_id)
	return f == null or f.job != SimConst.JOB_GATHER or f.target_id != b.id


func find_free_farm(p: Vector2, radius: float, for_unit: int, exclude: Array[int] = []) -> SimBuilding:
	var best: SimBuilding = null
	var best_d := INF
	for b: SimBuilding in buildings.values():
		if not b.complete or not b.walkable or not econ.building_is_field(b.type) or b.id in exclude:
			continue
		if not farm_is_free(b, for_unit):
			continue
		var d := Pathing.rect_distance(p, b.rect())
		if d <= radius and d < best_d:
			best_d = d
			best = b
	return best


## The nearest unfinished site within `radius` that townsfolk may build (agents build their
## own homes and add-ons).
func find_site_near(p: Vector2, radius: float) -> SimBuilding:
	var best: SimBuilding = null
	var best_d := INF
	for b: SimBuilding in buildings.values():
		if b.complete or b.owner_agent_id != "":
			continue
		var d := Pathing.rect_distance(p, b.rect())
		if d <= radius and d < best_d:
			best_d = d
			best = b
	return best


func idle_townsfolk() -> Array[int]:
	var out: Array[int] = []
	for u: SimUnit in units.values():
		if u.kind == "townsfolk" and u.is_idle():
			out.append(u.id)
	return out


func unit_on_cell(c: Vector2i) -> bool:
	for u: SimUnit in units.values():
		if u.cell() == c:
			return true
	return false


## Free cells around `b`, nearest to `toward` first (where trained units appear).
func exit_cells(b: SimBuilding, toward: Vector2) -> Array[Vector2i]:
	var cells := Pathing.free_edge_cells(grid, b.rect())
	cells.sort_custom(func(a: Vector2i, c: Vector2i) -> bool:
		var da := Pathing.center_of(a).distance_squared_to(toward)
		var dc := Pathing.center_of(c).distance_squared_to(toward)
		if da == dc:
			return a.y < c.y or (a.y == c.y and a.x < c.x)
		return da < dc)
	return cells


## Seeds for "reachable from the Keep": the free cells around it.
func keep_seeds() -> Array[Vector2i]:
	var k := keep()
	if k != null:
		return Pathing.free_edge_cells(grid, k.rect())
	var out: Array[Vector2i] = []
	var c := Pathing.nearest_walkable(grid, Vector2i(map_center()), 16)
	if c != Pathing.NO_CELL:
		out.append(c)
	return out


## Cells reachable from the Keep (1) as a byte per cell; cached until solidity changes.
func keep_region() -> PackedByteArray:
	if _region_version != grid.solid_version or _region.is_empty():
		_region = FloodFill.region(grid, keep_seeds())
		_region_version = grid.solid_version
	return _region


## Walk distance per tick for a unit kind.
func walk_step(kind: String) -> float:
	if not _step_cache.has(kind):
		_step_cache[kind] = econ.walk_speed(kind) * dt
	return float(_step_cache[kind])


func gather_rate_m(kind: String) -> int:
	return econ.gather_milli_per_tick(kind)


## Construction progress added per tick to a site of `type` with `builders` builders.
func work_per_tick(type: String, builders: int) -> int:
	var key := "%s:%d" % [type, builders]
	if not _work_cache.has(key):
		_work_cache[key] = ConstructionMath.work_per_tick(econ, econ.building_build_s(type), builders, tick_rate)
	return int(_work_cache[key])


# --- walls ------------------------------------------------------------------------------------

## Gives the town its walls (new and loaded towns have them; sandbox maps do not). The rings the
## current age has stand at once.
func enable_walls() -> void:
	if walls != null:
		return
	walls = WallLayout.for_economy(econ, grid.size)
	walls_up = 0
	wall_gaps = PackedByteArray()
	wall_gaps.resize(walls.pieces.size())
	sync_walls()


func wall_ring_count() -> int:
	return walls.ring_count() if walls != null else 0


## How many rings stand in age `a`: ring k (the Keep Ring is 0) stands from Age k + 1.
func rings_for_age(a: int) -> int:
	return clampi(a, 0, wall_ring_count())


## Raises or lowers rings until exactly the current age's stand. Raising a ring makes its
## pieces solid, clears trees and bushes off its line and its gate roads, and moves anyone
## standing there out of the way. Called whenever the age changes.
func sync_walls() -> void:
	if walls == null:
		return
	var want := rings_for_age(age)
	while walls_up < want:
		_raise_ring(walls_up)
		walls_up += 1
		walls_changed.emit(walls_up - 1)
		emit_notice("wall_raised", {"ring": walls_up - 1})
	while walls_up > want:
		walls_up -= 1
		_lower_ring(walls_up)
		walls_changed.emit(walls_up)
		emit_notice("wall_lowered", {"ring": walls_up})


## The wall's name for ring `ring` (economy.json ages[].wall): "Keep Ring", "Merchant Ring", ...
func wall_name(ring: int) -> String:
	return String(econ.age_def(ring + 1).get("wall", "town wall"))


## Ring of the wall reserving cell `c` (standing or not; its gate roads included), or -1.
func wall_ring_at(c: Vector2i) -> int:
	return walls.ring_at(c) if walls != null else -1


## True when wall piece `piece` stands: its ring has risen and no building leaves a gap there.
func piece_stands(piece: int) -> bool:
	if walls == null or piece < 0 or piece >= walls.pieces.size():
		return false
	var p := walls.pieces[piece]
	return p.kind != WallLayout.GATE and p.ring < walls_up and wall_gaps[piece] == 0


## True when a standing wall occupies cell `c`.
func is_wall_cell(c: Vector2i) -> bool:
	return walls != null and piece_stands(walls.piece_at(c))


## The first wall-reserved cell inside `r`, as {"ring": int, "gate": bool, "standing": bool}
## ({} when the walls leave `r` free).
func wall_reservation_in(r: Rect2i) -> Dictionary:
	if walls == null:
		return {}
	var clipped := r.intersection(grid.bounds())
	for y in range(clipped.position.y, clipped.end.y):
		for x in range(clipped.position.x, clipped.end.x):
			var c := Vector2i(x, y)
			var ring := walls.ring_at(c)
			if ring < 0:
				continue
			return {"ring": ring, "gate": walls.is_gate_cell(c), "standing": ring < walls_up}
	return {}


func _raise_ring(k: int) -> void:
	var blocked := PackedByteArray()
	blocked.resize(grid.size * grid.size)
	for pi: int in walls.ring_pieces[k]:
		var p := walls.pieces[pi]
		# Trees and bushes on the wall's line and its gate roads are cleared for good (maps made
		# before the walls; new maps leave the line clear).
		for ci in p.cells:
			var occ := grid.occupant[ci]
			if occ != 0 and nodes.has(occ):
				remove_node(occ)
		if p.kind == WallLayout.GATE:
			continue
		wall_gaps[pi] = 1 if _piece_has_building(p) else 0
		if wall_gaps[pi] != 0:
			continue
		for ci in p.cells:
			grid.set_solid(Rect2i(walls.cell_of(ci), Vector2i.ONE), true)
			blocked[ci] = 1
	_on_wall_blocked(blocked)
	grid_changed.emit(_ring_rect(k))


func _lower_ring(k: int) -> void:
	for pi: int in walls.ring_pieces[k]:
		var p := walls.pieces[pi]
		var was_gap := wall_gaps[pi] != 0
		wall_gaps[pi] = 0
		if p.kind == WallLayout.GATE or was_gap:
			continue
		for ci in p.cells:
			var c := walls.cell_of(ci)
			if not _solid_otherwise(c):
				grid.set_solid(Rect2i(c, Vector2i.ONE), false)
	grid_changed.emit(_ring_rect(k))


## A building arrived on or left wall cells inside `r`: open or close the pieces it touches.
func _refresh_wall_gaps(r: Rect2i) -> void:
	if walls == null or walls_up == 0:
		return
	var seen := {}
	var clipped := r.intersection(grid.bounds())
	for y in range(clipped.position.y, clipped.end.y):
		for x in range(clipped.position.x, clipped.end.x):
			var pi := walls.piece_at(Vector2i(x, y))
			if pi < 0 or seen.has(pi):
				continue
			seen[pi] = true
			var p := walls.pieces[pi]
			if p.kind == WallLayout.GATE or p.ring >= walls_up:
				continue
			var gap := 1 if _piece_has_building(p) else 0
			if gap == wall_gaps[pi]:
				continue
			wall_gaps[pi] = gap
			var blocked := PackedByteArray()
			blocked.resize(grid.size * grid.size)
			for ci in p.cells:
				var c := walls.cell_of(ci)
				if gap != 0:
					if not _solid_otherwise(c):
						grid.set_solid(Rect2i(c, Vector2i.ONE), false)
				else:
					grid.set_solid(Rect2i(c, Vector2i.ONE), true)
					blocked[ci] = 1
			if gap == 0:
				_on_wall_blocked(blocked)
			walls_changed.emit(p.ring)


func _piece_has_building(p: WallLayout.Piece) -> bool:
	for ci in p.cells:
		var occ := grid.occupant[ci]
		if occ != 0 and buildings.has(occ):
			return true
	return false


## True when something other than a wall makes `c` solid: rock, a live resource node or a
## building that is not a field.
func _solid_otherwise(c: Vector2i) -> bool:
	if grid.terrain_at(c) == SimGrid.TERRAIN_ROCK:
		return true
	var occ := grid.occupant_at(c)
	if occ == 0:
		return false
	var n: SimResourceNode = nodes.get(occ)
	if n != null:
		return not n.depleted
	var b: SimBuilding = buildings.get(occ)
	return b != null and not b.walkable


## Cells marked in `blocked` (a byte per cell) just became wall: anyone standing there steps
## off to their own side of the wall, and routes through them are planned again.
func _on_wall_blocked(blocked: PackedByteArray) -> void:
	for u: SimUnit in units.values():
		var c := u.cell()
		if grid.in_bounds(c) and blocked[grid.index(c)] != 0:
			var free := _wall_exit(u.pos)
			if free != Pathing.NO_CELL:
				u.pos = Pathing.center_of(free)
			if u.path_state == SimConst.PATH_READY:
				repath(u)
			continue
		if u.path_state == SimConst.PATH_READY:
			for i in range(u.path_i, u.path.size()):
				var pc := u.path[i]
				if grid.in_bounds(pc) and blocked[grid.index(pc)] != 0:
					repath(u)
					break


## The nearest walkable cell to a point inside a wall, on the same side of the ring.
func _wall_exit(p: Vector2) -> Vector2i:
	var c := Pathing.cell_of(p)
	var k := walls.ring_at(c)
	if k >= 0:
		var rel := p - walls.center
		var side := 1.0 if rel.length() >= walls.radii[k] else -1.0
		var probe := Pathing.cell_of(p + rel.normalized() * side * 1.6)
		var near := Pathing.nearest_walkable(grid, probe, 3)
		if near != Pathing.NO_CELL:
			return near
	return Pathing.nearest_walkable(grid, c, 10)


func _ring_rect(k: int) -> Rect2i:
	var r := int(ceil(walls.radii[k])) + 5
	var c := Vector2i(walls.center)
	return Rect2i(c - Vector2i(r, r), Vector2i(r, r) * 2).intersection(grid.bounds())


# --- paths ------------------------------------------------------------------------------------

## Asks the PathService for a path; the unit stands still until it is served.
func request_path(u: SimUnit, mode: int, goal: Rect2i, accept_partial: bool = false) -> void:
	u.goal_mode = mode
	u.goal_rect = goal
	u.accept_partial = accept_partial
	u.path.clear()
	u.path_i = 0
	u.path_partial = false
	u.stuck_ticks = 0
	u.path_state = SimConst.PATH_PENDING
	path_service.request(u.id)


func repath(u: SimUnit) -> void:
	request_path(u, u.goal_mode, u.goal_rect, u.accept_partial)


func stop_moving(u: SimUnit) -> void:
	u.path.clear()
	u.path_i = 0
	u.path_state = SimConst.PATH_NONE
	u.path_partial = false
	u.stuck_ticks = 0
	path_service.cancel(u.id)


## Called by PathService. A partial path fails the request unless the unit accepts partial
## paths (moves walk as close as they can and report "can't reach").
func compute_path(u: SimUnit) -> void:
	var from := u.cell()
	if not grid.is_walkable(from):
		var free := Pathing.nearest_walkable(grid, from, 10)
		if free == Pathing.NO_CELL:
			u.path_state = SimConst.PATH_FAILED
			return
		u.pos = Pathing.center_of(free)
		from = free
	var res := Pathing.find_path(grid, from, u.goal_mode, u.goal_rect)
	var p: Array[Vector2i] = res["path"]
	var reached: bool = res["reached"]
	if p.is_empty() or (not reached and not u.accept_partial):
		u.path.clear()
		u.path_i = 0
		u.path_state = SimConst.PATH_FAILED
		return
	u.path = p
	u.path_partial = not reached
	u.stuck_ticks = 0
	if p.size() <= 1:
		u.path_i = p.size()
		u.path_state = SimConst.PATH_DONE
	else:
		u.path_i = 1
		u.path_state = SimConst.PATH_READY
	if u.path_partial:
		emit_notice("cant_reach", {"unit": u.id})


## Cells in `r` just became solid: push units out of them and re-path routes that cross them.
func _on_cells_blocked(r: Rect2i) -> void:
	for u: SimUnit in units.values():
		if r.has_point(u.cell()):
			var free := Pathing.nearest_walkable(grid, u.cell(), 10)
			if free != Pathing.NO_CELL:
				u.pos = Pathing.center_of(free)
			if u.path_state == SimConst.PATH_READY:
				repath(u)
			continue
		if u.path_state == SimConst.PATH_READY:
			for i in range(u.path_i, u.path.size()):
				if r.has_point(u.path[i]):
					repath(u)
					break


func emit_notice(kind: String, data: Dictionary = {}) -> void:
	notice.emit(kind, data)


# --- snapshots --------------------------------------------------------------------------------

## JSON-safe snapshot of the whole simulation (what Phase 3's save_town sends).
func to_dict() -> Dictionary:
	return SimSerializer.to_dict(self)


static func from_dict(d: Dictionary, economy: EconomyData, resource_ledger: Ledger) -> SimWorld:
	return SimSerializer.from_dict(d, economy, resource_ledger)
