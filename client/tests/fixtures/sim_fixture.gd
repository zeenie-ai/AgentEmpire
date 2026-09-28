class_name SimFixture
extends RefCounted
## Helpers for headless simulation tests.


static func econ() -> EconomyData:
	return EconomyData.load_default()


static func ledger(e: EconomyData, start: Dictionary = {}) -> LocalLedger:
	return LocalLedger.new(e, e.start_resources() if start.is_empty() else start, e.start_age())


## An empty map with only the Keep at the centre and a deterministic path service.
static func empty_world(start: Dictionary = {}) -> SimWorld:
	var e := econ()
	var w := SimWorld.create_empty(e, ledger(e, start))
	w.path_service.deterministic = true
	return w


## A generated map (Keep, resources, starting townsfolk) with a deterministic path service.
static func generated_world(seed_value: int, start: Dictionary = {}) -> SimWorld:
	var e := econ()
	var w := SimWorld.create_new(e, ledger(e, start), seed_value, "test-%d" % seed_value)
	w.path_service.deterministic = true
	return w


static func keep_rect(w: SimWorld) -> Rect2i:
	return w.keep().rect()


## Seconds of simulation to ticks.
static func ticks(w: SimWorld, seconds: float) -> int:
	return int(round(seconds * float(w.tick_rate)))


static func big_purse() -> Dictionary:
	return {"food": 5000, "wood": 5000, "stone": 5000, "gold": 5000}
