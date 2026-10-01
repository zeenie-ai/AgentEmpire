extends Node
## Owns the running town: the SimWorld, its fixed-rate clock and the bridge from simulation
## notices to toasts, income stats and audio cues. With a Town Hall running, the town is the
## Town Hall's (TownLink, a child of this node); without one it is an offline town.
##
## The simulation steps at economy.json tick_rate (20/s) from an accumulator in _process, fed
## with real elapsed time (capped at MAX_FRAME_DELTA). The engine clamps the delta it reports
## after a long frame, so a rendering stall (a slow driver, a screen recorder) would otherwise
## slow the whole town down; with the real clock the town keeps its speed and catches up.
## interp_alpha tells views how far they are between the last two ticks.

signal world_started(world: SimWorld)
signal world_stopped()
## The connected Town Hall's mode changed: "real", "fake" (practice), or "" (none connected).
signal town_hall_mode_changed(mode: String)

const Protocol = preload("res://net/protocol.gd")

const MAX_FRAME_DELTA := 1.0
const SAVE_DIR := "user://saves"
## How long boot() waits for the Town Hall before starting an offline town.
const BOOT_WAIT_MS := 3000
## How long the game waits for a Town Hall it started itself (a real one probes the harnesses
## first). A start that fails says so in its log, which ends the wait at once.
const LAUNCH_WAIT_MS := 45000
## How long quitting waits for the final save_town.
const QUIT_SAVE_WAIT_MS := 2000
## Closing a Town Hall: the save before it, its own goodbye, and the end of its process.
const CLOSE_SAVE_WAIT_MS := 8000
const CLOSE_DISCONNECT_WAIT_MS := 5000
const CLOSE_EXIT_WAIT_MS := 20000
const MODE_NAMES := {"real": "real", "fake": "practice"}

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
var _last_usec: int = 0
## The mode last announced through town_hall_mode_changed.
var _hall_mode: String = ""
## True while switch_town_hall_mode() or close_town_hall() runs.
var _hall_busy: bool = false
## The data folder of the Town Hall this game started last, and that Town Hall's process id once
## the game has connected to it (town_hall_launched_by_game).
var _launched_data_dir: String = ""
var _launched_pid: int = 0
## Why the last Town Hall the game started could not start ("" when it did, or when unknown).
var _launch_error: String = ""


func _ready() -> void:
	link = TownLink.new()
	link.name = "TownLink"
	add_child(link)
	get_tree().auto_accept_quit = false
	Net.connection_changed.connect(_on_net_connection)


## Starts the game: the Town Hall's town when a Town Hall answers within BOOT_WAIT_MS (or one
## the game starts, when none is running and townhall/auto_start allows), otherwise an offline
## town from `map_seed`. `-- --offline` skips the Town Hall.
func boot(map_seed: int) -> void:
	booting = true
	if Net.wanted():
		var mode := TownHallLauncher.normalize_mode(String(Settings.get_value("townhall/provider", "fake")))
		await _connect_or_launch(mode, BOOT_WAIT_MS, bool(Settings.get_value("townhall/auto_start", true)))
	if Net.is_online() and await link.open_online_town(map_seed):
		booting = false
		return
	booting = false
	new_town(map_seed)


## Looks for a Town Hall for up to `wait_ms`; when none answers (no runtime file, or a stale one)
## and `allow_launch`, starts one in `mode` and waits up to LAUNCH_WAIT_MS for it, or until its
## log says it could not start. Returns whether Net is online.
func _connect_or_launch(mode: String, wait_ms: int, allow_launch: bool) -> bool:
	Net.restart_search()
	var deadline := Time.get_ticks_msec() + wait_ms
	var launched := false
	var log_offset := 0
	var next_log_check := 0
	_launch_error = ""
	while not Net.is_online() and Time.get_ticks_msec() < deadline:
		if Net.status == Net.STATUS_BUSY or Net.status == Net.STATUS_REJECTED:
			break
		# No Town Hall found: no runtime file, or one whose Town Hall did not answer.
		var missing := (Net.status == Net.STATUS_SEARCHING and Net.endpoint.is_empty() and Net.attempts > 0) or Net.failures > 0
		if missing and not launched:
			if not allow_launch:
				break
			log_offset = TownHallLauncher.file_size(TownHallLauncher.log_file_for(mode))
			if not _start_town_hall(mode):
				break
			launched = true
			deadline = Time.get_ticks_msec() + LAUNCH_WAIT_MS
		if launched and Time.get_ticks_msec() >= next_log_check:
			next_log_check = Time.get_ticks_msec() + 500
			_launch_error = TownHallLauncher.launch_failure(mode, log_offset)
			if _launch_error != "":
				ClientLog.warn("townhall", "The %s Town Hall could not start: %s" % [mode, _launch_error])
				break
		await get_tree().process_frame
	return Net.is_online()


