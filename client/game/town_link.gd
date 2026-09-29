class_name TownLink
extends Node
## The online half of the game: connects the running town (Game.world) with the Town Hall
## (Net and Realm). It
## - opens and saves the Town Hall's town (load_town / save_town) and keeps the RemoteLedger
##   in step with the Town Hall's treasury;
## - mirrors the Town Hall's agents into the simulation: agents in training at the Keep, their
##   figures, homes, add-ons and what they are doing (reconcile() after every full state, then
##   single events), always through GameCommands;
## - turns simulation notices into Town Hall commands: agent_trained, home_built, tool_built,
##   task_delivered;
## - builds each agent's starting add-ons once its home stands (attach_tool, then place_tool);
## - offers the player's actions to the HUD: summon an agent, choose its plot, add an add-on,
##   send a task by courier, answer approvals, review results.
## Everything the Town Hall already decided arrives as a command, so the command log stays
## complete; nothing here changes the simulation directly.

## The running town became (or stopped being) the Town Hall's.
signal online_changed(online: bool)
## An agent finished training and waits for the player to choose its plot.
signal plot_needed(agent_id: String)
## Offline play while a Town Hall is reachable: the HUD offers to open the Town Hall's town.
signal town_available()

const Protocol = preload("res://net/protocol.gd")

const SAVE_EVERY_S := 60.0
const SAVE_SOON_S := 2.0
const TICK_EVERY_S := 1.0
const TOOL_RETRY_S := 5.0
const TOOL_ERROR_RETRY_S := 30.0
## A dropped scroll is picked up by a wisp after this long.
const DROPPED_WISP_DELAY_S := 1.0
const SNAPSHOT_ENCODING := "json+gzip+base64"

## Tool names the harnesses use, matched to the add-on that grants them (lowercase substrings,
## checked in order).
const TOOL_ADDONS := [
	["mcp", "waygate"],
	["websearch", "rookery"], ["webfetch", "rookery"], ["web_search", "rookery"], ["fetch", "rookery"],
	["bash", "forge"], ["shell", "forge"], ["command", "forge"], ["exec", "forge"], ["powershell", "forge"],
	["edit", "quillworks"], ["write", "quillworks"], ["patch", "quillworks"], ["filechange", "quillworks"],
	["read", "lectern"], ["grep", "lectern"], ["glob", "lectern"], ["find", "lectern"], ["ls", "lectern"],
]

var ledger: RemoteLedger
## True while the running town is the Town Hall's (online play).
var online_town: bool = false
var town_rev: int = 0
## agent_id -> {"tool": String, "missing": Dictionary}: add-ons waiting for resources.
var waiting_tools: Dictionary = {}

var _tick_timer: float = 0.0
var _save_timer: float = SAVE_EVERY_S
var _saving: bool = false
var _tool_retry_at: Dictionary = {}
var _tool_pending: Dictionary = {}
var _plot_announced: Dictionary = {}
var _offered: bool = false
## agent_id -> unit id picked by the player to carry that agent's next scroll.
var _next_courier: Dictionary = {}


func _ready() -> void:
	Net.connection_changed.connect(_on_connection)
	Realm.reset.connect(_on_reset)
	Realm.treasury_event.connect(_on_treasury)
	Realm.agent_changed.connect(_on_agent_changed)
	Realm.agent_retired.connect(_on_agent_retired)
	Realm.tool_changed.connect(_on_tool_changed)
	Realm.task_changed.connect(_on_task_changed)
	Realm.task_progress.connect(_on_task_progress)
	Realm.age_changed.connect(_on_age_changed)
	Realm.approval_requested.connect(_on_approval_requested)
	Realm.incident_opened.connect(_on_incident_opened)
	Game.world_started.connect(_on_world_started)
	Game.world_stopped.connect(_on_world_stopped)


func world() -> SimWorld:
	return Game.world


## True when the town is the Town Hall's and the link is up (agent actions are possible).
func is_live() -> bool:
	return online_town and Net.is_online() and Realm.has_state


# --- opening and saving the Town Hall's town ---------------------------------------------------

