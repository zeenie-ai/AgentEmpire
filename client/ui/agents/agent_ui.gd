class_name AgentUi
extends RefCounted
## Shared helpers for the agent windows and panels: display names (harnesses, roles, states,
## approval categories), numbers (Mana, money, XP), times ("2 min ago"), colours, lore names and
## oath templates, and small widget factories (labels, section headers, pills, cost rows, key
## caps). Everything protocol-shaped is read null-safely through J.

const Protocol = preload("res://net/protocol.gd")

## Harness ids as the player knows them. Unknown ids are shown capitalised.
const HARNESS_NAMES := {"claude": "Claude Code", "codex": "Codex", "pi": "pi"}

const LORE_NAMES := ["Mira", "Aldric", "Seraphine", "Corvin", "Isolde", "Thessaly", "Rowan", "Elowen",
	"Brannoc", "Liora", "Caspian", "Wynne", "Osric", "Ysmay", "Tamsin", "Evander", "Maelis", "Ronan",
	"Sabine", "Idris", "Nerys", "Galen", "Ottilie", "Percival", "Rhosyn", "Soren", "Vesper", "Alaric",
	"Brisa", "Cedric", "Delphine", "Emrys", "Faelan", "Hesper", "Ione", "Kestrel", "Lucan", "Morwen",
	"Orla", "Peregrine", "Sigrun", "Ulric", "Valen", "Wystan", "Zephyrine", "Anselm", "Elspeth", "Torvald"]

const OATHS := {
	"artificer": "You are {name}, an Artificer of Aurelhaven. You build and change code.\n\n- Read the code around a change before you make it, and follow the project's existing style.\n- Keep each change small and focused on the task you were given.\n- Add or update tests for the behaviour you change.\n- Run the Rite (the project's checks) before you finish, and fix what fails.\n- Never touch secrets, credentials or files outside your work folder.\n- Finish with a short summary: what changed, why, and anything left to do.",
	"scholar": "You are {name}, a Scholar of Aurelhaven. You research questions and report what you find.\n\n- Prefer primary sources: official documentation, specifications and the code itself.\n- Say where each finding comes from, with links or file paths.\n- Keep what you verified apart from what you believe.\n- Do not change code unless the task asks for it.\n- Answer the question first, then give the details and the open questions.",
	"scribe": "You are {name}, a Scribe of Aurelhaven. You write and keep the documentation.\n\n- Write for the reader who has to use it: clear, concrete and brief.\n- Match the tone and format of the existing documents.\n- Check every command, path and example against the code before you write it down.\n- Prefer updating existing pages to creating new ones.\n- Finish with the pages you changed and why.",
	"warden": "You are {name}, a Warden of Aurelhaven. You review changes and test them.\n\n- Look for bugs, missing edge cases, security problems and unclear code.\n- Run the tests and the Rite; report failures with their exact output.\n- Add a test that pins down every bug you find.\n- Point to files and lines, and rank your findings by severity.\n- Do not rewrite working code for style alone.",
	"herald": "You are {name}, a Herald of Aurelhaven. You handle operations and automation.\n\n- Prefer safe, reversible steps, and say what a command will do before you run it.\n- Never print, copy or commit secrets.\n- Keep scripts idempotent and easy to read.\n- Check the result of each step before you take the next one.\n- Finish with what you did, what changed and how to undo it.",
}


# --- names --------------------------------------------------------------------------------------

static func harness_name(id: String) -> String:
	if HARNESS_NAMES.has(id):
		return String(HARNESS_NAMES[id])
	return id.capitalize() if id != "" else "Unknown harness"


## "ready", "logged_out" or "missing" for a check_providers entry.
static func harness_state(p: Dictionary) -> String:
	if not J.b(p.get("installed"), false):
		return "missing"
	if not J.b(p.get("logged_in"), false):
		return "logged_out"
	return "ready"


