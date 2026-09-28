class_name IncomeTracker
extends RefCounted
## Rolling income per resource over the last minute of simulation time, for the top-bar
## tooltips. Fed from the simulation's "deposited" notices; not part of the saved state.

const WINDOW_S := 60

var window_ticks: int = 1200
## Entries [tick, resource, amount], oldest first.
var _events: Array = []


func _init(tick_rate: int = 20) -> void:
	window_ticks = maxi(1, tick_rate * WINDOW_S)


func record(tick: int, res: String, amount: int) -> void:
	if amount > 0:
		_events.append([tick, res, amount])


## Amount of `res` gathered during the last minute of simulation time.
func per_minute(res: String, now_tick: int) -> int:
	_trim(now_tick)
	var total := 0
	for e: Array in _events:
		if String(e[1]) == res:
			total += int(e[2])
	return total


func clear() -> void:
	_events.clear()


func _trim(now_tick: int) -> void:
	var cutoff := now_tick - window_ticks
	var drop := 0
	while drop < _events.size() and int(_events[drop][0]) < cutoff:
		drop += 1
	if drop > 0:
		_events = _events.slice(drop)
