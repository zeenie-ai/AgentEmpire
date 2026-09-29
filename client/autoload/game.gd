extends Node
## Owns the running town: the SimWorld, its fixed-rate clock and the bridge from simulation
## notices to toasts, income stats and audio cues. With a Town Hall running, the town is the
## Town Hall's (TownLink, a child of this node); without one it is an offline town.
##
## The simulation steps at economy.json tick_rate (20/s) from an accumulator in _process, with
## the frame delta capped at MAX_FRAME_DELTA. interp_alpha tells views how far they are between
## the last two ticks.

signal world_started(world: SimWorld)
signal world_stopped()

const MAX_FRAME_DELTA := 0.25
const SAVE_DIR := "user://saves"
## How long boot() waits for the Town Hall before starting an offline town.
const BOOT_WAIT_MS := 3000
## How long quitting waits for the final save_town.
const QUIT_SAVE_WAIT_MS := 2000

var world: SimWorld
var interp_alpha: float = 0.0
var paused: bool = false
## Debug speed-up; 1.0 in normal play.
var time_scale: float = 1.0
var income: IncomeTracker = IncomeTracker.new()
var link: TownLink
## True while boot() is still deciding between the Town Hall's town and an offline one.
var booting: bool = false

var _accumulator: float = 0.0
var _quitting: bool = false


func _ready() -> void:
	link = TownLink.new()
	link.name = "TownLink"
	add_child(link)
	get_tree().auto_accept_quit = false


## Starts the game: the Town Hall's town when a Town Hall answers within BOOT_WAIT_MS,
## otherwise an offline town from `map_seed`. `-- --offline` skips the Town Hall.
func boot(map_seed: int) -> void:
	booting = true
	if Net.wanted():
		Net.enable(true)
		var deadline := Time.get_ticks_msec() + BOOT_WAIT_MS
		while not Net.is_online() and Time.get_ticks_msec() < deadline:
			if Net.status == Net.STATUS_BUSY or Net.status == Net.STATUS_REJECTED:
				break
			if Net.status == Net.STATUS_SEARCHING and Net.endpoint.is_empty() and Net.attempts > 0:
				break
			# A stale runtime file: the first attempt failed and Net is retrying.
			if Net.attempts >= 2:
				break
			await get_tree().process_frame
	if Net.is_online() and await link.open_online_town(map_seed):
		booting = false
		return
	booting = false
	new_town(map_seed)


## Leaves the offline town and opens the Town Hall's.
func switch_to_town_hall(map_seed: int) -> void:
	if not Net.is_online():
		Notify.push("The Town Hall is not connected.", "warn")
		return
	await link.open_online_town(map_seed)


func has_world() -> bool:
	return world != null


func is_online_town() -> bool:
	return link != null and link.online_town


## Starts a new offline town from `map_seed`.
func new_town(map_seed: int, town_id: String = "") -> SimWorld:
	stop_town()
	Economy.reset_local_ledger()
	var id := town_id if town_id != "" else "town-%08x" % (randi() & 0x7fffffff)
	var w := SimWorld.create_new(Economy.data, Economy.ledger, map_seed, id)
	_start(w)
	return w


## Starts a town from a SimWorld snapshot (and optionally an offline ledger snapshot).
func load_town(snapshot: Dictionary, ledger_state: Dictionary = {}) -> SimWorld:
	stop_town()
	var l := Economy.reset_local_ledger()
	if not ledger_state.is_empty():
		l.load_dict(ledger_state)
	var w := SimWorld.from_dict(snapshot, Economy.data, Economy.ledger)
	if w == null:
		Notify.push("That save is from a newer version.", "error")
		return null
	_start(w)
	return w


func stop_town() -> void:
	if world == null:
		link.online_town = false
		return
	if world.notice.is_connected(_on_notice):
		world.notice.disconnect(_on_notice)
	world = null
	income.clear()
	world_stopped.emit()


## Queues a command for the next simulation tick.
func issue(cmd: Dictionary) -> void:
	if world != null:
		world.commands.push(cmd)


## Runs `w` as the current town (TownLink uses this for the Town Hall's town).
func start_world(w: SimWorld) -> void:
	_start(w)


func _start(w: SimWorld) -> void:
	world = w
	income = IncomeTracker.new(w.tick_rate)
	_accumulator = 0.0
	interp_alpha = 0.0
	world.notice.connect(_on_notice)
	ClientLog.info("game", "Town %s started (seed %d, %d nodes)." % [w.town_id, w.map_seed, w.nodes.size()])
	world_started.emit(world)


