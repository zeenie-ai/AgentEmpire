class_name RemoteLedger
extends LocalLedger
## The Town Hall's treasury as the simulation sees it (online play).
##
## LocalLedger's synchronous bookkeeping is kept as an optimistic mirror, so the fixed-tick
## simulation never waits on the network, and every change is forwarded to the Town Hall:
## spend -> spend_resources, refund -> refund_resources, deposit -> report_gather (deposits are
## batched and sent every GATHER_FLUSH_MS). An op_id doubles as the request_id and the Town Hall
## stores op_ids, so resending after a reconnect never applies anything twice.
##
## The mirror is always  server treasury + deltas not confirmed yet + the unsent gather batch.
## A pending operation is dropped when the treasury_updated event it caused arrives
## (causation_id = op_id), or ACK_GRACE_MS after its reply when it caused none. A refused spend
## is dropped at once and reported through `rejected` so the simulation can undo what it built;
## it is also forgotten, so a later refund of it pays nothing.
##
## Resources the Town Hall pays or charges on its own (agents, homes, add-ons, rewards) reach
## the mirror through on_treasury_event() like everything else.

const GATHER_FLUSH_MS := 1000
const ACK_GRACE_MS := 1500
## Operations that failed for a transient reason are sent again this often while online.
const RETRY_MS := 2000
const RETRYABLE := ["OFFLINE", "DISCONNECTED", "TIMEOUT"]

## Sends a command: func(type: String, payload: Dictionary, request_id: String) -> NetRequest.
var send: Callable
## Prefix for the gather batch op ids ("<town>:<session>"); set by the owner.
var op_prefix: String = "town"
## Pending operations, oldest first:
## {"op", "type", "payload", "delta", "state": "unsent"|"sent"|"acked", "acked_msec"}.
var ops: Array[Dictionary] = []

var _server: Dictionary = {}
var _has_server: bool = false
var _batch: Dictionary = {}
var _batch_storehouses: int = 0
var _batch_since_msec: int = -1
var _batch_seq: int = 0
var _online: bool = false
var _last_retry_msec: int = 0


func _init(econ: EconomyData, start: Dictionary = {}, start_age: int = 1) -> void:
	super(econ, start, start_age)


## True until the Town Hall has reported a treasury (the mirror is then only a guess).
func is_syncing() -> bool:
	return not _has_server


## The Town Hall's treasury from get_state (or any treasury it reports).
func set_server_treasury(t: Dictionary, reason: String = "sync") -> void:
	_server = _clean(t)
	_has_server = true
	_recompute(reason)


## A treasury_updated event. `causation_id` is the request that caused it.
func on_treasury_event(t: Dictionary, reason: String, causation_id: String) -> void:
	_drop_op(causation_id)
	set_server_treasury(t, reason)


## The link came up or went down. Coming up sends everything not confirmed yet, in order.
func set_online(on: bool) -> void:
	_online = on
	if not on:
		return
	for op in ops:
		if String(op["state"]) != "acked":
			op["state"] = "unsent"
	_send_unsent()


## Call every frame: sends the gather batch when due, retires acknowledged operations.
func poll(now_msec: int) -> void:
	if not _batch.is_empty() and now_msec - _batch_since_msec >= GATHER_FLUSH_MS:
		_flush_batch()
	if _online and now_msec - _last_retry_msec >= RETRY_MS:
		_last_retry_msec = now_msec
		_send_unsent()
	var changed_any := false
	for i in range(ops.size() - 1, -1, -1):
		var op: Dictionary = ops[i]
		if String(op["state"]) == "acked" and now_msec - int(op["acked_msec"]) >= ACK_GRACE_MS:
			ops.remove_at(i)
			changed_any = true
	if changed_any:
		_recompute("confirmed")


## Sends the gather batch now (before saving the town, for example).
func flush() -> void:
	if not _batch.is_empty():
		_flush_batch()


## Operations the Town Hall has not confirmed yet, counting an unsent gather batch as one.
func pending_count() -> int:
	return ops.size() + (0 if _batch.is_empty() else 1)


# --- Ledger ------------------------------------------------------------------------------------

func spend(op_id: String, reason: String, cost: Dictionary, ref: String) -> bool:
	var known := _spends.has(op_id)
	if not super.spend(op_id, reason, cost, ref):
		return false
	if known:
		return true
	var clean := _positive(cost)
	var payload := {"op_id": op_id, "reason": reason.left(64), "cost": clean}
	if ref != "":
		payload["ref"] = ref.left(128)
	_queue(op_id, "spend_resources", payload, _negated(clean))
	return true