## Loads the Town Hall's town, or starts a new one there from `map_seed`. Requires Net online.
func open_online_town(map_seed: int) -> bool:
	var req := Net.request(Protocol.CMD_LOAD_TOWN)
	await req.done
	if not req.ok:
		Notify.push("Could not load the town from the Town Hall: %s" % req.error_message(), "error")
		return false
	var l := RemoteLedger.new(Economy.data, {}, Economy.data.start_age())
	l.send = Net.request
	var w: SimWorld = null
	var saved := req.payload_dict()
	if not saved.is_empty() and typeof(saved.get("snapshot")) == TYPE_DICTIONARY:
		var snap := decode_snapshot(saved["snapshot"])
		var sim: Variant = snap.get("sim")
		if typeof(sim) == TYPE_DICTIONARY:
			w = SimWorld.from_dict(sim, Economy.data, l)
			if w == null:
				Notify.push("The Town Hall's town was saved by a newer version of the game.", "error")
				return false
			var ls: Variant = snap.get("ledger")
			if typeof(ls) == TYPE_DICTIONARY:
				l.load_dict(ls)
			town_rev = int(saved.get("rev", 0))
	if w == null:
		w = SimWorld.create_new(Economy.data, l, map_seed, "hall-%08x" % (randi() & 0x7fffffff))
		town_rev = 0
	Game.stop_town()
	l.op_prefix = "%s:%s" % [w.town_id, w.session]
	ledger = l
	online_town = true
	Economy.set_ledger(l)
	l.set_server_treasury(Realm.treasury)
	l.set_online(Net.is_online())
	Game.start_world(w)
	online_changed.emit(true)
	_save_timer = SAVE_SOON_S if town_rev == 0 else SAVE_EVERY_S
	return true


## Sends the town to the Town Hall now. Returns the request (or null when not possible).
func save_now() -> NetRequest:
	var w := world()
	if not is_live() or w == null or _saving:
		return null
	ledger.flush()
	var snapshot := encode_snapshot({"sim": w.to_dict(), "ledger": ledger.to_dict(),
		"client": {"version": String(ProjectSettings.get_setting("application/config/version", "0"))}})
	var req := Net.request(Protocol.CMD_SAVE_TOWN, {"base_rev": town_rev, "schema_version": SimConst.SCHEMA_VERSION, "snapshot": snapshot})
	_saving = true
	_save_timer = SAVE_EVERY_S
	req.done.connect(_on_saved)
	return req


func _on_saved(req: NetRequest) -> void:
	_saving = false
	if req.ok:
		town_rev = int(req.payload_dict().get("rev", town_rev))
		return
	if req.error_code() == Protocol.ERR_CONFLICT:
		Notify.push("Another window saved this town; it will be reloaded.", "warn", "save_conflict", 5000)
		ClientLog.warn("link", "save_town conflict at rev %d" % town_rev)
		town_rev = int(Realm.town.get("rev", town_rev))
	else:
		ClientLog.warn("link", "save_town failed: %s" % req.error_message())
		_save_timer = SAVE_SOON_S * 5.0


func save_soon() -> void:
	_save_timer = minf(_save_timer, SAVE_SOON_S)


## The town save as the Town Hall stores it: the client's own JSON text (full float precision,
## sorted keys), gzipped and base64-encoded. The Town Hall never looks inside, and a JSON round
## trip through it could round floats differently, so the save stays opaque and exact.
static func encode_snapshot(doc: Dictionary) -> Dictionary:
	var raw := JSON.stringify(doc, "", true, true).to_utf8_buffer()
	return {"encoding": SNAPSHOT_ENCODING, "bytes": raw.size(),
		"data": Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_GZIP))}


static func decode_snapshot(snap: Dictionary) -> Dictionary:
	if J.gs(snap, "encoding") != SNAPSHOT_ENCODING:
		return snap
	var packed := Marshalls.base64_to_raw(J.gs(snap, "data"))
	var raw := packed.decompress(J.gi(snap, "bytes"), FileAccess.COMPRESSION_GZIP)
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


# --- per frame -----------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not online_town or world() == null:
		return
	ledger.poll(Time.get_ticks_msec())
	_tick_timer -= delta
	if _tick_timer <= 0.0:
		_tick_timer = TICK_EVERY_S
		if is_live():
			_build_starting_tools()
			_watch_scrolls()
	_save_timer -= delta
	if _save_timer <= 0.0:
		save_now()


# --- Net and Realm -------------------------------------------------------------------------------

func _on_connection(on: bool) -> void:
	if ledger != null:
		ledger.set_online(on and online_town)
	if on and not online_town and Game.world != null and not _offered:
		_offered = true
		town_available.emit()
	online_changed.emit(on and online_town)


func _on_reset() -> void:
	if not online_town:
		return
	ledger.set_server_treasury(Realm.treasury)
	reconcile()


func _on_treasury(t: Dictionary, reason: String, _delta: Dictionary, causation_id: String) -> void:
	if online_town and ledger != null:
		ledger.on_treasury_event(t, reason, causation_id)


func _on_world_started(w: SimWorld) -> void:
	if not online_town:
		return
	w.notice.connect(_on_notice)
	if ledger != null and not ledger.rejected.is_connected(_on_rejected):
		ledger.rejected.connect(_on_rejected)
	Game.issue(GameCommands.set_age(Realm.current_age()))
	# After the views have bound the new world (they hear world_started after us).
	reconcile.call_deferred()


