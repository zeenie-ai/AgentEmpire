extends Node
## The client's copy of the Town Hall's state: agents, tool add-ons, tasks, approvals,
## incidents, parties, Mana, the age, settings and providers (PROTOCOL.md, Shared objects).
##
## Net.state_received replaces everything (reset); Net.event_received updates single objects,
## always by replacing the stored copy with the one in the event. Every change is announced
## through `changed(kind, id)` plus a few specific signals the HUD and TownLink listen to.
## Objects are the protocol's dictionaries as parsed from JSON: ids are strings, numbers floats.

## kind: "agent", "tool", "task", "approval", "incident", "party", "mana", "age", "settings",
## "providers" or "all" (after a reset). id is the object's id, or "".
signal changed(kind: String, id: String)
signal reset()
signal agent_changed(agent: Dictionary)
signal agent_retired(agent_id: String)
signal tool_changed(tool: Dictionary)
signal task_changed(task: Dictionary, previous_state: String)
signal task_progress(task_id: String, progress: Dictionary)
signal task_activity(task_id: String, entry: Dictionary)
signal approval_requested(approval: Dictionary)
signal approval_resolved(approval_id: String, info: Dictionary)
signal incident_opened(incident: Dictionary)
signal incident_resolved(incident_id: String)
signal mana_changed(mana: Dictionary)
signal age_changed(age: Dictionary)
signal treasury_event(treasury: Dictionary, reason: String, delta: Dictionary, causation_id: String)
signal subtask_delegated(info: Dictionary)
signal daemon_shutdown()

const Protocol = preload("res://net/protocol.gd")
const ACTIVITY_KEEP := 200

var agents: Dictionary = {}
var tools: Dictionary = {}
var tasks: Dictionary = {}
var approvals: Dictionary = {}
var incidents: Dictionary = {}
var parties: Dictionary = {}
var mana: Dictionary = {}
var age: Dictionary = {"current": 1, "research": null}
var settings: Dictionary = {}
var providers: Array = []
var treasury: Dictionary = {}
## {rev, schema_version} of the town save on the Town Hall, or {} when there is none.
var town: Dictionary = {}
## Latest task_progress payload per task id.
var progress: Dictionary = {}
## Recent task_activity entries per task id, oldest first.
var activity: Dictionary = {}
## True once a full state has been received.
var has_state: bool = false


func _ready() -> void:
	Net.state_received.connect(apply_state)
	Net.event_received.connect(apply_event)


## "offline" until the Town Hall is connected; then "normal", "dim", "warning" or "depleted".
func mana_level() -> String:
	if not Net.is_online() or mana.is_empty():
		return "offline"
	return J.gs(mana, "level", "normal")


func clear() -> void:
	agents.clear()
	tools.clear()
	tasks.clear()
	approvals.clear()
	incidents.clear()
	parties.clear()
	mana = {}
	age = {"current": 1, "research": null}
	settings = {}
	providers = []
	treasury = {}
	town = {}
	progress.clear()
	activity.clear()
	has_state = false


# --- queries ---------------------------------------------------------------------------------

func agent(id: String) -> Dictionary:
	return agents.get(id, {})


## Agents that are not retired, oldest first.
func active_agents() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for a: Dictionary in agents.values():
		if J.gs(a, "lifecycle", "") != Protocol.AgentLifecycle.RETIRED:
			out.append(a)
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return J.gs(x, "created_at", "") < J.gs(y, "created_at", ""))
	return out


func agent_count() -> int:
	return active_agents().size()


## The agent's add-ons that are not dismantled.
func tools_of(agent_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for t: Dictionary in tools.values():
		if J.gs(t, "agent_id", "") == agent_id and J.gs(t, "status", "") != Protocol.ToolStatus.REMOVED:
			out.append(t)
	return out


func tool_of_type(agent_id: String, type: String) -> Dictionary:
	for t in tools_of(agent_id):
		if J.gs(t, "type", "") == type:
			return t
	return {}


## The agent's tasks, oldest first. open_only leaves out accepted, rejected and cancelled ones.
func tasks_of(agent_id: String, open_only: bool = true) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for t: Dictionary in tasks.values():
		if J.gs(t, "agent_id", "") != agent_id:
			continue
		if open_only and is_terminal(t):
			continue
		out.append(t)
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return J.gs(x, "created_at", "") < J.gs(y, "created_at", ""))
	return out


