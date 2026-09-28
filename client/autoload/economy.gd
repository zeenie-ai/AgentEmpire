extends Node
## Economy data (res://data/economy.json) plus the active resource ledger.
##
## Offline the ledger is a LocalLedger. Phase 3 swaps in a Town Hall-backed Ledger with
## set_ledger(); the simulation and the HUD only ever talk to the Ledger interface.

## Re-emitted from the active ledger.
signal treasury_changed(treasury: Dictionary, reason: String, delta: Dictionary)
signal ledger_swapped(ledger: Ledger)

var data: EconomyData
var ledger: Ledger


func _ready() -> void:
	data = EconomyData.load_default()
	if not data.is_valid():
		ClientLog.error("economy", "Could not load economy data: %s. Run node scripts/sync-economy.mjs." % data.load_error)
		return
	reset_local_ledger()


## Fresh offline ledger with the starting resources.
func reset_local_ledger() -> LocalLedger:
	var l := LocalLedger.new(data, data.start_resources(), data.start_age())
	set_ledger(l)
	return l


func set_ledger(l: Ledger) -> void:
	if ledger != null and ledger.changed.is_connected(_on_changed):
		ledger.changed.disconnect(_on_changed)
	ledger = l
	ledger.changed.connect(_on_changed)
	ledger_swapped.emit(ledger)
	treasury_changed.emit(ledger.treasury(), "swap", {})


func _on_changed(treasury: Dictionary, reason: String, delta: Dictionary) -> void:
	treasury_changed.emit(treasury, reason, delta)