func _on_world_stopped() -> void:
	var was := online_town
	online_town = false
	if was:
		online_changed.emit(false)
	_plot_announced.clear()
	_tool_pending.clear()
	_tool_retry_at.clear()
	waiting_tools.clear()


func _on_rejected(op_id: String, code: String) -> void:
	Game.issue(GameCommands.revoke_spend(op_id))
	if code == Protocol.ERR_INSUFFICIENT_RESOURCES:
		Notify.push("The Town Hall says there were not enough resources; that order was undone.", "warn", "revoked", 3000)


# --- reconciliation ------------------------------------------------------------------------------

## Brings the simulation in line with the Town Hall: every agent in training, on its way, at home
## or retired; every home and add-on. Idempotent; runs after every full state.
func reconcile() -> void:
	var w := world()
	if w == null or not online_town or not Realm.has_state:
		return
	var known := {}
	for a: Dictionary in Realm.agents.values():
		var id := String(a["id"])
		known[id] = true
		if J.gs(a, "lifecycle", "") == Protocol.AgentLifecycle.RETIRED:
			if w.agent_unit(id) != null or w.agent_home(id) != null or not w.queued_agent(id).is_empty():
				Game.issue(GameCommands.drop_agent(id))
			continue
		_reconcile_agent(w, a)
	var strays := {}
	for u: SimUnit in w.units.values():
		if u.kind == "agent" and not known.has(u.agent_id):
			strays[u.agent_id] = true
	for b: SimBuilding in w.buildings.values():
		if b.owner_agent_id != "" and not known.has(b.owner_agent_id):
			strays[b.owner_agent_id] = true
		for item in b.queue:
			var qa := J.gs(item, "agent_id", "")
			if qa != "" and not known.has(qa):
				strays[qa] = true
	for id: String in strays:
		Game.issue(GameCommands.drop_agent(id))


func _reconcile_agent(w: SimWorld, a: Dictionary) -> void:
	var id := String(a["id"])
	var role := J.gs(a, "role", "")
	var home_type := w.econ.role_home(role)
	if J.gs(a, "lifecycle", "") == Protocol.AgentLifecycle.TRAINING:
		if w.agent_unit(id) == null and w.queued_agent(id).is_empty():
			var ticks := int(round(w.econ.role_train_s(role) * float(w.tick_rate)))
			Game.issue(GameCommands.queue_agent(w.keep_id, id, role, ticks))
		return
	var home_b := w.agent_home(id)
	var home: Variant = a.get("home")
	if typeof(home) == TYPE_DICTIONARY:
		var tile: Dictionary = home.get("tile", {})
		var cell := Vector2i(int(tile.get("x", 0)), int(tile.get("y", 0)))
		var built := bool(home.get("built", false))
		if home_b == null:
			Game.issue(GameCommands.place_home(id, home_type, cell, built))
		elif built and not home_b.complete:
			Game.issue(GameCommands.complete_building(home_b.id))
		elif not built and home_b.complete:
			Net.request(Protocol.CMD_HOME_BUILT, {"agent_id": id})
	if w.agent_unit(id) == null:
		var at := Pathing.NO_CELL
		if typeof(home) == TYPE_DICTIONARY:
			var t: Dictionary = home.get("tile", {})
			at = HomeLayout.door_cell(Rect2i(Vector2i(int(t.get("x", 0)), int(t.get("y", 0))), w.econ.building_footprint(home_type)))
		elif w.keep() != null:
			var exits := w.exit_cells(w.keep(), w.rally_point(w.keep()))
			at = exits[0] if not exits.is_empty() else Vector2i(w.map_center())
		Game.issue(GameCommands.spawn_agent(id, role, at))
	if typeof(home) != TYPE_DICTIONARY and not _plot_announced.has(id):
		_plot_announced[id] = true
		plot_needed.emit(id)
	for t in Realm.tools_of(id):
		_reconcile_tool(w, t)
	for b in w.agent_tools(id):
		var t := Realm.tools.get(b.tool_id, {}) as Dictionary
		if t.is_empty() or J.gs(t, "status", "") == Protocol.ToolStatus.REMOVED:
			Game.issue(GameCommands.remove_tool(b.tool_id))
	_sync_state(a)