static func harness_state_text(state: String) -> String:
	match state:
		"ready":
			return "Ready"
		"logged_out":
			return "Not logged in"
	return "Not installed"


static func harness_state_color(state: String, look: int) -> Color:
	match state:
		"ready":
			return AgentTheme.c(look, "good")
		"logged_out":
			return AgentTheme.c(look, "warn")
	return AgentTheme.c(look, "bad")


static func billing_name(billing: String) -> String:
	match billing:
		Protocol.Billing.SUBSCRIPTION:
			return "Subscription"
		Protocol.Billing.API_KEY:
			return "API key"
	return "Billing unknown"


static func billing_note(billing: String) -> String:
	match billing:
		Protocol.Billing.SUBSCRIPTION:
			return "Runs on your subscription; Mana use is estimated."
		Protocol.Billing.API_KEY:
			return "Pays per use with an API key; Mana use is exact."
	return "Billing has not been detected yet."


static func role_icon(role: String) -> String:
	return "agent_" + role if role != "" else "summon"


## An add-on's name ("Lectern"). Read from the tools table: EconomyData.building_def() never
## reaches it for add-on types (its lookup defaults to an empty dictionary).
static func addon_name(type: String) -> String:
	var d := Economy.data.tool_def(type)
	return String(d.get("name", Economy.data.building_name(type))) if not d.is_empty() else Economy.data.building_name(type)


static func addon_plain(type: String) -> String:
	var d := Economy.data.tool_def(type)
	return String(d.get("plain", "")) if not d.is_empty() else Economy.data.building_plain(type)


static func addon_cost(type: String) -> Dictionary:
	var d := Economy.data.tool_def(type)
	return EconomyData._int_dict(d.get("cost", {})) if not d.is_empty() else Economy.data.building_cost(type)


## The display name of a building or an add-on.
static func structure_name(type: String) -> String:
	return addon_name(type) if Economy.data.is_tool(type) else Economy.data.building_name(type)


static func size_label(size: String) -> String:
	return "%s (%s)" % [Economy.data.size_name(size), size]


static func state_text(state: String) -> String:
	match state:
		Protocol.TaskState.IN_TRANSIT:
			return "On its way"
		Protocol.TaskState.QUEUED:
			return "Queued"
		Protocol.TaskState.PREPARING:
			return "Preparing"
		Protocol.TaskState.RUNNING:
			return "Working"
		Protocol.TaskState.AWAITING_APPROVAL:
			return "Waiting for approval"
		Protocol.TaskState.AWAITING_REVIEW:
			return "Ready for review"
		Protocol.TaskState.ACCEPTING:
			return "Accepting"
		Protocol.TaskState.ACCEPTED:
			return "Accepted"
		Protocol.TaskState.REJECTED:
			return "Set aside"
		Protocol.TaskState.PAUSED:
			return "Paused"
		Protocol.TaskState.FAILED:
			return "Failed"
		Protocol.TaskState.CANCELLED:
			return "Cancelled"
	return state.capitalize()


## What an agent is doing in a task_progress phase ("Using Bash at the Forge").
static func phase_text(phase: String, tool: String) -> String:
	match phase:
		Protocol.ProgressPhase.PREPARING:
			return "Preparing the workspace"
		Protocol.ProgressPhase.TOOL:
			if tool == "":
				return "Using a tool"
			var addon := TownLink.addon_for_tool(tool)
			if addon != "":
				return "Using %s at the %s" % [tool, addon_name(addon)]
			return "Using %s" % tool
		Protocol.ProgressPhase.DELEGATING:
			return "Delegating to the party"
		Protocol.ProgressPhase.FINISHING:
			return "Finishing up"
		Protocol.ProgressPhase.RITE:
			return "Performing the Rite"
	return "Thinking it through"


