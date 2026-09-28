@abstract
class_name Ledger
extends RefCounted
## The resource ledger as seen by the simulation and the HUD.
##
## Offline play uses LocalLedger. In Phase 3 a Town Hall-backed ledger takes its place through
## Economy.set_ledger(): it keeps an optimistic mirror of the server treasury, forwards
## spend() / refund() / deposit() as spend_resources / refund_resources / report_gather (the
## op_id doubles as the protocol's idempotency key) and emits `rejected` when the server
## refuses an operation the mirror had already accepted. Every call is synchronous so the
## fixed-tick simulation never waits on the network.
##
## Rules every implementation keeps (PROTOCOL.md, "Rules both sides rely on"):
## - spend() charges the whole cost or nothing, and repeating an op_id never charges twice;
## - refund() pays back at most once per spend, never more than was spent;
## - deposit() is subject to the Food and Wood storage caps (by age, plus Storehouses);
##   rewards and refunds may exceed a cap, gathering may not.

## Emitted after every balance change. `delta` holds the signed change per resource.
signal changed(treasury: Dictionary, reason: String, delta: Dictionary)
## Emitted when an optimistically applied operation is refused later (remote ledgers only).
signal rejected(op_id: String, code: String)


## Current balances, {"food": int, "wood": int, "stone": int, "gold": int}. A copy.
@abstract func treasury() -> Dictionary

@abstract func age() -> int

@abstract func set_age(value: int) -> void

## Charges `cost` in full or not at all. Returns false when the treasury cannot cover it.
@abstract func spend(op_id: String, reason: String, cost: Dictionary, ref: String) -> bool

## Refunds `fraction` (clamped to 0..1) of the spend `spend_op_id`. Returns the amounts paid
## back, or {} when the spend is unknown or was already refunded.
@abstract func refund(op_id: String, spend_op_id: String, fraction: float) -> Dictionary

## Adds gathered resources, clipped to the storage caps. Returns the amounts accepted.
@abstract func deposit(op_id: String, deposits: Dictionary, storehouses: int) -> Dictionary

## Storage cap for `res` with `storehouses` completed Storehouses, or -1 when uncapped.
@abstract func storage_cap(res: String, storehouses: int) -> int

@abstract func to_dict() -> Dictionary

@abstract func load_dict(d: Dictionary) -> void


func amount(res: String) -> int:
	return int(treasury().get(res, 0))


func can_afford(cost: Dictionary) -> bool:
	return missing(cost).is_empty()


## Shortfall per resource for `cost`; empty when affordable.
func missing(cost: Dictionary) -> Dictionary:
	var out := {}
	var t := treasury()
	for res: Variant in cost.keys():
		var need := int(cost[res])
		var have := int(t.get(res, 0))
		if need > have:
			out[String(res)] = need - have
	return out