func _reconcile_tool(w: SimWorld, t: Dictionary) -> void:
	var tool_id := String(t["id"])
	var status := J.gs(t, "status", "")
	var b := w.tool_building(tool_id)
	if status == Protocol.ToolStatus.REMOVED:
		if b != null:
			Game.issue(GameCommands.remove_tool(tool_id))
		return
	if b == null:
		var tile: Dictionary = t.get("tile", {})
		Game.issue(GameCommands.place_tool(J.gs(t, "agent_id", ""), tool_id, J.gs(t, "type", ""),
			Vector2i(int(tile.get("x", 0)), int(tile.get("y", 0))), status == Protocol.ToolStatus.ACTIVE))
	elif status == Protocol.ToolStatus.ACTIVE and not b.complete:
		Game.issue(GameCommands.complete_building(b.id))
	elif status == Protocol.ToolStatus.BUILDING and b.complete:
		Net.request(Protocol.CMD_TOOL_BUILT, {"tool_id": tool_id})


## The figure's activity and the add-on it uses, from the agent and its task's progress.
func _sync_state(a: Dictionary) -> void:
	var id := String(a["id"])
	var activity := J.gs(a, "activity", "idle")
	var tool := ""
	var cur := Realm.current_task(id)
	if not cur.is_empty():
		var p: Dictionary = Realm.progress.get(String(cur["id"]), {})
		tool = addon_for_tool(J.gs(p, "current_tool", ""))
	var u := world().agent_unit(id) if world() != null else null
	if u != null and (u.activity != activity or u.work_tool != tool):
		Game.issue(GameCommands.set_agent_state(id, activity, tool))


## The add-on type that grants a harness tool name ("Bash" -> "forge"), or "".
static func addon_for_tool(tool_name: String) -> String:
	var n := tool_name.to_lower()
	if n == "":
		return ""
	for pair: Array in TOOL_ADDONS:
		if n.contains(String(pair[0])):
			return String(pair[1])
	return ""


# --- Town Hall events ----------------------------------------------------------------------------

func _on_agent_changed(a: Dictionary) -> void:
	var w := world()
	if not online_town or w == null:
		return
	if J.gs(a, "lifecycle", "") == Protocol.AgentLifecycle.RETIRED:
		Game.issue(GameCommands.drop_agent(String(a["id"])))
		return
	_reconcile_agent(w, a)


func _on_agent_retired(agent_id: String) -> void:
	if online_town and world() != null:
		Game.issue(GameCommands.drop_agent(agent_id))


func _on_tool_changed(t: Dictionary) -> void:
	var w := world()
	if online_town and w != null:
		_reconcile_tool(w, t)


func _on_task_changed(t: Dictionary, before: String) -> void:
	if not online_town or world() == null:
		return
	var id := String(t["id"])
	var state := J.gs(t, "state", "")
	if before == Protocol.TaskState.IN_TRANSIT and state != Protocol.TaskState.IN_TRANSIT:
		Game.issue(GameCommands.cancel_courier(id))
	if state == before:
		return
	var who := String(Realm.agent(J.gs(t, "agent_id", "")).get("name", "An agent"))
	var title := J.gs(t, "title", "")
	if state == Protocol.TaskState.AWAITING_REVIEW:
		Notify.push("%s finished \"%s\". Review it at their home." % [who, title], "good", "review_" + id, 0)
		Audio.play("task_done")
	elif state == Protocol.TaskState.FAILED:
		Notify.push("%s could not finish \"%s\"." % [who, title], "error", "failed_" + id, 0)
	elif state == Protocol.TaskState.PAUSED:
		Notify.push("%s paused \"%s\": %s." % [who, title, _pause_reason(t)], "warn", "paused_" + id, 0)
	elif state == Protocol.TaskState.ACCEPTED:
		var rewards: Variant = t.get("rewards")
		if typeof(rewards) == TYPE_DICTIONARY:
			Notify.push("Reward for \"%s\": %s." % [title, Game._res_list((rewards as Dictionary).get("resources", {}))], "good", "reward_" + id, 0)
			Audio.play("reward")


static func _pause_reason(t: Dictionary) -> String:
	match J.gs(t, "state_reason", ""):
		"budget":
			return "its Mana seal is spent"
		"mana_depleted":
			return "the Mana pool is empty"
		"stalled":
			return "no progress for a long time"
		"restart":
			return "the Town Hall restarted"
		"provider_limit":
			return "the provider's usage limit"
	return "waiting"


func _on_task_progress(task_id: String, _p: Dictionary) -> void:
	if not online_town or world() == null:
		return
	var t := Realm.task(task_id)
	if not t.is_empty():
		var a := Realm.agent(J.gs(t, "agent_id", ""))
		if not a.is_empty():
			_sync_state(a)


func _on_age_changed(age: Dictionary) -> void:
	if online_town and world() != null:
		Game.issue(GameCommands.set_age(maxi(int(age.get("current", 1)), 1)))


