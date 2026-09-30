extends GutTest
## RemoteLedger: the optimistic mirror of the Town Hall's treasury. Requests go to a fake
## transport; the test plays the Town Hall by finishing them and sending treasury events.

const START := {"food": 200, "wood": 200, "stone": 150, "gold": 100}

var sent: Array[Dictionary] = []
var rejected: Array[String] = []


func _ledger(online: bool = true) -> RemoteLedger:
	sent.clear()
	rejected.clear()
	var l := RemoteLedger.new(EconomyData.load_default(), {}, 1)
	l.op_prefix = "town:test"
	l.send = func(type: String, payload: Dictionary, rid: String) -> NetRequest:
		var r := NetRequest.new(type, rid, payload)
		sent.append({"type": type, "payload": payload, "rid": rid, "req": r})
		return r
	l.rejected.connect(func(op: String, _code: String) -> void: rejected.append(op))
	l.set_server_treasury(START)
	l.set_online(online)
	return l


func _last(type: String) -> Dictionary:
	for i in range(sent.size() - 1, -1, -1):
		if String(sent[i]["type"]) == type:
			return sent[i]
	return {}


func _server(t: Dictionary, delta: Dictionary) -> Dictionary:
	var out := t.duplicate()
	for k: String in delta:
		out[k] = int(out.get(k, 0)) + int(delta[k])
	return out


func test_spend_applies_at_once_and_is_forwarded_with_its_op_id() -> void:
	var l := _ledger()
	assert_true(l.spend("op-1", "build:cottage", {"wood": 30}, ""))
	assert_eq(l.amount("wood"), 170, "optimistic")
	var s := _last("spend_resources")
	assert_eq(String(s["rid"]), "op-1", "the op id is the request id")
	assert_eq(String((s["payload"] as Dictionary)["op_id"]), "op-1")
	assert_eq(int(((s["payload"] as Dictionary)["cost"] as Dictionary)["wood"]), 30)


func test_the_mirror_settles_on_the_server_treasury() -> void:
	var l := _ledger()
	l.spend("op-1", "build:cottage", {"wood": 30}, "")
	(_last("spend_resources")["req"] as NetRequest).finish(true, {"treasury": _server(START, {"wood": -30})})
	await wait_process_frames(2)
	assert_eq(l.amount("wood"), 170, "no flicker between the reply and the event")
	l.on_treasury_event(_server(START, {"wood": -30}), "build:cottage", "op-1")
	assert_eq(l.pending_count(), 0)
	assert_eq(l.amount("wood"), 170)


func test_events_from_other_operations_keep_pending_ones_applied() -> void:
	var l := _ledger()
	l.spend("op-1", "train:townsfolk", {"food": 50}, "")
	# The Town Hall charges an agent (its own operation) before op-1 is confirmed.
	l.on_treasury_event(_server(START, {"food": -120, "gold": -60}), "agent", "c-1")
	assert_eq(l.amount("food"), 30, "server charge and pending spend both count")
	assert_eq(l.amount("gold"), 40)


func test_a_refused_spend_is_undone_and_reported() -> void:
	var l := _ledger()
	l.spend("op-1", "build:storehouse", {"wood": 100}, "")
	(_last("spend_resources")["req"] as NetRequest).fail("INSUFFICIENT_RESOURCES", "not enough", false)
	await wait_process_frames(2)
	assert_eq(rejected.size(), 1)
	assert_eq(rejected[0] if not rejected.is_empty() else "", "op-1")
	assert_eq(l.amount("wood"), 200, "the deduction is gone")
	assert_true(l.refund("op-2", "op-1", 1.0).is_empty(), "nothing to refund for a refused spend")


func test_transient_failures_resend_the_same_operation_later() -> void:
	var l := _ledger()
	l.spend("op-1", "build:cottage", {"wood": 30}, "")
	(_last("spend_resources")["req"] as NetRequest).fail(NetRequest.DISCONNECTED)
	await wait_process_frames(2)
	assert_eq(l.amount("wood"), 170, "still applied")
	l.set_online(false)
	var before := sent.size()
	l.set_online(true)
	assert_eq(sent.size(), before + 1, "resent on reconnect")
	assert_eq(String(_last("spend_resources")["rid"]), "op-1", "with the same op id")


func test_offline_operations_wait_for_the_link() -> void:
	var l := _ledger(false)
	l.spend("op-1", "build:cottage", {"wood": 30}, "")
	assert_eq(sent.size(), 0)
	l.set_online(true)
	assert_eq(sent.size(), 1)


func test_deposits_are_batched_and_capped() -> void:
	var l := _ledger()
	var got := l.deposit("g-1", {"wood": 10}, 0)
	l.deposit("g-2", {"wood": 10}, 0)
	l.deposit("g-3", {"food": 5}, 0)
	assert_eq(int(got["wood"]), 10)
	assert_eq(l.amount("wood"), 220)
	assert_eq(sent.size(), 0, "not sent yet")
	l.poll(Time.get_ticks_msec() + RemoteLedger.GATHER_FLUSH_MS + 10)
	var g := _last("report_gather")
	var deposits: Dictionary = (g["payload"] as Dictionary)["deposits"]
	assert_eq(int(deposits["wood"]), 20)
	assert_eq(int(deposits["food"]), 5)
	assert_string_starts_with(String(g["rid"]), "town:test:gather:")
	var cap := l.storage_cap("wood", 0)
	var clipped := l.deposit("g-4", {"wood": cap}, 0)
	assert_eq(l.amount("wood"), cap, "gathering never passes the cap")
	assert_lt(int(clipped["wood"]), cap)


func test_confirmed_operations_without_an_event_retire_after_a_grace_period() -> void:
	var l := _ledger()
	l.spend("op-1", "build:cottage", {"wood": 30}, "")
	(_last("spend_resources")["req"] as NetRequest).finish(true, {"treasury": START})
	await wait_process_frames(2)
	assert_eq(l.pending_count(), 1)
	l.poll(Time.get_ticks_msec() + RemoteLedger.ACK_GRACE_MS + 10)
	assert_eq(l.pending_count(), 0)
	assert_eq(l.amount("wood"), 200, "back to what the Town Hall reports")


func test_spend_records_survive_a_town_save_for_refunds() -> void:
	var l := _ledger()
	l.spend("op-1", "build:cottage", {"wood": 30}, "b12")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(l.to_dict()))
	var l2 := _ledger()
	l2.load_dict(saved)
	assert_eq(l2.amount("wood"), 200, "the treasury never comes from a save")
	var back := l2.refund("op-2", "op-1", 1.0)
	assert_eq(int(back.get("wood", 0)), 30)
	assert_eq(String(_last("refund_resources")["rid"]), "op-2")
