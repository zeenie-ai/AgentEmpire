class_name PathService
extends RefCounted
## Queues path requests and spends a limited time budget on them each tick, so a burst of
## orders spreads over several ticks instead of stalling a frame. Units wait (standing) until
## their path is ready. At least one request is served per tick.
##
## `deterministic` switches the budget from wall-clock time to a fixed count per tick, so tests
## and future lockstep play get identical results on every machine.

var budget_usec: int = 2500
var max_per_tick: int = 48
var deterministic: bool = false

var last_tick_served: int = 0
var last_tick_usec: int = 0
var total_served: int = 0

var _queue: Array[int] = []
var _queued: Dictionary = {}


func request(unit_id: int) -> void:
	if _queued.has(unit_id):
		return
	_queued[unit_id] = true
	_queue.append(unit_id)


func cancel(unit_id: int) -> void:
	if _queued.has(unit_id):
		_queued.erase(unit_id)
		_queue.erase(unit_id)


func pending() -> int:
	return _queue.size()


func is_queued(unit_id: int) -> bool:
	return _queued.has(unit_id)


## Serves queued requests through `world.compute_path(unit)`. Returns how many were served.
func process(world: SimWorld) -> int:
	var start := Time.get_ticks_usec()
	var served := 0
	while not _queue.is_empty() and served < max_per_tick:
		if not deterministic and served > 0 and Time.get_ticks_usec() - start >= budget_usec:
			break
		var id: int = _queue.pop_front()
		_queued.erase(id)
		var u: SimUnit = world.units.get(id)
		if u == null or u.path_state != SimConst.PATH_PENDING:
			continue
		world.compute_path(u)
		served += 1
	last_tick_served = served
	last_tick_usec = Time.get_ticks_usec() - start
	total_served += served
	return served


func snapshot() -> Array:
	return _queue.duplicate()


func restore(ids: Array) -> void:
	_queue.clear()
	_queued.clear()
	for v: Variant in ids:
		request(int(v))
