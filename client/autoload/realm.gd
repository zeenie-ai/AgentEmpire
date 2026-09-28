extends Node
## Phase 3 stub: local copies of Town Hall state (agents, tools, tasks, approvals, parties,
## incidents, Mana and the age), replaced by id from agent_updated / task_updated / ... events.

signal mana_changed(mana: Dictionary)

var agents: Dictionary = {}
var tools: Dictionary = {}
var tasks: Dictionary = {}
var approvals: Dictionary = {}
var mana: Dictionary = {}
var age: Dictionary = {"current": 1, "research": null}


## "offline" until the Town Hall is connected; later "normal", "dim", "warning" or "depleted".
func mana_level() -> String:
	if not Net.is_online() or mana.is_empty():
		return "offline"
	return String(mana.get("level", "normal"))
