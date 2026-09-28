class_name LocalLedger
extends Ledger
## Offline ledger: balances live in the client. Used until the Town Hall connection exists
## (Phase 3), and by the headless tests.

const MAX_ENTRIES := 256
const MAX_REMEMBERED_RESULTS := 512

## Recent balance changes, newest last: {"op": String, "reason": String, "delta": Dictionary}.
var entries: Array[Dictionary] = []

var _econ: EconomyData
var _treasury: Dictionary = {}
var _age: int = 1
## op_id -> {"cost": Dictionary, "refunded": bool, "reason": String, "ref": String}
var _spends: Dictionary = {}
## op_id -> result, so a repeated refund/deposit op_id returns the original result.
var _results: Dictionary = {}
var _result_order: Array[String] = []


func _init(econ: EconomyData, start: Dictionary = {}, start_age: int = 1) -> void:
	_econ = econ
	_age = maxi(start_age, 1)
	for res in econ.resource_names():
		_treasury[res] = int(start.get(res, 0))


func treasury() -> Dictionary:
	return _treasury.duplicate()


func age() -> int:
	return _age


func set_age(value: int) -> void:
	_age = maxi(value, 1)


func storage_cap(res: String, storehouses: int) -> int:
	return _econ.storage_cap(res, _age, storehouses)


func spend(op_id: String, reason: String, cost: Dictionary, ref: String) -> bool:
	if _spends.has(op_id):
		return true
	var clean := _positive(cost)
	if not can_afford(clean):
		return false
	var delta := {}
	for res: String in clean:
		_treasury[res] = int(_treasury.get(res, 0)) - int(clean[res])
		delta[res] = -int(clean[res])
	_spends[op_id] = {"cost": clean, "refunded": false, "reason": reason, "ref": ref}
	_log(op_id, reason, delta)
	return true


func refund(op_id: String, spend_op_id: String, fraction: float) -> Dictionary:
	if _results.has(op_id):
		return (_results[op_id] as Dictionary).duplicate()
	var rec: Dictionary = _spends.get(spend_op_id, {})
	if rec.is_empty() or bool(rec.get("refunded", false)):
		_remember(op_id, {})
		return {}
	var f := clampf(fraction, 0.0, 1.0)
	var cost: Dictionary = rec["cost"]
	var out := {}
	for res: String in cost:
		var spent := int(cost[res])
		var amt := mini(int(floor(float(spent) * f + 0.000001)), spent)
		if amt > 0:
			_treasury[res] = int(_treasury.get(res, 0)) + amt
			out[res] = amt
	rec["refunded"] = true
	_remember(op_id, out)
	if not out.is_empty():
		_log(op_id, "refund", out)
	return out.duplicate()


func deposit(op_id: String, deposits: Dictionary, storehouses: int) -> Dictionary:
	if _results.has(op_id):
		return (_results[op_id] as Dictionary).duplicate()
	var out := {}
	for res: Variant in deposits.keys():
		var key := String(res)
		var amt := maxi(int(deposits[res]), 0)
		if amt == 0:
			continue
		var cap := storage_cap(key, storehouses)
		if cap >= 0:
			amt = mini(amt, maxi(cap - int(_treasury.get(key, 0)), 0))
		if amt > 0:
			_treasury[key] = int(_treasury.get(key, 0)) + amt
			out[key] = amt
	_remember(op_id, out)
	if not out.is_empty():
		_log(op_id, "gather", out)
	return out.duplicate()


## True when the spend exists and has not been refunded yet.
func is_refundable(spend_op_id: String) -> bool:
	var rec: Dictionary = _spends.get(spend_op_id, {})
	return not rec.is_empty() and not bool(rec.get("refunded", false))


func to_dict() -> Dictionary:
	return {
		"kind": "local",
		"age": _age,
		"treasury": _treasury.duplicate(),
		"spends": _spends.duplicate(true),
	}


func load_dict(d: Dictionary) -> void:
	_age = maxi(int(d.get("age", 1)), 1)
	var t: Dictionary = d.get("treasury", {})
	for res in _econ.resource_names():
		_treasury[res] = int(t.get(res, 0))
	_spends.clear()
	var spends: Dictionary = d.get("spends", {})
	for op: Variant in spends.keys():
		var rec: Dictionary = spends[op]
		var cost := {}
		var src: Dictionary = rec.get("cost", {})
		for res: Variant in src.keys():
			cost[String(res)] = int(src[res])
		_spends[String(op)] = {
			"cost": cost,
			"refunded": bool(rec.get("refunded", false)),
			"reason": String(rec.get("reason", "")),
			"ref": String(rec.get("ref", "")),
		}
	_results.clear()
	_result_order.clear()
	changed.emit(treasury(), "load", {})


func _positive(cost: Dictionary) -> Dictionary:
	var out := {}
	for res: Variant in cost.keys():
		var v := int(cost[res])
		if v > 0:
			out[String(res)] = v
	return out


func _remember(op_id: String, result: Dictionary) -> void:
	_results[op_id] = result.duplicate()
	_result_order.append(op_id)
	while _result_order.size() > MAX_REMEMBERED_RESULTS:
		_results.erase(_result_order.pop_front())


func _log(op_id: String, reason: String, delta: Dictionary) -> void:
	entries.append({"op": op_id, "reason": reason, "delta": delta.duplicate()})
	while entries.size() > MAX_ENTRIES:
		entries.pop_front()
	changed.emit(treasury(), reason, delta.duplicate())