static func blocked_text(reason: String, agent: Dictionary) -> String:
	match reason:
		Protocol.BlockedReason.MISSING_TOOLS:
			return "Blocked: a required add-on is missing"
		Protocol.BlockedReason.NO_MANA:
			return "Blocked: not enough Mana to start the next task"
		Protocol.BlockedReason.PROVIDER_OFFLINE:
			return "Blocked: %s is offline" % harness_name(J.gs(agent, "provider"))
		Protocol.BlockedReason.WORKSPACE_ERROR:
			return "Blocked: the work folder has a problem"
	return "Blocked"


static func pause_text(reason: String) -> String:
	match reason:
		Protocol.PauseReason.BUDGET:
			return "its Mana seal is spent"
		Protocol.PauseReason.MANA_DEPLETED:
			return "the Mana pool is empty"
		Protocol.PauseReason.STALLED:
			return "no progress for a long time"
		Protocol.PauseReason.RESTART:
			return "the Town Hall restarted"
		Protocol.PauseReason.PROVIDER_LIMIT:
			return "the harness hit its usage limit"
	return "waiting"


static func merge_blocked_text(reason: String) -> String:
	match reason:
		Protocol.MergeBlockedReason.CHECKOUT_DIRTY:
			return "Your main checkout has uncommitted changes. Commit or stash them, then accept again."
		Protocol.MergeBlockedReason.WRONG_BRANCH:
			return "Your main checkout is on a different branch from the one the agent started on. Switch back, then accept again."
		Protocol.MergeBlockedReason.CONFLICT:
			return "The agent's changes conflict with your checkout. Resolve the conflict or keep the work on its branch."
		Protocol.MergeBlockedReason.MERGE_FAILED:
			return "Git could not merge the agent's branch."
		Protocol.MergeBlockedReason.EXPORT_CONFLICT:
			return "Some of these files changed in your work folder since the agent started, so nothing was written. Save or undo your edits there, then accept again."
		Protocol.MergeBlockedReason.NOT_A_REPO:
			return "The work folder is not a git repository, so there is nothing to merge. Export the files instead."
		Protocol.MergeBlockedReason.WORKSPACE_MISSING:
			return "The agent's workspace is missing."
	return "The Town Hall could not integrate the work."


static func zero_reward_text(reason: String) -> String:
	match reason:
		"duplicate":
			return "No reward: the same task was accepted recently."
		"no_deliverable":
			return "No reward: the agent delivered nothing to integrate."
		"too_short":
			return "No reward: the work finished too quickly to count."
		"party_subtask":
			return "No reward here: party subtasks pay out through their lead's task."
	return "No reward for this task."