func task(id: String) -> Dictionary:
	return tasks.get(id, {})


static func is_terminal(t: Dictionary) -> bool:
	return J.gs(t, "state", "") in Protocol.TERMINAL_TASK_STATES


## The agent's current task (running, preparing or waiting for approval), or {}.
func current_task(agent_id: String) -> Dictionary:
	var a := agent(agent_id)
	var id: Variant = a.get("current_task_id")
	if id != null and String(id) != "" and tasks.has(String(id)):
		return tasks[String(id)]
	return {}


## The task an agent's home shows first: running, then waiting on the player, then queued.
func headline_task(agent_id: String) -> Dictionary:
	var cur := current_task(agent_id)
	if not cur.is_empty():
		return cur
	var order := ["awaiting_review", "accepting", "paused", "failed", "queued", "in_transit"]
	var best: Dictionary = {}
	var best_rank := 99
	for t in tasks_of(agent_id):
		var r := order.find(J.gs(t, "state", ""))
		if r >= 0 and r < best_rank:
			best_rank = r
			best = t
	return best


## Approvals waiting for the player, oldest first.
func pending_approvals() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for a: Dictionary in approvals.values():
		if J.gs(a, "status", "pending") == Protocol.ApprovalStatus.PENDING:
			out.append(a)
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return J.gs(x, "created_at", "") < J.gs(y, "created_at", ""))
	return out


func approvals_for(agent_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for a in pending_approvals():
		if J.gs(a, "agent_id", "") == agent_id:
			out.append(a)
	return out


## Tasks whose result waits for review (oldest first).
func tasks_awaiting_review() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for t: Dictionary in tasks.values():
		var s := J.gs(t, "state", "")
		if s == Protocol.TaskState.AWAITING_REVIEW or s == Protocol.TaskState.ACCEPTING:
			out.append(t)
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return J.gs(x, "finished_at", "") < J.gs(y, "finished_at", ""))
	return out