func _process(delta: float) -> void:
	if world == null:
		return
	if paused:
		return
	var tick_dt := world.dt
	_accumulator += minf(delta, MAX_FRAME_DELTA) * time_scale
	var guard := 0
	while _accumulator >= tick_dt and guard < 64:
		world.step(1)
		_accumulator -= tick_dt
		guard += 1
	interp_alpha = clampf(_accumulator / tick_dt, 0.0, 1.0)


# --- offline saves -------------------------------------------------------------------------

func save_offline(slot: String = "quick") -> bool:
	if world == null:
		return false
	if is_online_town():
		var req: NetRequest = link.save_now()
		if req != null:
			await req.done
			Notify.push("Town saved to the Town Hall." if req.ok else "Could not save: %s" % req.error_message(), "good" if req.ok else "error")
		return req != null and req.ok
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var doc := {"format": "aurelhaven-offline", "sim": world.to_dict(), "ledger": Economy.ledger.to_dict()}
	var f := FileAccess.open("%s/%s.json" % [SAVE_DIR, slot], FileAccess.WRITE)
	if f == null:
		Notify.push("Could not save the town.", "error")
		return false
	f.store_string(JSON.stringify(doc, "", true, true))
	f.close()
	Notify.push("Town saved.", "good")
	return true


func load_offline(slot: String = "quick") -> bool:
	if is_online_town():
		Notify.push("This town lives in the Town Hall; it saves itself.", "info", "online_load", 2000)
		return false
	var path := "%s/%s.json" % [SAVE_DIR, slot]
	if not FileAccess.file_exists(path):
		Notify.push("No saved town yet (F5 saves).", "warn")
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed as Dictionary).has("sim"):
		Notify.push("The saved town could not be read.", "error")
		return false
	var doc: Dictionary = parsed
	if load_town(doc["sim"], doc.get("ledger", {})) == null:
		return false
	Notify.push("Town loaded.", "good")
	return true


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quit_after_save()


## Saves the Town Hall's town before closing (waits up to QUIT_SAVE_WAIT_MS).
func _quit_after_save() -> void:
	if _quitting:
		return
	_quitting = true
	var req: NetRequest = link.save_now() if is_online_town() else null
	if req != null:
		var deadline := Time.get_ticks_msec() + QUIT_SAVE_WAIT_MS
		while not req.finished and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
	get_tree().quit()


# --- notices -------------------------------------------------------------------------------

func _on_notice(kind: String, data: Dictionary) -> void:
	match kind:
		"deposited":
			income.record(world.tick, String(data.get("res", "")), int(data.get("amount", 0)))
		"need_houses":
			Notify.push("Need houses: build a Cottage to raise the population cap.", "warn", "need_houses", 8000)
			Audio.play("need_houses")
		"not_enough":
			Notify.push("Not enough %s." % _res_list(data.get("missing", {})), "warn", "not_enough", 1200)
		"queue_full":
			Notify.push("The training queue is full (%d)." % int(data.get("max", 0)), "warn", "queue_full", 1200)
		"placement_invalid":
			Notify.push(String(data.get("reason", "Can't build there.")), "warn", "placement", 800)
		"storage_full":
			var res := String(data.get("res", "")).capitalize()
			Notify.push("%s storage is full. Build a Storehouse." % res, "warn", "storage_full_" + res, 10000)
		"built":
			Notify.push("%s completed." % Economy.data.building_name(String(data.get("type", ""))), "good", "", 0)
			Audio.play("build_complete")
		"trained":
			Notify.push("A townsperson is ready.", "good", "trained", 1500)
			Audio.play("train_complete")
		"cant_reach":
			Notify.push("Can't reach that.", "warn", "cant_reach", 3000)
		"farm_busy":
			Notify.push("That farm is already worked.", "info", "farm_busy", 2000)
		"no_dropoff":
			Notify.push("No drop-off accepts that. Build a Storehouse.", "warn", "no_dropoff", 5000)
		"site_cancelled":
			Notify.push("Construction cancelled. Refunded %s." % _res_list(data.get("refund", {})), "info", "", 0)
		"dismantled":
			Notify.push("Dismantled. Refunded %s." % _res_list(data.get("refund", {})), "info", "", 0)
		"train_cancelled":
			Notify.push("Training cancelled. Refunded %s." % _res_list(data.get("refund", {})), "info", "train_cancel", 500)


static func _res_list(d: Variant) -> String:
	if typeof(d) != TYPE_DICTIONARY or (d as Dictionary).is_empty():
		return "nothing"
	var parts: PackedStringArray = []
	for k: Variant in (d as Dictionary).keys():
		parts.append("%d %s" % [int(d[k]), String(k).capitalize()])
	return ", ".join(parts)