func _on_approval_requested(ap: Dictionary) -> void:
	if not online_town:
		return
	var who := String(Realm.agent(J.gs(ap, "agent_id", "")).get("name", "An agent"))
	Notify.push("%s asks: %s" % [who, J.gs(ap, "summary", "may I?")], "warn", "approval_" + J.gs(ap, "id", ""), 0)
	Audio.play("hand_bell")


func _on_incident_opened(i: Dictionary) -> void:
	# Waiting approvals already have their own toast (and the bell over the home).
	if not online_town or J.gs(i, "kind") == "hand_bell":
		return
	var kind := J.gs(i, "severity", "info")
	Notify.push(J.gs(i, "message", "Something happened."), "error" if kind == "urgent" else ("warn" if kind == "warn" else "info"),
		"incident_" + J.gs(i, "id", ""), 0)


# --- simulation notices --------------------------------------------------------------------------

func _on_notice(kind: String, data: Dictionary) -> void:
	if not online_town:
		return
	match kind:
		"agent_trained":
			var id := J.gs(data, "agent_id", "")
			Net.request(Protocol.CMD_AGENT_TRAINED, {"agent_id": id})
			var name := J.gs(Realm.agent(id), "name", "Your agent")
			Notify.push("%s is ready. Choose a plot for their home." % name, "good", "trained_" + id, 0)
			Audio.play("train_complete")
			if not _plot_announced.has(id):
				_plot_announced[id] = true
				plot_needed.emit(id)
		"home_complete":
			Net.request(Protocol.CMD_HOME_BUILT, {"agent_id": J.gs(data, "agent_id", "")})
			save_soon()
		"tool_complete":
			Net.request(Protocol.CMD_TOOL_BUILT, {"tool_id": J.gs(data, "tool_id", "")})
			save_soon()
		"courier_arrived":
			var p: Dictionary = data.get("payload", {})
			_delivered(J.gs(p, "task_id", ""))
		"wisp_arrived":
			_delivered(J.gs(data, "task_id", ""))
		"courier_dropped", "courier_failed":
			var p: Dictionary = data.get("payload", {})
			_send_wisp(J.gs(p, "task_id", ""), DROPPED_WISP_DELAY_S)
		"cancel_agent":
			cancel_summon(J.gs(data, "agent_id", ""))
		"home_blocked":
			Notify.push("A home could not be placed where the Town Hall recorded it.", "error", "home_blocked", 5000)


func _delivered(task_id: String) -> void:
	if task_id == "":
		return
	var t := Realm.task(task_id)
	if not t.is_empty() and J.gs(t, "state", "") != Protocol.TaskState.IN_TRANSIT:
		return
	Net.request(Protocol.CMD_TASK_DELIVERED, {"task_id": task_id})


# --- starting add-ons ------------------------------------------------------------------------------

## Attaches each agent's next missing starting add-on once its home stands: required ones first,
## never before the add-ons they require. A shortfall is retried every few seconds.
func _build_starting_tools() -> void:
	var w := world()
	var now := Time.get_ticks_msec()
	for a in Realm.active_agents():
		var id := String(a["id"])
		if _tool_pending.has(id) or now < int(_tool_retry_at.get(id, 0)):
			continue
		var home_b := w.agent_home(id)
		if home_b == null or not home_b.complete:
			continue
		var next := next_starting_tool(w.econ, a, Realm.tools_of(id))
		if next == "":
			waiting_tools.erase(id)
			continue
		if Realm.tools_of(id).size() >= w.econ.tool_slots(Realm.current_age()):
			continue
		var req := attach_tool(id, next)
		if req == null:
			_tool_retry_at[id] = now + int(TOOL_ERROR_RETRY_S * 1000.0)
			continue
		_tool_pending[id] = true
		req.done.connect(_on_auto_attach.bind(id, next))


func _on_auto_attach(req: NetRequest, agent_id: String, type: String) -> void:
	_tool_pending.erase(agent_id)
	if req.ok:
		waiting_tools.erase(agent_id)
		return
	var now := Time.get_ticks_msec()
	if req.error_code() == Protocol.ERR_INSUFFICIENT_RESOURCES:
		waiting_tools[agent_id] = {"tool": type, "missing": Economy.ledger.missing(Economy.data.tool_def(type).get("cost", {}))}
		_tool_retry_at[agent_id] = now + int(TOOL_RETRY_S * 1000.0)
	else:
		ClientLog.warn("link", "attach_tool %s for %s failed: %s" % [type, agent_id, req.error_message()])
		_tool_retry_at[agent_id] = now + int(TOOL_ERROR_RETRY_S * 1000.0)


