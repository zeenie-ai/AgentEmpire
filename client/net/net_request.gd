class_name NetRequest
extends RefCounted
## One command sent to the Town Hall. Net.request() returns it; the caller awaits `done`:
##
##     var req := Net.request(Protocol.CMD_LIST_MODELS, {"provider": "claude"})
##     await req.done
##     if req.ok: ... req.payload ... else: ... req.error_message() ...
##
## `done` is always emitted on a later frame than the one that created the request, so awaiting
## it right after Net.request() never misses it, even when the request fails at once (offline).

signal done(req: NetRequest)

## Error codes that never come from the Town Hall.
const OFFLINE := "OFFLINE"
const DISCONNECTED := "DISCONNECTED"
const TIMEOUT := "TIMEOUT"

var type: String = ""
var request_id: String = ""
var payload_sent: Dictionary = {}
var finished: bool = false
var ok: bool = false
## The reply payload (a Dictionary for most commands; load_town may return null).
var payload: Variant = null
## {"code": String, "message": String, "retryable": bool} when ok is false.
var error: Dictionary = {}
## Time.get_ticks_msec() when it was sent (for timeouts).
var sent_msec: int = 0


func _init(t: String = "", id: String = "", p: Dictionary = {}) -> void:
	type = t
	request_id = id
	payload_sent = p
	sent_msec = Time.get_ticks_msec()


func error_code() -> String:
	return String(error.get("code", ""))


## A sentence for the player.
func error_message() -> String:
	match error_code():
		OFFLINE:
			return "The Town Hall is not connected."
		DISCONNECTED:
			return "Lost the connection to the Town Hall."
		TIMEOUT:
			return "The Town Hall did not answer in time."
	var m := String(error.get("message", ""))
	return m if m != "" else "The Town Hall refused: %s." % error_code()


func payload_dict() -> Dictionary:
	return payload if typeof(payload) == TYPE_DICTIONARY else {}


## Completes the request. Emitted deferred so a caller that awaits right away sees it. The
## deferred call carries the request itself, which keeps it alive until `done` has fired even
## when nobody else holds it any more (Net drops it from its pending list on the reply).
func finish(success: bool, result: Variant, err: Dictionary = {}) -> void:
	if finished:
		return
	finished = true
	ok = success
	payload = result
	error = err
	_emit_done.bind(self).call_deferred()


func fail(code: String, message: String = "", retryable: bool = true) -> void:
	finish(false, null, {"code": code, "message": message, "retryable": retryable})


func _emit_done(_keep_alive: NetRequest) -> void:
	done.emit(self)