func refund(op_id: String, spend_op_id: String, fraction: float) -> Dictionary:
	var repeat := _results.has(op_id)
	var out := super.refund(op_id, spend_op_id, fraction)
	if repeat or out.is_empty():
		return out
	_queue(op_id, "refund_resources", {"op_id": op_id, "spend_op_id": spend_op_id, "fraction": clampf(fraction, 0.0001, 1.0)}, out)
	return out


func deposit(op_id: String, deposits: Dictionary, storehouses: int) -> Dictionary:
	var repeat := _results.has(op_id)
	var out := super.deposit(op_id, deposits, storehouses)
	if repeat or out.is_empty():
		return out
	if _batch.is_empty():
		_batch_since_msec = Time.get_ticks_msec()
	for res: String in out:
		_batch[res] = int(_batch.get(res, 0)) + int(out[res])
	_batch_storehouses = storehouses
	return out


func to_dict() -> Dictionary:
	return {"kind": "remote", "spends": _spends.duplicate(true)}


## Restores the spend records (for refunds) from a town save. The treasury always comes from
## the Town Hall, never from a save.
func load_dict(d: Dictionary) -> void:
	var t := _treasury.duplicate()
	var a := _age
	super.load_dict({"age": a, "treasury": t, "spends": d.get("spends", {})})


# --- internals ---------------------------------------------------------------------------------

func _queue(op_id: String, type: String, payload: Dictionary, delta: Dictionary) -> void:
	ops.append({"op": op_id, "type": type, "payload": payload, "delta": delta, "state": "unsent", "acked_msec": 0})
	_send_unsent()


func _send_unsent() -> void:
	if not _online or not send.is_valid():
		return
	for op in ops:
		if String(op["state"]) != "unsent":
			continue
		op["state"] = "sent"
		var req: NetRequest = send.call(String(op["type"]), op["payload"], String(op["op"]))
		req.done.connect(_on_reply.bind(String(op["op"])))


func _on_reply(req: NetRequest, op_id: String) -> void:
	var op := _find(op_id)
	if op.is_empty():
		return
	if req.ok:
		op["state"] = "acked"
		op["acked_msec"] = Time.get_ticks_msec()
		return
	var code := req.error_code()
	if code in RETRYABLE:
		op["state"] = "unsent"
		return
	_drop_op(op_id)
	if String(op["type"]) == "spend_resources":
		_spends.erase(op_id)
		rejected.emit(op_id, code)
	_recompute("rejected")


func _flush_batch() -> void:
	_batch_seq += 1
	var op_id := "%s:gather:%d" % [op_prefix, _batch_seq]
	var deposits := _batch.duplicate()
	_batch.clear()
	_batch_since_msec = -1
	ops.append({"op": op_id, "type": "report_gather", "payload": {"op_id": op_id, "deposits": deposits, "storehouses": _batch_storehouses},
		"delta": deposits, "state": "unsent", "acked_msec": 0})
	_send_unsent()


func _find(op_id: String) -> Dictionary:
	for op in ops:
		if String(op["op"]) == op_id:
			return op
	return {}


func _drop_op(op_id: String) -> void:
	if op_id == "":
		return
	for i in ops.size():
		if String(ops[i]["op"]) == op_id:
			ops.remove_at(i)
			return


## treasury = server + pending deltas + batch; announces the difference to the old mirror.
func _recompute(reason: String) -> void:
	if not _has_server:
		return
	var next := _server.duplicate()
	for op in ops:
		var d: Dictionary = op["delta"]
		for res: String in d:
			next[res] = int(next.get(res, 0)) + int(d[res])
	for res: String in _batch:
		next[res] = int(next.get(res, 0)) + int(_batch[res])
	var delta := {}
	for res in _econ.resource_names():
		var v := maxi(int(next.get(res, 0)), 0)
		var diff := v - int(_treasury.get(res, 0))
		if diff != 0:
			delta[res] = diff
		_treasury[res] = v
	if not delta.is_empty():
		changed.emit(treasury(), reason, delta)


func _clean(t: Dictionary) -> Dictionary:
	var out := {}
	for res in _econ.resource_names():
		out[res] = int(t.get(res, 0))
	return out


static func _negated(cost: Dictionary) -> Dictionary:
	var out := {}
	for res: String in cost:
		out[res] = -int(cost[res])
	return out