## The next starting add-on an agent still lacks, in build order, or "".
static func next_starting_tool(econ: EconomyData, agent: Dictionary, tools: Array[Dictionary]) -> String:
	var have: Array[String] = []
	for t in tools:
		have.append(J.gs(t, "type", ""))
	var wanted: Array[String] = []
	for v: Variant in agent.get("starting_tools", []):
		wanted.append(String(v))
	var role := J.gs(agent, "role", "")
	var order: Array[String] = []
	for t in econ.role_tools(role, "required"):
		if t in wanted and not t in order:
			order.append(t)
	for t in wanted:
		if not t in order:
			order.append(t)
	for t in order:
		if t in have:
			continue
		var ready := true
		for req in econ.tool_requires(t):
			if not req in have:
				ready = false
		if ready:
			return t
	return ""


# --- scrolls ------------------------------------------------------------------------------------

## Tasks in transit that nobody carries (a reload, a lost courier) get a wisp.
func _watch_scrolls() -> void:
	var w := world()
	for t: Dictionary in Realm.tasks.values():
		if J.gs(t, "state", "") != Protocol.TaskState.IN_TRANSIT:
			continue
		var id := String(t["id"])
		if _carried(w, id):
			continue
		_send_wisp(id, w.econ.wisp_after_s())


func _carried(w: SimWorld, task_id: String) -> bool:
	for wisp in w.wisps:
		if String(wisp["task_id"]) == task_id:
			return true
	for u: SimUnit in w.units.values():
		if u.job == SimConst.JOB_COURIER and J.gs(u.payload, "task_id", "") == task_id:
			return true
	for cmd: Dictionary in w.commands.pending_snapshot():
		if J.gs(cmd, "task_id", "") == task_id:
			return true
	return false


func _send_wisp(task_id: String, delay_s: float) -> void:
	var w := world()
	var t := Realm.task(task_id)
	if w == null or t.is_empty() or J.gs(t, "state", "") != Protocol.TaskState.IN_TRANSIT:
		return
	var agent_id := J.gs(t, "agent_id", "")
	var home := w.agent_home(agent_id)
	if home == null:
		return
	Game.issue(GameCommands.wisp(home.id, task_id, agent_id, int(round(delay_s * float(w.tick_rate)))))


## Who carries a new scroll: the nearest idle townsperson to the Keep, else the nearest one
## gathering (who goes back to it afterwards). Builders and busy couriers are never pulled away.
func pick_courier() -> SimUnit:
	var w := world()
	if w == null:
		return null
	var at := w.keep().center() if w.keep() != null else w.map_center()
	var best: SimUnit = null
	var best_score := INF
	for u: SimUnit in w.units.values():
		if u.kind != "townsfolk":
			continue
		var penalty := 0.0
		match u.job:
			SimConst.JOB_IDLE:
				penalty = 0.0
			SimConst.JOB_GATHER, SimConst.JOB_DEPOSIT:
				penalty = 1000.0
			_:
				continue
		var score := penalty + u.pos.distance_to(at)
		if score < best_score:
			best_score = score
			best = u
	return best


# --- player actions -------------------------------------------------------------------------------

## Summons an agent: create_agent, then it trains at the Keep. `spec` is create_agent's spec.
func summon(spec: Dictionary) -> NetRequest:
	var req := Net.request(Protocol.CMD_CREATE_AGENT, {"spec": spec})
	req.done.connect(_on_summoned.bind(J.gs(spec, "role", "")))
	return req


func _on_summoned(r: NetRequest, role: String) -> void:
	var w := world()
	if not r.ok or w == null:
		return
	var p := r.payload_dict()
	var training: Dictionary = p.get("training", {})
	var ticks := int(round(float(training.get("duration_ms", 0)) / 1000.0 * float(w.tick_rate)))
	Game.issue(GameCommands.queue_agent(w.keep_id, J.gs(p, "agent_id", ""), role, maxi(ticks, 1)))
	save_soon()


## Cancels an agent still in training (the Town Hall refunds it in full).
func cancel_summon(agent_id: String) -> NetRequest:
	var req := Net.request(Protocol.CMD_RETIRE_AGENT, {"agent_id": agent_id, "when": Protocol.RetireWhen.NOW})
	req.done.connect(_on_summon_cancelled.bind(agent_id))
	return req


func _on_summon_cancelled(r: NetRequest, agent_id: String) -> void:
	if r.ok:
		Game.issue(GameCommands.drop_agent(agent_id))
	else:
		Notify.push(r.error_message(), "warn")


## The home type an agent builds.
func home_type(agent_id: String) -> String:
	return Economy.data.role_home(J.gs(Realm.agent(agent_id), "role", ""))


