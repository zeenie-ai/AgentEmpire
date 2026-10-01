extends Node
## The WebSocket link to the Town Hall (protocol/PROTOCOL.md).
##
## - Finds a running Town Hall (TownHallDiscovery), connects to ws://<host>:<port>/ws and says
##   hello with the session token. It keeps looking and reconnects with backoff while enabled.
## - request(type, payload) sends a command and returns a NetRequest to await.
## - Events are checked against `seq`: duplicates are dropped and a gap (or a "snapshot"
##   catch-up after hello) fetches get_state, delivered through state_received; events that
##   arrive meanwhile are held back and replayed on top of it. Realm consumes both signals.
## - The link counts as online once hello succeeded and the state is current.
##
## Only one client may be connected. A second one gets SESSION_BUSY and parks as "busy" until
## the player chooses take_over().
##
## Each Town Hall data folder has its own event history, so `last_seq` only carries over to a
## Town Hall on the same data folder; any other one (the other mode's town) starts with a full
## state. A mode switch pins the runtime file of the Town Hall it waits for (pin_runtime).

signal status_changed(status: String)
signal connection_changed(online: bool)
## A full get_state result: the client replaces its copy of the Town Hall's state.
signal state_received(state: Dictionary)
## One event envelope ({v, type, seq, id, time, subject, causation_id, payload}), in seq order.
signal event_received(event: Dictionary)

const Protocol = preload("res://net/protocol.gd")

const STATUS_OFF := "off"
const STATUS_SEARCHING := "searching"
const STATUS_CONNECTING := "connecting"
const STATUS_ONLINE := "online"
const STATUS_BUSY := "busy"
const STATUS_REJECTED := "rejected"

const BUFFER_BYTES := 4 * 1024 * 1024
const REQUEST_TIMEOUT_MS := 30000
const RETRY_MIN_S := 1.0
const RETRY_MAX_S := 8.0
const SEARCH_EVERY_S := 2.0
const REJECTED_RETRY_S := 5.0
## A connection attempt still pending after this long is given up and retried.
const CONNECT_TIMEOUT_MS := 2000
const TRANSIENT_EVENTS := ["session_revoked", "daemon_shutdown"]

var status: String = STATUS_OFF
var online: bool = false
## {"host", "port", "token", "source", "pid", "data_dir"} of the Town Hall in use.
var endpoint: Dictionary = {}
## The hello reply: {protocol, daemon_version, sdk_versions, features, seq, catchup}.
var hello_info: Dictionary = {}
## Highest event seq applied; -1 before the first state.
var last_seq: int = -1
## Why the last attempt failed, for the connection chip ("" when fine).
var last_problem: String = ""
## Connection attempts so far (boot waits for the first one).
var attempts: int = 0
## Attempts that failed since the last successful connection (no answer, refused, rejected).
var failures: int = 0

var _enabled: bool = false
var _ws: WebSocketPeer
var _retry_in: float = 0.0
var _backoff: float = RETRY_MIN_S
var _parked: bool = false
var _take_over: bool = false
var _hello_sent: bool = false
var _pending: Dictionary = {}
var _counter: int = 0
var _session: String = ""
var _snapshot_pending: bool = false
var _held: Array[Dictionary] = []
var _connect_started_msec: int = 0
## Only this runtime file is read while set (a mode switch waiting for one Town Hall).
var _pinned_runtime: String = ""
## The data folder whose event history last_seq belongs to.
var _seq_data_dir: String = ""


func _ready() -> void:
	_session = "%06x" % (randi() & 0xffffff)


func is_online() -> bool:
	return online


func is_enabled() -> bool:
	return _enabled


## Starts (or stops) looking for the Town Hall.
func enable(on: bool) -> void:
	if on == _enabled:
		return
	_enabled = on
	if on:
		_parked = false
		_retry_in = 0.0
		_set_status(STATUS_SEARCHING)
	else:
		_close(1000, "client disabled")
		_set_status(STATUS_OFF)


## False when the game was started with `-- --offline`.
static func wanted() -> bool:
	return not "--offline" in OS.get_cmdline_user_args()


## Tries again right away (after the player starts the Town Hall, for example).
func reconnect_now() -> void:
	if not _enabled:
		enable(true)
		return
	_parked = false
	if _ws == null:
		_retry_in = 0.0


## Starts looking afresh: the attempt and failure counts start over (a caller waiting for a
## Town Hall reads them), and the next attempt is immediate.
func restart_search() -> void:
	attempts = 0
	failures = 0
	_backoff = RETRY_MIN_S
	last_problem = ""
	_parked = false
	if not _enabled:
		enable(true)
	elif _ws == null:
		_retry_in = 0.0


## Reads only `path` when looking for a Town Hall, until unpin_runtime().
func pin_runtime(path: String) -> void:
	_pinned_runtime = path


func unpin_runtime() -> void:
	_pinned_runtime = ""


## Forgets the Town Hall this client followed (its last seq and hello), so the next one starts
## with a full state. Used before connecting to another Town Hall's town.
func forget_session() -> void:
	last_seq = -1
	_seq_data_dir = ""
	hello_info = {}
	_held.clear()