## What an agent is doing, for its status line: {"text", "mood", "task_id"?}. mood: "training",
## "settling", "working", "waiting" (for the player's approval), "review", "blocked", "paused",
## "idle" or "retired". `link` answers training_left_s() and waiting_tools (TownLink or a fake).
static func agent_status(a: Dictionary, link: Object = null) -> Dictionary:
	var id := J.gs(a, "id")
	match J.gs(a, "lifecycle"):
		Protocol.AgentLifecycle.RETIRED:
			return {"text": "Retired", "mood": "retired"}
		Protocol.AgentLifecycle.TRAINING:
			var left := 0.0
			if link != null and link.has_method("training_left_s"):
				left = float(link.call("training_left_s", id))
			return {"text": ("Training at the Keep: %d s left" % ceili(left)) if left > 0.0 else "Training at the Keep", "mood": "training"}
		Protocol.AgentLifecycle.SETTLING:
			var home: Variant = a.get("home")
			var home_name := Economy.data.building_name(Economy.data.role_home(J.gs(a, "role")))
			if typeof(home) != TYPE_DICTIONARY:
				return {"text": "Waiting for a plot: choose where the %s goes" % home_name, "mood": "settling"}
			if not J.b((home as Dictionary).get("built"), false):
				return {"text": "Building the %s" % home_name, "mood": "settling"}
			var wait := waiting_tool(link, id)
			if not wait.is_empty():
				return {"text": "Needs %s to build the %s" % [cost_text(J.gd(wait, "missing")), addon_name(J.gs(wait, "tool"))], "mood": "blocked"}
			var building: PackedStringArray = []
			for t in Realm.tools_of(id):
				if J.gs(t, "status") == Protocol.ToolStatus.BUILDING:
					building.append(addon_name(J.gs(t, "type")))
			if not building.is_empty():
				return {"text": "Setting up: building the %s" % ", ".join(building), "mood": "settling"}
			return {"text": "Settling in", "mood": "settling"}
	var cur := Realm.current_task(id)
	match J.gs(a, "activity", "idle"):
		Protocol.AgentActivity.AWAITING_APPROVAL:
			return {"text": "Waiting for your approval", "mood": "waiting", "task_id": J.gs(cur, "id")}
		Protocol.AgentActivity.WORKING:
			var p: Dictionary = Realm.progress.get(J.gs(cur, "id"), {})
			var what := phase_text(J.gs(p, "phase", Protocol.ProgressPhase.WORKING), J.gs(p, "current_tool"))
			return {"text": "Working: " + what.left(1).to_lower() + what.substr(1), "mood": "working", "task_id": J.gs(cur, "id")}
		Protocol.AgentActivity.BLOCKED:
			return {"text": blocked_text(J.gs(a, "blocked_reason"), a), "mood": "blocked"}
	for t in Realm.tasks_of(id):
		var s := J.gs(t, "state")
		if s == Protocol.TaskState.AWAITING_REVIEW or s == Protocol.TaskState.ACCEPTING:
			return {"text": "Result ready for review", "mood": "review", "task_id": J.gs(t, "id")}
	for t in Realm.tasks_of(id):
		match J.gs(t, "state"):
			Protocol.TaskState.PAUSED:
				return {"text": "Paused: %s" % pause_text(J.gs(t, "state_reason")), "mood": "blocked", "task_id": J.gs(t, "id")}
			Protocol.TaskState.FAILED:
				return {"text": "A task failed: resume or dismiss it", "mood": "blocked", "task_id": J.gs(t, "id")}
			Protocol.TaskState.IN_TRANSIT:
				return {"text": "Idle: a scroll is on its way", "mood": "idle", "task_id": J.gs(t, "id")}
			Protocol.TaskState.QUEUED, Protocol.TaskState.PREPARING:
				return {"text": "Starting the next task", "mood": "working", "task_id": J.gs(t, "id")}
	return {"text": "Idle: ready for a task", "mood": "idle"}


static func mood_color(mood: String, look: int) -> Color:
	match mood:
		"working":
			return AgentTheme.c(look, "good")
		"waiting", "paused":
			return AgentTheme.c(look, "warn")
		"review":
			return AgentTheme.c(look, "accent2")
		"blocked":
			return AgentTheme.c(look, "bad")
		"training", "settling":
			return AgentTheme.c(look, "info")
		"retired":
			return AgentTheme.c(look, "faint")
	return AgentTheme.c(look, "soft")


## The add-on an agent waits to afford ({"tool", "missing"}), from link.waiting_tools, or {}.
static func waiting_tool(link: Object, agent_id: String) -> Dictionary:
	if link == null:
		return {}
	var w: Variant = link.get("waiting_tools")
	if typeof(w) != TYPE_DICTIONARY:
		return {}
	return J.d((w as Dictionary).get(agent_id))


## Tasks waiting at an agent's home (in transit or queued), which the age's queue limit counts.
static func waiting_count(agent_id: String) -> int:
	var n := 0
	for t in Realm.tasks_of(agent_id):
		var s := J.gs(t, "state")
		if (s == Protocol.TaskState.IN_TRANSIT or s == Protocol.TaskState.QUEUED) and t.get("parent_task_id") == null:
			n += 1
	return n


# --- approval categories, risk and ranks -------------------------------------------------------------