## Places an agent's home with its plot. `cell` is the home's top-left cell.
func place_home(agent_id: String, cell: Vector2i) -> NetRequest:
	var w := world()
	var type := home_type(agent_id)
	var check := Placement.check_plot(w, type, cell)
	if not bool(check.get("ok", false)):
		var r := NetRequest.new(Protocol.CMD_PLACE_HOME)
		r.fail(Protocol.ERR_BAD_REQUEST, J.gs(check, "reason", "Can't build there."), false)
		return r
	var req := Net.request(Protocol.CMD_PLACE_HOME, {"agent_id": agent_id, "tile": {"x": cell.x, "y": cell.y}})
	req.done.connect(_on_home_placed.bind(agent_id, type, cell))
	return req


func _on_home_placed(r: NetRequest, agent_id: String, type: String, cell: Vector2i) -> void:
	if r.ok:
		Game.issue(GameCommands.place_home(agent_id, type, cell))
		save_soon()


## Adds an add-on to an agent's plot (the next free spot of its ring). Returns null when the
## plot is full or the agent has no home yet.
func attach_tool(agent_id: String, type: String, config: Dictionary = {}) -> NetRequest:
	var w := world()
	var home := w.agent_home(agent_id) if w != null else null
	if home == null:
		return null
	var taken: Array[Rect2i] = []
	for t in w.agent_tools(agent_id):
		taken.append(t.rect())
	var blocked := func(c: Vector2i) -> bool:
		if w.grid.terrain_at(c) == SimGrid.TERRAIN_ROCK:
			return true
		var occ := w.grid.occupant_at(c)
		if occ == 0:
			return false
		if w.buildings.has(occ):
			return true
		var n: SimResourceNode = w.nodes.get(occ)
		return n != null and n.is_live()
	var cell := HomeLayout.tool_cell(home.plot, w.econ.building_footprint(type), taken, blocked)
	if cell == Pathing.NO_CELL:
		Notify.push("No room left on %s's plot." % J.gs(Realm.agent(agent_id), "name", "the agent"), "warn", "plot_full", 3000)
		return null
	var payload := {"agent_id": agent_id, "type": type, "tile": {"x": cell.x, "y": cell.y}}
	if not config.is_empty():
		payload["config"] = config
	var req := Net.request(Protocol.CMD_ATTACH_TOOL, payload)
	req.done.connect(_on_tool_attached.bind(agent_id, type, cell))
	return req


func _on_tool_attached(r: NetRequest, agent_id: String, type: String, cell: Vector2i) -> void:
	if r.ok:
		Game.issue(GameCommands.place_tool(agent_id, J.gs(r.payload_dict(), "tool_id", ""), type, cell))


func detach_tool(tool_id: String) -> NetRequest:
	return Net.request(Protocol.CMD_DETACH_TOOL, {"tool_id": tool_id})


## Sends a task. `spec`: {title, prompt, size, acceptance?, rite?, seal_mana?, express?}.
## A townsperson carries the scroll when one is free (the one the player picked with a
## right-click on the home, if any), else a Font Wisp after a while; express (or the
## express_dispatch setting) skips the walk.
func assign_task(agent_id: String, spec: Dictionary) -> NetRequest:
	var w := world()
	var home := w.agent_home(agent_id) if w != null else null
	var courier := {"mode": Protocol.CourierMode.WISP}
	var carrier: SimUnit = null
	if bool(spec.get("express", false)) or bool(Realm.settings.get("express_dispatch", false)):
		courier = {"mode": Protocol.CourierMode.EXPRESS}
	elif home != null:
		carrier = _chosen_courier(agent_id)
		if carrier == null:
			carrier = pick_courier()
		if carrier != null:
			courier = {"mode": Protocol.CourierMode.HUMAN, "human_id": "u%d" % carrier.id}
	var payload := spec.duplicate(true)
	payload.erase("express")
	payload["agent_id"] = agent_id
	payload["courier"] = courier
	var req := Net.request(Protocol.CMD_ASSIGN_TASK, payload)
	req.done.connect(_on_task_assigned.bind(agent_id, String(courier["mode"]), carrier.id if carrier != null else 0,
		home.id if home != null else 0))
	return req


func _on_task_assigned(r: NetRequest, agent_id: String, mode: String, carrier_id: int, home_id: int) -> void:
	var w := world()
	if not r.ok or w == null or home_id == 0:
		return
	var task_id := J.gs(r.payload_dict(), "task_id", "")
	if mode == Protocol.CourierMode.HUMAN:
		Game.issue(GameCommands.courier(carrier_id, home_id, task_id, agent_id))
	elif mode == Protocol.CourierMode.WISP:
		Game.issue(GameCommands.wisp(home_id, task_id, agent_id, int(round(w.econ.wisp_after_s() * float(w.tick_rate)))))