## The connected Town Hall's mode from its hello features: "real", "fake", or "" when unknown.
func town_hall_mode() -> String:
	return mode_from_features(J.a(hello_info.get("features")))


## Whether the connected Town Hall announced `feature` in its hello (for example "shutdown").
func has_feature(feature: String) -> bool:
	return feature in J.a(hello_info.get("features"))


static func mode_from_features(features: Array) -> String:
	if "real_providers" in features:
		return "real"
	if "fake_provider" in features:
		return "fake"
	return ""


## Connects even though another client is active; that client is closed with 4409.
func take_over() -> void:
	_take_over = true
	_parked = false
	if not _enabled:
		enable(true)
	elif _ws == null:
		_retry_in = 0.0


## Sends a command. Commands fail at once with OFFLINE while the link is not online.
## `request_id` is generated unless given (ledger operations pass their op_id, which makes a
## resend after a reconnect safe).
func request(type: String, payload: Dictionary = {}, request_id: String = "") -> NetRequest:
	var rid := request_id if request_id != "" else _next_id()
	if not online:
		var r := NetRequest.new(type, rid, payload)
		r.fail(NetRequest.OFFLINE, "", true)
		return r
	return _send(type, payload, rid)


# --- connection ------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _enabled:
		return
	if _ws == null:
		if _parked:
			return
		_retry_in -= delta
		if _retry_in <= 0.0:
			_attempt()
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			if Time.get_ticks_msec() - _connect_started_msec > CONNECT_TIMEOUT_MS:
				last_problem = "The Town Hall did not answer."
				_close(1000, "connect timeout")
				_schedule_retry()
				return
		WebSocketPeer.STATE_OPEN:
			if not _hello_sent:
				_send_hello()
			while _ws != null and _ws.get_available_packet_count() > 0:
				_on_frame(_ws.get_packet().get_string_from_utf8())
		WebSocketPeer.STATE_CLOSED:
			_on_closed(_ws.get_close_code(), _ws.get_close_reason())
	_check_timeouts()


func _attempt() -> void:
	attempts += 1
	endpoint = TownHallDiscovery.find(_pinned_runtime, String(Settings.get_value("townhall/provider", "fake")))
	if endpoint.is_empty():
		last_problem = "No running Town Hall found."
		_set_status(STATUS_SEARCHING)
		_retry_in = SEARCH_EVERY_S
		return
	# Another data folder means another event history: its seq numbers say nothing about ours.
	var data_dir := J.gs(endpoint, "data_dir")
	if data_dir != "" and not TownHallLauncher.same_dir(data_dir, _seq_data_dir):
		if _seq_data_dir != "":
			last_seq = -1
			_held.clear()
		_seq_data_dir = data_dir
	var ws := WebSocketPeer.new()
	ws.inbound_buffer_size = BUFFER_BYTES
	ws.outbound_buffer_size = BUFFER_BYTES
	var url := "ws://%s:%d/ws" % [String(endpoint["host"]), int(endpoint["port"])]
	if ws.connect_to_url(url) != OK:
		last_problem = "Could not open %s." % url
		_schedule_retry()
		return
	_ws = ws
	_hello_sent = false
	_connect_started_msec = Time.get_ticks_msec()
	_set_status(STATUS_CONNECTING)


func _send_hello() -> void:
	_hello_sent = true
	var payload := {
		"token": String(endpoint.get("token", "")),
		"protocol": {"major": Protocol.PROTOCOL_MAJOR, "minor": Protocol.PROTOCOL_MINOR},
		"client": {
			"name": "aurelhaven-godot",
			"version": String(ProjectSettings.get_setting("application/config/version", "0")),
			"platform": "web" if OS.has_feature("web") else "desktop",
		},
	}
	if last_seq >= 0:
		payload["last_seq"] = last_seq
	if _take_over:
		payload["take_over"] = true
	var req := _send(Protocol.CMD_HELLO, payload, _next_id())
	req.done.connect(_on_hello)


func _on_hello(req: NetRequest) -> void:
	if _ws == null:
		return
	if not req.ok:
		_close(1000, "hello failed")
		match req.error_code():
			Protocol.ERR_SESSION_BUSY:
				last_problem = "Another Aurelhaven window is connected."
				_parked = true
				_set_status(STATUS_BUSY)
			Protocol.ERR_AUTH_FAILED:
				last_problem = "The Town Hall refused the token."
				_set_status(STATUS_REJECTED)
				_retry_in = REJECTED_RETRY_S
			_:
				last_problem = req.error_message()
				_schedule_retry()
		return
	_take_over = false
	_backoff = RETRY_MIN_S
	last_problem = ""
	hello_info = req.payload_dict()
	if String(hello_info.get("catchup", "snapshot")) == "snapshot" or last_seq < 0:
		_request_snapshot()
	else:
		_go_online()


func _request_snapshot() -> void:
	if _snapshot_pending:
		return
	_snapshot_pending = true
	var req := _send(Protocol.CMD_GET_STATE, {}, _next_id())
	req.done.connect(_on_snapshot)