static func category_color(category: String) -> Color:
	match category:
		Protocol.ApprovalCategory.READ:
			return Color("#7fb6ff")
		Protocol.ApprovalCategory.WRITE:
			return Color("#ffd27a")
		Protocol.ApprovalCategory.COMMAND:
			return Color("#ff9d57")
		Protocol.ApprovalCategory.NETWORK:
			return Color("#c49bff")
		Protocol.ApprovalCategory.OUTSIDE_WORKSPACE:
			return Color("#ff6b6b")
		Protocol.ApprovalCategory.MCP:
			return Color("#5fe3c3")
	return Color("#b8c4d8")


static func category_name(category: String) -> String:
	match category:
		Protocol.ApprovalCategory.READ:
			return "Read"
		Protocol.ApprovalCategory.WRITE:
			return "Write"
		Protocol.ApprovalCategory.COMMAND:
			return "Command"
		Protocol.ApprovalCategory.NETWORK:
			return "Network"
		Protocol.ApprovalCategory.OUTSIDE_WORKSPACE:
			return "Outside workspace"
		Protocol.ApprovalCategory.MCP:
			return "MCP tool"
	return category.capitalize()


## "wants to run a command", used under the agent's name on a petition.
static func category_verb(category: String) -> String:
	match category:
		Protocol.ApprovalCategory.READ:
			return "wants to read files"
		Protocol.ApprovalCategory.WRITE:
			return "wants to change files"
		Protocol.ApprovalCategory.COMMAND:
			return "wants to run a command"
		Protocol.ApprovalCategory.NETWORK:
			return "wants to reach the network"
		Protocol.ApprovalCategory.OUTSIDE_WORKSPACE:
			return "wants to leave its work folder"
		Protocol.ApprovalCategory.MCP:
			return "wants to use an MCP tool"
	return "asks for permission"


## What a task or agent rule made from this approval would cover, as the Town Hall matches it:
## the first two words of a command, the host of a network request, otherwise the tool.
## "“npm install” commands", "requests to developer.mozilla.org", "Edit".
static func approval_reach(approval: Dictionary) -> String:
	var tool := J.gs(approval, "tool", "this tool")
	var parsed: Variant = JSON.parse_string(J.gs(approval, "input_preview"))
	var input := J.d(parsed)
	match J.gs(approval, "category"):
		Protocol.ApprovalCategory.COMMAND:
			var words := J.gs(input, "command").strip_edges().split(" ", false)
			if not words.is_empty():
				return "“%s” commands" % " ".join(words.slice(0, 2)).to_lower()
		Protocol.ApprovalCategory.NETWORK:
			var host := J.gs(input, "url").get_slice("://", 1).get_slice("/", 0).to_lower()
			if host != "":
				return "requests to %s" % host
	return tool


static func risk_color(risk: String) -> Color:
	match risk:
		Protocol.Risk.LOW:
			return Color("#8fe3a8")
		Protocol.Risk.HIGH:
			return Color("#ff6b5a")
	return Color("#ffc15a")


static func rank_color(rank: String) -> Color:
	match rank:
		"E":
			return Color("#7fcf8a")
		"D":
			return Color("#6fb2ff")
		"C":
			return Color("#b58cff")
		"B":
			return Color("#ffa45a")
		"A":
			return Color("#ff6b6b")
		"S":
			return Color("#ffd27a")
	return Color("#b3a28c")


## The ranks in order, lowest first ("F", "E", ... "S").
static func rank_order() -> Array[String]:
	var out: Array[String] = []
	var ranks: Variant = Economy.data.raw.get("ranks", [])
	if typeof(ranks) == TYPE_ARRAY:
		for r: Variant in ranks:
			if typeof(r) == TYPE_DICTIONARY:
				out.append(J.gs(r, "rank"))
	if out.is_empty():
		out.assign(["F", "E", "D", "C", "B", "A", "S"])
	return out


static func rank_at_least(rank: String, minimum: String) -> bool:
	var order := rank_order()
	return order.find(rank) >= order.find(minimum)