## Townsfolk right-clicked onto an agent's home: the first of them carries the agent's oldest
## scroll still in transit (taking it from a waiting wisp). Returns false when there is none;
## the unit is then remembered as the courier of the next task sent to that agent.
func manual_courier(unit_ids: Array, agent_id: String) -> bool:
	var w := world()
	var home := w.agent_home(agent_id) if w != null else null
	if home == null or unit_ids.is_empty():
		return false
	var carrier: SimUnit = w.units.get(int(unit_ids[0]))
	if carrier == null or carrier.kind != "townsfolk":
		return false
	var oldest: Dictionary = {}
	for t in Realm.tasks_of(agent_id):
		if J.gs(t, "state") == Protocol.TaskState.IN_TRANSIT:
			oldest = t
			break
	if oldest.is_empty():
		_next_courier[agent_id] = carrier.id
		return false
	var task_id := J.gs(oldest, "id")
	Game.issue(GameCommands.cancel_courier(task_id))
	Game.issue(GameCommands.courier(carrier.id, home.id, task_id, agent_id))
	return true


func _chosen_courier(agent_id: String) -> SimUnit:
	var id := int(_next_courier.get(agent_id, 0))
	_next_courier.erase(agent_id)
	var u: SimUnit = world().units.get(id) if id != 0 else null
	if u == null or u.kind != "townsfolk" or u.job == SimConst.JOB_BUILD or u.job == SimConst.JOB_COURIER:
		return null
	return u


func respond_approval(approval_id: String, decision: String, scope: String, message: String = "") -> NetRequest:
	var payload := {"approval_id": approval_id, "decision": decision, "scope": scope}
	if message.strip_edges() != "":
		payload["message"] = message.strip_edges()
	return Net.request(Protocol.CMD_RESPOND_APPROVAL, payload)


func task_detail(task_id: String, include: Array = ["activity", "diff"]) -> NetRequest:
	return Net.request(Protocol.CMD_GET_TASK_DETAIL, {"task_id": task_id, "include": include})


func accept_result(task_id: String, integrate: String) -> NetRequest:
	return Net.request(Protocol.CMD_ACCEPT_RESULT, {"task_id": task_id, "integrate": integrate})


func send_back(task_id: String, feedback: String) -> NetRequest:
	return Net.request(Protocol.CMD_SEND_BACK, {"task_id": task_id, "feedback": feedback})


func abandon_task(task_id: String) -> NetRequest:
	return Net.request(Protocol.CMD_ABANDON_TASK, {"task_id": task_id})


func cancel_task(task_id: String) -> NetRequest:
	return Net.request(Protocol.CMD_CANCEL_TASK, {"task_id": task_id})


func resume_task(task_id: String, extend_seal_mana: int = 0) -> NetRequest:
	var payload := {"task_id": task_id}
	if extend_seal_mana > 0:
		payload["extend_seal_mana"] = extend_seal_mana
	return Net.request(Protocol.CMD_RESUME_TASK, payload)


func stop_and_review(task_id: String) -> NetRequest:
	return Net.request(Protocol.CMD_STOP_AND_REVIEW, {"task_id": task_id})


func nudge_task(task_id: String, message: String) -> NetRequest:
	return Net.request(Protocol.CMD_NUDGE_TASK, {"task_id": task_id, "message": message})


func retire_agent(agent_id: String, when: String = Protocol.RetireWhen.AFTER_CURRENT) -> NetRequest:
	return Net.request(Protocol.CMD_RETIRE_AGENT, {"agent_id": agent_id, "when": when})


func update_agent(agent_id: String, patch: Dictionary) -> NetRequest:
	var a := Realm.agent(agent_id)
	return Net.request(Protocol.CMD_UPDATE_AGENT, {"agent_id": agent_id, "patch": patch, "expected_version": int(a.get("version", 1))})


func set_budget(period: String, pool_usd: float, billing: Dictionary, confirm_raise: bool = false) -> NetRequest:
	var payload := {"period": period, "pool_usd": pool_usd, "billing": billing}
	if confirm_raise:
		payload["confirm_raise"] = true
	return Net.request(Protocol.CMD_SET_BUDGET, payload)


func set_setting(key: String, value: Variant) -> NetRequest:
	return Net.request(Protocol.CMD_SET_SETTING, {"key": key, "value": value})


# --- lookups for the HUD ----------------------------------------------------------------------------

## The Town Hall agent a building belongs to ("" for townsfolk buildings).
static func agent_of_building(b: SimBuilding) -> String:
	return b.owner_agent_id if b != null else ""


## Seconds left of an agent's training at the Keep (0 when not training).
func training_left_s(agent_id: String) -> float:
	var w := world()
	if w == null:
		return 0.0
	var item := w.queued_agent(agent_id)
	if item.is_empty():
		return 0.0
	return float(int(item.get("needed", 0)) - int(item.get("ticks", 0))) / float(w.tick_rate)