func _on_snapshot(req: NetRequest) -> void:
	_snapshot_pending = false
	if not req.ok:
		if _ws != null:
			last_problem = req.error_message()
			_close(1000, "state failed")
			_schedule_retry()
		return
	if _ws == null:
		return
	var state := req.payload_dict()
	last_seq = int(state.get("seq", 0))
	state_received.emit(state)
	var held := _held.duplicate()
	_held.clear()
	held.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("seq", 0)) < int(b.get("seq", 0)))
	for ev in held:
		_on_event(ev)
	if not online and _ws != null:
		_go_online()


func _go_online() -> void:
	failures = 0
	online = true
	_set_status(STATUS_ONLINE)
	connection_changed.emit(true)


## The server (or the network) closed the socket.
func _on_closed(code: int, reason: String) -> void:
	_teardown()
	match code:
		Protocol.CLOSE_REPLACED:
			last_problem = "Another Aurelhaven window took over."
			_parked = true
			_set_status(STATUS_BUSY)
		Protocol.CLOSE_BAD_TOKEN:
			last_problem = "The Town Hall refused the token."
			_set_status(STATUS_REJECTED)
			_retry_in = REJECTED_RETRY_S
		Protocol.CLOSE_PROTOCOL_MISMATCH:
			last_problem = "This game and the Town Hall speak different protocol versions."
			_set_status(STATUS_REJECTED)
			_retry_in = REJECTED_RETRY_S * 4.0
		_:
			if not _parked:
				if reason != "":
					last_problem = "Disconnected: %s" % reason
				_schedule_retry()


## Closes the socket from this side; the caller decides what happens next.
func _close(code: int, reason: String) -> void:
	if _ws == null:
		return
	_ws.close(code, reason)
	_teardown()


func _teardown() -> void:
	_ws = null
	_hello_sent = false
	_snapshot_pending = false
	_held.clear()
	var was_online := online
	online = false
	_fail_pending(NetRequest.DISCONNECTED)
	if was_online:
		connection_changed.emit(false)


func _schedule_retry() -> void:
	failures += 1
	_retry_in = _backoff
	_backoff = minf(_backoff * 2.0, RETRY_MAX_S)
	_set_status(STATUS_CONNECTING if not endpoint.is_empty() else STATUS_SEARCHING)


func _set_status(s: String) -> void:
	if s == status:
		return
	status = s
	status_changed.emit(s)


# --- frames ------------------------------------------------------------------------------------

func _send(type: String, payload: Dictionary, rid: String) -> NetRequest:
	var req := NetRequest.new(type, rid, payload)
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		req.fail(NetRequest.DISCONNECTED)
		return req
	var frame := JSON.stringify({"v": Protocol.ENVELOPE_VERSION, "type": type, "request_id": rid, "payload": payload})
	if frame.to_utf8_buffer().size() > Protocol.MAX_FRAME_BYTES:
		req.fail(Protocol.ERR_BAD_REQUEST, "The message is too large.", false)
		return req
	if _ws.send_text(frame) != OK:
		req.fail(NetRequest.DISCONNECTED)
		return req
	_pending[rid] = req
	return req


func _on_frame(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = parsed
	var type := String(msg.get("type", ""))
	if msg.has("request_id") and type.ends_with("_result"):
		var rid := String(msg["request_id"])
		var req: NetRequest = _pending.get(rid)
		if req == null:
			return
		_pending.erase(rid)
		if bool(msg.get("ok", false)):
			req.finish(true, msg.get("payload"))
		else:
			var err: Variant = msg.get("error", {})
			req.finish(false, null, err if typeof(err) == TYPE_DICTIONARY else {"code": "INTERNAL", "message": ""})
		return
	_on_event(msg)


func _on_event(ev: Dictionary) -> void:
	var type := String(ev.get("type", ""))
	if type in TRANSIENT_EVENTS:
		if type == "session_revoked":
			last_problem = "Another Aurelhaven window took over."
			_parked = true
		event_received.emit(ev)
		return
	if not ev.has("seq"):
		return
	var seq := int(ev["seq"])
	if _snapshot_pending or last_seq < 0:
		_held.append(ev)
		return
	if seq <= last_seq:
		return
	if seq != last_seq + 1:
		_held.append(ev)
		_request_snapshot()
		return
	last_seq = seq
	event_received.emit(ev)


func _check_timeouts() -> void:
	if _pending.is_empty():
		return
	var now := Time.get_ticks_msec()
	for rid: String in _pending.keys():
		var req: NetRequest = _pending[rid]
		if now - req.sent_msec > REQUEST_TIMEOUT_MS:
			_pending.erase(rid)
			req.fail(NetRequest.TIMEOUT)


func _fail_pending(code: String) -> void:
	var reqs := _pending.values()
	_pending.clear()
	for req: NetRequest in reqs:
		req.fail(code)


func _next_id() -> String:
	_counter += 1
	return "c-%s-%d" % [_session, _counter]