## Starts a Town Hall in `mode` when it can be found (desktop dev layout).
func _start_town_hall(mode: String) -> bool:
	if TownHallLauncher.find_dir() == "":
		return false
	if TownHallLauncher.start(mode) <= 0:
		Notify.push("Could not start the Town Hall. Is Node.js installed?", "warn", "hall_start", 5000)
		return false
	_launched_data_dir = TownHallLauncher.data_dir_for(mode)
	_launched_pid = 0
	Notify.push("Starting the %s Town Hall..." % _mode_name(mode), "info", "hall_start", 3000)
	Net.reconnect_now()
	return true


# --- the Town Hall: which one, switching and closing -------------------------------------------

## The connected Town Hall's mode, from its hello: "real" (the installed harnesses), "fake"
## (practice: scripted agents), or "" when none is connected or it does not say.
func town_hall_mode() -> String:
	return Net.town_hall_mode() if Net.is_online() else ""


## True when the connected Town Hall is one this game started (rather than one started by hand).
func town_hall_launched_by_game() -> bool:
	if not Net.is_online() or _launched_data_dir == "":
		return false
	var ep: Dictionary = Net.endpoint
	if not TownHallLauncher.same_dir(J.gs(ep, "data_dir"), _launched_data_dir):
		return false
	var pid := J.gi(ep, "pid")
	return pid == 0 or _launched_pid == 0 or pid == _launched_pid


## True while the game is switching or closing the Town Hall.
func town_hall_busy() -> bool:
	return _hall_busy


## Moves the game to the Town Hall of `mode` ("real" or "fake"): remembers it in
## townhall/provider, saves the town, asks the current Town Hall to shut down and waits for it to
## end, starts (or finds) the other mode's Town Hall and opens that mode's town. Also works with
## no Town Hall connected (it then only starts and opens). On any failure the player is told and
## keeps a town: the current one when nothing was closed yet, else an offline town.
func switch_town_hall_mode(mode: String) -> void:
	if mode != TownHallLauncher.MODE_REAL and mode != TownHallLauncher.MODE_FAKE:
		push_warning("switch_town_hall_mode: unknown mode %s" % mode)
		return
	if _hall_busy:
		Notify.push("The Town Hall is already changing.", "warn", "hall_switch", 2000)
		return
	_set_hall_busy(true)
	await _switch_to(mode)
	_set_hall_busy(false)


## Opens the Town Hall of the remembered mode (townhall/provider): after close_town_hall(), say.
func open_town_hall() -> void:
	await switch_town_hall_mode(TownHallLauncher.normalize_mode(String(Settings.get_value("townhall/provider", "fake"))))


## Saves the town, shuts the connected Town Hall down (its running tasks pause and resume when it
## starts again) and carries on in an offline town. The top bar then offers the Town Hall again
## as soon as one runs; open_town_hall() starts it.
func close_town_hall() -> void:
	if _hall_busy:
		Notify.push("The Town Hall is already changing.", "warn", "hall_switch", 2000)
		return
	if not Net.is_online():
		Notify.push("No Town Hall is connected.", "info", "hall_switch", 2000)
		return
	_set_hall_busy(true)
	Notify.push("Closing the Town Hall...", "info", "hall_switch", 0)
	if await _shut_down_town_hall():
		# The Town Hall's town cannot go on without it; an offline town the player had stays.
		if world == null or is_online_town():
			new_town(int(Settings.get_value("game/seed", 4127)))
		Net.restart_search()
		Notify.push("The Town Hall is closed; this town plays offline.", "info", "hall_switch", 0)
	_set_hall_busy(false)


func _switch_to(mode: String) -> void:
	var map_seed := int(Settings.get_value("game/seed", 4127))
	if town_hall_mode() == mode:
		Settings.set_value("townhall/provider", mode)
		if not is_online_town():
			await link.open_online_town(map_seed)
		return
	# Before closing anything: the other mode must be reachable or startable from here.
	var target_runtime := TownHallLauncher.runtime_file_for(mode)
	if TownHallLauncher.find_dir() == "" and (target_runtime == "" or not FileAccess.file_exists(target_runtime)):
		Notify.push("The %s Town Hall cannot be started from this game." % _mode_name(mode), "error", "hall_switch", 0)
		return
	Settings.set_value("townhall/provider", mode)
	if Net.is_online():
		Notify.push("Closing the %s Town Hall..." % _mode_name(town_hall_mode()), "info", "hall_switch", 0)
		if not await _shut_down_town_hall():
			return
	Notify.push("Opening the %s Town Hall..." % _mode_name(mode), "info", "hall_switch", 0)
	Net.forget_session()
	Net.pin_runtime(target_runtime)
	var online := await _connect_or_launch(mode, BOOT_WAIT_MS, true)
	Net.unpin_runtime()
	if online and town_hall_mode() == mode and await link.open_online_town(map_seed):
		Notify.push("This is the %s town." % _mode_name(mode), "good", "hall_switch", 0)
		return
	var why := _launch_error if _launch_error != "" else (Net.last_problem if Net.last_problem != "" else "it did not answer")
	_offline_fallback(map_seed, "Could not open the %s Town Hall (%s). Playing offline." % [_mode_name(mode), why])