## XP needed to reach `level` (economy.json levels.xp_for_level, "50 * L * (L - 1)").
static func xp_for_level(level: int) -> int:
	var formula := String(Economy.data.section("levels").get("xp_for_level", "50 * L * (L - 1)"))
	var e := Expression.new()
	if e.parse(formula, ["L"]) == OK:
		var v: Variant = e.execute([level])
		if not e.has_execute_failed() and typeof(v) in [TYPE_INT, TYPE_FLOAT]:
			return int(v)
	return 50 * level * (level - 1)


static func max_level() -> int:
	return int(Economy.data.section("levels").get("max", 30))


## {"into": XP past this level, "span": XP from this level to the next, "ratio": 0..1, "max": bool}.
static func level_progress(xp: int, level: int) -> Dictionary:
	if level >= max_level():
		return {"into": 0, "span": 0, "ratio": 1.0, "max": true}
	var base := xp_for_level(level)
	var next := xp_for_level(level + 1)
	var span := maxi(next - base, 1)
	var into := clampi(xp - base, 0, span)
	return {"into": into, "span": span, "ratio": float(into) / float(span), "max": false}


# --- numbers ---------------------------------------------------------------------------------------

static func micros_per_mana() -> int:
	return Economy.data.micros_per_mana()


static func mana_of(micros: int) -> float:
	return float(micros) / float(micros_per_mana())


## "1,250" (whole Mana).
static func mana_text(micros: int) -> String:
	return group(roundi(mana_of(micros)))


## "$12.50"
static func usd_text(micros: int) -> String:
	return "$%.2f" % (float(micros) / 1000000.0)


## "$0.40" for an amount of Mana.
static func mana_usd(mana: float) -> String:
	return "$%.2f" % (mana * float(micros_per_mana()) / 1000000.0)