func incidents_for(agent_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i: Dictionary in incidents.values():
		var subject: Variant = i.get("subject")
		if J.gs(_dict(subject), "agent_id") == agent_id:
			out.append(i)
	return out


func provider(id: String) -> Dictionary:
	for p: Variant in providers:
		if typeof(p) == TYPE_DICTIONARY and String((p as Dictionary).get("id", "")) == id:
			return p
	return {}


func provider_ready(id: String) -> bool:
	var p := provider(id)
	return bool(p.get("installed", false)) and bool(p.get("logged_in", false))


func current_age() -> int:
	return maxi(int(age.get("current", 1)), 1)


# --- updates -----------------------------------------------------------------------------------

## Replaces everything with a get_state result.
func apply_state(state: Dictionary) -> void:
	clear()
	for a: Dictionary in state.get("agents", []):
		agents[String(a["id"])] = a
	for t: Dictionary in state.get("tools", []):
		tools[String(t["id"])] = t
	for t: Dictionary in state.get("tasks", []):
		tasks[String(t["id"])] = t
	for a: Dictionary in state.get("approvals", []):
		approvals[String(a["id"])] = a
	for p: Dictionary in state.get("parties", []):
		parties[String(p["id"])] = p
	for i: Dictionary in state.get("incidents", []):
		incidents[String(i["id"])] = i
	mana = _dict(state.get("mana"))
	var ag := _dict(state.get("age"))
	if not ag.is_empty():
		age = ag
	settings = _dict(state.get("settings"))
	var ps: Variant = state.get("providers", [])
	providers = ps if typeof(ps) == TYPE_ARRAY else []
	treasury = _dict(state.get("treasury"))
	town = _dict(state.get("town"))
	has_state = true
	reset.emit()
	changed.emit("all", "")
	mana_changed.emit(mana)
	age_changed.emit(age)


## Applies one event envelope.
func apply_event(ev: Dictionary) -> void:
	var p := _dict(ev.get("payload"))
	match J.gs(ev, "type", ""):
		Protocol.EVT_AGENT_UPDATED:
			var a := _dict(p.get("agent"))
			if a.is_empty():
				return
			agents[String(a["id"])] = a
			agent_changed.emit(a)
			changed.emit("agent", String(a["id"]))
		Protocol.EVT_AGENT_RETIRED:
			var id := J.gs(p, "agent_id", "")
			if agents.has(id):
				var a: Dictionary = agents[id]
				a["lifecycle"] = Protocol.AgentLifecycle.RETIRED
			agent_retired.emit(id)
			changed.emit("agent", id)
		Protocol.EVT_TOOL_UPDATED:
			var t := _dict(p.get("tool"))
			if t.is_empty():
				return
			tools[String(t["id"])] = t
			tool_changed.emit(t)
			changed.emit("tool", String(t["id"]))
		Protocol.EVT_TASK_UPDATED:
			var t := _dict(p.get("task"))
			if t.is_empty():
				return
			var id := String(t["id"])
			var before := String(_dict(tasks.get(id)).get("state", ""))
			tasks[id] = t
			if is_terminal(t):
				progress.erase(id)
			task_changed.emit(t, before)
			changed.emit("task", id)
		Protocol.EVT_TASK_PROGRESS:
			var id := J.gs(p, "task_id", "")
			progress[id] = p
			task_progress.emit(id, p)
		Protocol.EVT_TASK_ACTIVITY:
			var id := J.gs(p, "task_id", "")
			var entry := _dict(p.get("entry"))
			if not activity.has(id):
				activity[id] = []
			var list: Array = activity[id]
			list.append(entry)
			while list.size() > ACTIVITY_KEEP:
				list.pop_front()
			task_activity.emit(id, entry)
		Protocol.EVT_APPROVAL_REQUESTED:
			var a := _dict(p.get("approval"))
			if a.is_empty():
				return
			approvals[String(a["id"])] = a
			approval_requested.emit(a)
			changed.emit("approval", String(a["id"]))
		Protocol.EVT_APPROVAL_RESOLVED:
			var id := J.gs(p, "approval_id", "")
			approvals.erase(id)
			approval_resolved.emit(id, p)
			changed.emit("approval", id)
		Protocol.EVT_MANA_UPDATED:
			mana = _dict(p.get("mana"))
			mana_changed.emit(mana)
			changed.emit("mana", "")
		Protocol.EVT_TREASURY_UPDATED:
			treasury = _dict(p.get("treasury"))
			var cause: Variant = ev.get("causation_id")
			treasury_event.emit(treasury, J.gs(p, "reason", ""), _dict(p.get("delta")), String(cause) if cause != null else "")
		Protocol.EVT_INCIDENT_OPENED:
			var i := _dict(p.get("incident"))
			if i.is_empty():
				return
			incidents[String(i["id"])] = i
			incident_opened.emit(i)
			changed.emit("incident", String(i["id"]))
		Protocol.EVT_INCIDENT_RESOLVED:
			var id := J.gs(p, "incident_id", "")
			incidents.erase(id)
			incident_resolved.emit(id)
			changed.emit("incident", id)
		Protocol.EVT_PARTY_UPDATED:
			var party := _dict(p.get("party"))
			if not party.is_empty():
				parties[String(party["id"])] = party
				changed.emit("party", String(party["id"]))
		Protocol.EVT_PARTY_DISBANDED:
			var id := J.gs(p, "party_id", "")
			parties.erase(id)
			changed.emit("party", id)
		Protocol.EVT_SUBTASK_DELEGATED:
			subtask_delegated.emit(p)
		Protocol.EVT_AGE_UPDATED:
			var ag := _dict(p.get("age"))
			if not ag.is_empty():
				age = ag
				age_changed.emit(age)
				changed.emit("age", "")
		Protocol.EVT_PROVIDERS_UPDATED:
			var ps: Variant = p.get("providers", [])
			providers = ps if typeof(ps) == TYPE_ARRAY else []
			changed.emit("providers", "")
		Protocol.EVT_TOWN_SAVED:
			town["rev"] = int(p.get("rev", 0))
		Protocol.EVT_DAEMON_SHUTDOWN:
			daemon_shutdown.emit()


static func _dict(v: Variant) -> Dictionary:
	return v if typeof(v) == TYPE_DICTIONARY else {}