## Saves the town, asks the connected Town Hall to shut down, and waits for the connection to
## close and the process to end. False (and the Town Hall stays) when the save or the request
## fails; the player is told why.
func _shut_down_town_hall() -> bool:
	var ep: Dictionary = Net.endpoint.duplicate()
	if is_online_town():
		var save: NetRequest = link.save_now()
		if save != null:
			await _wait_until(func() -> bool: return save.finished, CLOSE_SAVE_WAIT_MS)
			if not save.ok:
				var why := save.error_message() if save.finished else "no answer"
				Notify.push("Could not save the town (%s); the Town Hall stays open." % why, "error", "hall_switch", 0)
				return false
	if not Net.has_feature("shutdown"):
		Notify.push("This Town Hall cannot be closed from the game: stop it where it was started.", "error", "hall_switch", 0)
		return false
	var req := Net.request(Protocol.CMD_SHUTDOWN)
	await req.done
	if not req.ok and req.error_code() != NetRequest.DISCONNECTED:
		Notify.push("The Town Hall did not close: %s" % req.error_message(), "error", "hall_switch", 0)
		return false
	# It closes the connection right after its reply; stop looking for it meanwhile.
	await _wait_until(func() -> bool: return not Net.is_online(), CLOSE_DISCONNECT_WAIT_MS)
	Net.enable(false)
	if not await _wait_hall_exit(J.gs(ep, "source"), J.gi(ep, "pid"), CLOSE_EXIT_WAIT_MS):
		ClientLog.warn("townhall", "The Town Hall (pid %d) was still running %d s after it was asked to close." % [J.gi(ep, "pid"), CLOSE_EXIT_WAIT_MS / 1000])
	if TownHallLauncher.same_dir(J.gs(ep, "data_dir"), _launched_data_dir):
		_launched_data_dir = ""
		_launched_pid = 0
	return true


## Waits until the Town Hall that wrote `runtime_path` has removed it (the last thing it does)
## and its process `pid` has ended. True when both happened within `ms`.
func _wait_hall_exit(runtime_path: String, pid: int, ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + ms
	var next_check := 0
	while Time.get_ticks_msec() < deadline:
		var info := TownHallDiscovery.read_runtime_file(runtime_path) if runtime_path != "" else {}
		var still_listed := not info.is_empty() and (pid <= 0 or J.gi(info, "pid") == pid)
		if not still_listed and Time.get_ticks_msec() >= next_check:
			if not TownHallLauncher.process_alive(pid):
				return true
			next_check = Time.get_ticks_msec() + 500
		await get_tree().process_frame
	return false


## The player keeps a town whatever happens: an offline one, while Net keeps looking.
func _offline_fallback(map_seed: int, message: String) -> void:
	Notify.push(message, "error", "hall_switch", 0)
	Net.unpin_runtime()
	Net.restart_search()
	if world == null or is_online_town():
		new_town(map_seed)


func _wait_until(cond: Callable, ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + ms
	while not bool(cond.call()):
		if Time.get_ticks_msec() >= deadline:
			return false
		await get_tree().process_frame
	return true


func _set_hall_busy(busy: bool) -> void:
	_hall_busy = busy


func _on_net_connection(online: bool) -> void:
	if online and _launched_data_dir != "" and _launched_pid == 0:
		var ep: Dictionary = Net.endpoint
		if TownHallLauncher.same_dir(J.gs(ep, "data_dir"), _launched_data_dir):
			_launched_pid = J.gi(ep, "pid")
	var mode := town_hall_mode()
	if mode != _hall_mode:
		_hall_mode = mode
		town_hall_mode_changed.emit(mode)


static func _mode_name(mode: String) -> String:
	return String(MODE_NAMES.get(mode, "unknown"))


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
	if world == null or paused:
		_last_usec = 0
		return
	var now := Time.get_ticks_usec()
	var real := float(now - _last_usec) / 1000000.0 if _last_usec > 0 else delta
	_last_usec = now
	var tick_dt := world.dt
	_accumulator += minf(maxf(real, 0.0), MAX_FRAME_DELTA) * time_scale
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