## 12345 -> "12,345"
static func group(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


# --- time --------------------------------------------------------------------------------------------

## Unix seconds of an ISO-8601 time ("2026-09-28T10:00:00.000Z"), or 0 when unreadable.
static func unix_of(iso: String) -> float:
	if iso.length() < 19:
		return 0.0
	return float(Time.get_unix_time_from_datetime_string(iso.substr(0, 19)))


static func now_unix() -> float:
	return Time.get_unix_time_from_system()


static func seconds_since(iso: String) -> float:
	var u := unix_of(iso)
	return maxf(now_unix() - u, 0.0) if u > 0.0 else 0.0


static func ago_text(seconds: float) -> String:
	var s := int(maxf(seconds, 0.0))
	if s < 10:
		return "just now"
	if s < 60:
		return "%d s ago" % s
	if s < 3600:
		return "%d min ago" % (s / 60)
	if s < 86400:
		return "%d h ago" % (s / 3600)
	return "%d d ago" % (s / 86400)


## "5 h 12 min", "12 min", "45 s".
static func duration_text(seconds: float) -> String:
	var s := int(maxf(seconds, 0.0))
	if s >= 86400:
		return "%d d %d h" % [s / 86400, (s % 86400) / 3600]
	if s >= 3600:
		return "%d h %d min" % [s / 3600, (s % 3600) / 60]
	if s >= 60:
		return "%d min" % (s / 60)
	return "%d s" % s


## Local wall-clock time of an ISO time: "14:05:09".
static func local_clock(iso: String, with_seconds: bool = true) -> String:
	var u := unix_of(iso)
	if u <= 0.0:
		return "--:--"
	var bias := int(Time.get_time_zone_from_system().get("bias", 0))
	var d := Time.get_datetime_dict_from_unix_time(int(u) + bias * 60)
	if with_seconds:
		return "%02d:%02d:%02d" % [int(d.get("hour", 0)), int(d.get("minute", 0)), int(d.get("second", 0))]
	return "%02d:%02d" % [int(d.get("hour", 0)), int(d.get("minute", 0))]


# --- lore --------------------------------------------------------------------------------------------

## A lore name no agent in town has yet.
static func random_name(taken: Array = []) -> String:
	var free: Array[String] = []
	for n: String in LORE_NAMES:
		if not n in taken:
			free.append(n)
	if free.is_empty():
		return String(LORE_NAMES[randi() % LORE_NAMES.size()])
	return free[randi() % free.size()]


static func oath_for(role: String, agent_name: String) -> String:
	var template := String(OATHS.get(role, "You are {name}, an agent of Aurelhaven.\n\n- Keep your work focused on the task.\n- Finish with a short summary of what you did."))
	return template.replace("{name}", agent_name if agent_name.strip_edges() != "" else "an agent")


# --- widgets -----------------------------------------------------------------------------------------

static func label(text: String, variation: String = "", parent: Node = null) -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	if parent != null:
		parent.add_child(l)
	return l


## A label that wraps inside its container.
static func para(text: String, variation: String = "Body", parent: Node = null) -> Label:
	var l := label(text, variation, parent)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


static func hbox(separation: int = 8, parent: Node = null) -> HBoxContainer:
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", separation)
	if parent != null:
		parent.add_child(b)
	return b


static func vbox(separation: int = 6, parent: Node = null) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.add_theme_constant_override("separation", separation)
	if parent != null:
		parent.add_child(b)
	return b


static func spacer(parent: Node = null, expand: bool = true, px: float = 0.0) -> Control:
	var s := Control.new()
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.custom_minimum_size = Vector2(px, px)
	if expand:
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if parent != null:
		parent.add_child(s)
	return s


## "TITLE ———" with an optional note on the right ("OPTIONAL", "3 / 4 SLOTS").
static func section(title: String, look: int, note: String = "", parent: Node = null) -> HBoxContainer:
	var row := hbox(10, parent)
	var l := label(title.to_upper(), "Section", row)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var rule := Rule.new()
	rule.color = AgentTheme.c(look, "line")
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(rule)
	if note != "":
		var n := label(note.to_upper(), "MonoSmall", row)
		n.name = "Note"
		n.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return row


## The note label of a section() row, or null.
static func section_note(row: Control) -> Label:
	return row.get_node_or_null("Note") as Label


static func pill(text: String, color: Color, filled: bool = false, parent: Node = null, text_color: Color = Color(0, 0, 0, 0)) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_PASS
	p.add_theme_stylebox_override("panel", AgentTheme.pill_box(color, filled))
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_override("font", UiFonts.mono(700, 1))
	l.add_theme_font_size_override("font_size", 10)
	var tc := text_color
	if tc.a <= 0.0:
		tc = Color("#10131f") if filled else color.lightened(0.15)
	l.add_theme_color_override("font_color", tc)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(l)
	if parent != null:
		parent.add_child(p)
	return p


static func set_pill(p: PanelContainer, text: String, color: Color, filled: bool = false) -> void:
	p.add_theme_stylebox_override("panel", AgentTheme.pill_box(color, filled))
	var l := p.get_child(0) as Label
	l.text = text.to_upper()
	l.add_theme_color_override("font_color", Color("#10131f") if filled else color.lightened(0.15))


static func keycap(text: String, look: int, parent: Node = null) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", AgentTheme.keycap_box(look))
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", UiFonts.mono(700, 1))
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", UiTokens.GOLD_BRIGHT if look == AgentTheme.DOCUMENT else AgentTheme.c(look, "soft"))
	p.add_child(l)
	if parent != null:
		parent.add_child(p)
	return p


## Resource chips: an icon and an amount for each resource of `cost`. With `have`, amounts the
## treasury cannot cover turn red. `struck` draws them crossed out (free under Font's Grace).
static func cost_row(cost: Dictionary, look: int, have: Dictionary = {}, struck: bool = false, icon_px: float = 16.0) -> HBoxContainer:
	var row := hbox(10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fill_cost_row(row, cost, look, have, struck, icon_px)
	return row


static func fill_cost_row(row: HBoxContainer, cost: Dictionary, look: int, have: Dictionary = {}, struck: bool = false, icon_px: float = 16.0) -> void:
	for ch in row.get_children():
		row.remove_child(ch)
		ch.queue_free()
	var any := false
	for res in Economy.data.resource_names():
		var n := int(cost.get(res, 0))
		if n <= 0:
			continue
		any = true
		var chip := hbox(3, row)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var icon := IconView.new(res, icon_px)
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		chip.add_child(icon)
		var amount := Strike.new()
		amount.text = str(n)
		amount.struck = struck
		amount.add_theme_font_override("font", UiFonts.mono(700, 0))
		amount.add_theme_font_size_override("font_size", 13)
		var short := not have.is_empty() and int(have.get(res, 0)) < n and not struck
		var col := AgentTheme.c(look, "bad") if short else AgentTheme.c(look, "text")
		if struck:
			col = AgentTheme.c(look, "faint")
		amount.add_theme_color_override("font_color", col)
		amount.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		chip.add_child(amount)
	if not any:
		var none := label("nothing", "MonoSmall", row)
		none.vertical_alignment = VERTICAL_ALIGNMENT_CENTER


## A banner: a glyph, an optional title in `color` and wrapping text, on a tinted panel with a
## thick left edge. The text label is named "Text" (callout_text() finds it).
static func callout(look: int, color: Color, text: String, title: String = "", glyph: String = "", parent: Node = null) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", AgentTheme.callout_box(look, color))
	var row := hbox(12, p)
	if glyph != "":
		var g := Glyph.new(glyph, color, 18)
		g.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(g)
	var col := vbox(2, row)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if title != "":
		var t := label(title.to_upper(), "Section", col)
		t.name = "Title"
		t.add_theme_color_override("font_color", color if look != AgentTheme.DOCUMENT else color.darkened(0.1))
	var body := para(text, "Body", col)
	body.name = "Text"
	if parent != null:
		parent.add_child(p)
	return p


static func callout_text(p: Control) -> Label:
	return p.find_child("Text", true, false) as Label


static func callout_title(p: Control) -> Label:
	return p.find_child("Title", true, false) as Label


## "120 Food, 60 Gold" (the format CraftedTooltip turns into icons after "Cost: ").
static func cost_text(cost: Dictionary) -> String:
	var parts: PackedStringArray = []
	for res in Economy.data.resource_names():
		if int(cost.get(res, 0)) > 0:
			parts.append("%d %s" % [int(cost[res]), res.capitalize()])
	return ", ".join(parts)


## Sum of several costs.
static func add_costs(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate()
	for k: Variant in b.keys():
		out[String(k)] = int(out.get(String(k), 0)) + int(b[k])
	return out


## A button whose tooltip is the rich parchment kind (first line as a title).
class TipButton:
	extends Button

	func _make_custom_tooltip(for_text: String) -> Object:
		return CraftedTooltip.make(for_text) if for_text != "" else null


## A thin horizontal rule that fades out to the right.
class Rule:
	extends Control
	var color: Color = Color(1, 1, 1, 0.2)

	func _init() -> void:
		custom_minimum_size = Vector2(12, 3)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var y := floorf(size.y * 0.5) + 0.5
		var pts := PackedVector2Array([Vector2(0, y - 0.5), Vector2(size.x, y - 0.5), Vector2(size.x, y + 0.5), Vector2(0, y + 0.5)])
		draw_polygon(pts, PackedColorArray([color, Color(color, 0.0), Color(color, 0.0), color]))


## A label that can be struck through.
class Strike:
	extends Label
	var struck: bool = false:
		set(value):
			struck = value
			queue_redraw()

	func _draw() -> void:
		if struck:
			var y := size.y * 0.54
			draw_line(Vector2(-1, y), Vector2(size.x + 1, y), get_theme_color("font_color"), 1.5, true)
