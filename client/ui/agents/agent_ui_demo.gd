class_name AgentUiDemo
extends RefCounted
## A realistic Town Hall state for previewing and testing the agent UI (tools/ui_preview.gd,
## tests/unit/test_agent_ui.gd), shaped exactly like get_state: two agents (Mira at work on a
## task, Corvin with a result awaiting review), their add-ons, two pending approvals, a task with
## a diff, Mana and two ready harnesses. Times are relative to now, so ages read naturally.

const MICROS := 10000


## ISO-8601 time `seconds_ago` seconds before now (negative: in the future).
static func iso(seconds_ago: float) -> String:
	var t := int(Time.get_unix_time_from_system() - seconds_ago)
	return Time.get_datetime_string_from_unix_time(t) + ".000Z"


static func state() -> Dictionary:
	return {
		"seq": 1842,
		"age": {"current": 1, "research": null},
		"treasury": {"food": 460, "wood": 385, "stone": 240, "gold": 175},
		"mana": mana(),
		"agents": [mira(), corvin()],
		"tools": tools(),
		"tasks": [task_login(), task_tests(), task_docs()],
		"approvals": approvals(),
		"parties": [],
		"incidents": [],
		"town": null,
		"settings": {"work_while_away": false, "express_dispatch": false, "lantern_hours": {"start": 22, "end": 7}},
		"providers": providers(),
	}


static func providers() -> Array:
	return [
		{"id": "claude", "installed": true, "version": "2.1.4", "logged_in": true, "billing_hint": "subscription"},
		{"id": "codex", "installed": true, "version": "0.46.0", "logged_in": true, "billing_hint": "api_key"},
	]


static func mana() -> Dictionary:
	return {
		"period": "day", "period_start": iso(9.0 * 3600.0), "period_end": iso(-15.0 * 3600.0 + 1260.0),
		"cap_micros": 500 * MICROS, "spent_micros": 186 * MICROS + 2000, "reserved_micros": 150 * MICROS,
		"remaining_micros": 164 * MICROS - 2000, "level": "normal",
		"by_provider": {"claude": 126 * MICROS + 2000, "codex": 60 * MICROS}, "estimates": true,
		"provider_windows": [
			{"provider": "claude", "used_percent": 41.5, "resets_at": iso(-2.0 * 3600.0 - 840.0)},
			{"provider": "codex", "used_percent": 12.5, "resets_at": iso(-4.0 * 86400.0)},
		],
	}


static func _stats(accepted: int, first_try: int, rites: int, spent_mana: int) -> Dictionary:
	return {"accepted": accepted, "accepted_first_try": first_try, "sent_back": 1, "failed": 0,
		"rites_passed": rites, "party_tasks": 0, "mana_spent_micros": spent_mana * MICROS}


static func mira() -> Dictionary:
	return {
		"id": "agt_mira", "name": "Mira", "provider": "claude", "model": "claude-opus-5-5", "role": "artificer",
		"instructions": AgentUi.oath_for("artificer", "Mira"), "approval_mode": "trusted_edits",
		"workspace": {"path": "D:/work/aurelhaven-web", "mode": "git_worktree", "repo_root": "D:/work/aurelhaven-web"},
		"seals": {"S": 40, "M": 150, "L": 450, "XL": 1200}, "billing": "subscription",
		"lifecycle": "active", "activity": "working", "blocked_reason": null,
		"home": {"tile": {"x": 40, "y": 52}, "built": true},
		"tool_ids": ["tl_lectern", "tl_quill", "tl_forge"], "starting_tools": ["lectern", "quillworks", "forge"],
		"current_task_id": "tsk_login", "queue": ["tsk_tests"],
		"xp": 420, "level": 3, "rank": "E", "stats": _stats(5, 3, 2, 640),
		"party_id": null, "version": 7, "created_at": iso(2.0 * 86400.0),
	}


static func corvin() -> Dictionary:
	return {
		"id": "agt_corvin", "name": "Corvin", "provider": "codex", "model": "gpt-5.3-codex", "role": "scribe",
		"instructions": AgentUi.oath_for("scribe", "Corvin"), "approval_mode": "ask_every_time",
		"workspace": {"path": "D:/work/aurelhaven-web", "mode": "git_worktree", "repo_root": "D:/work/aurelhaven-web"},
		"seals": {"S": 40, "M": 150, "L": 450, "XL": 1200}, "billing": "api_key",
		"lifecycle": "active", "activity": "idle", "blocked_reason": null,
		"home": {"tile": {"x": 58, "y": 47}, "built": true},
		"tool_ids": ["tl_c_lectern", "tl_c_quill"], "starting_tools": ["lectern", "quillworks"],
		"current_task_id": null, "queue": [],
		"xp": 160, "level": 2, "rank": "E", "stats": _stats(2, 1, 1, 310),
		"party_id": null, "version": 4, "created_at": iso(1.5 * 86400.0),
	}


static func tools() -> Array:
	return [
		{"id": "tl_lectern", "agent_id": "agt_mira", "type": "lectern", "status": "active", "tile": {"x": 38, "y": 50}, "config_summary": null, "health": null},
		{"id": "tl_quill", "agent_id": "agt_mira", "type": "quillworks", "status": "active", "tile": {"x": 44, "y": 50}, "config_summary": null, "health": null},
		{"id": "tl_forge", "agent_id": "agt_mira", "type": "forge", "status": "building", "tile": {"x": 38, "y": 56}, "config_summary": null, "health": null},
		{"id": "tl_c_lectern", "agent_id": "agt_corvin", "type": "lectern", "status": "active", "tile": {"x": 56, "y": 45}, "config_summary": null, "health": null},
		{"id": "tl_c_quill", "agent_id": "agt_corvin", "type": "quillworks", "status": "active", "tile": {"x": 62, "y": 45}, "config_summary": null, "health": null},
	]


static func task_login() -> Dictionary:
	return {
		"id": "tsk_login", "agent_id": "agt_mira", "party_id": null, "parent_task_id": null,
		"title": "Fix the login redirect loop",
		"prompt": "After a session expires, signing in again bounces between /login and /dashboard. Find the cause and fix it.",
		"size": "M", "acceptance": ["Signing in lands on the dashboard", "No loop when the session expires"], "rite": "npm test",
		"state": "running", "state_reason": null, "attempt": 1,
		"seal_micros": 150 * MICROS, "reserved_micros": 150 * MICROS, "spent_micros": 62 * MICROS, "spent_is_estimate": true,
		"courier": {"mode": "human", "human_id": "u12"},
		"created_at": iso(900.0), "started_at": iso(780.0), "finished_at": null,
		"result": null, "rewards": null, "version": 6,
	}


static func task_tests() -> Dictionary:
	return {
		"id": "tsk_tests", "agent_id": "agt_mira", "party_id": null, "parent_task_id": null,
		"title": "Add tests for the session refresh", "prompt": "Cover the refresh path with tests.",
		"size": "S", "acceptance": [], "rite": "npm test",
		"state": "queued", "state_reason": null, "attempt": 1,
		"seal_micros": 40 * MICROS, "reserved_micros": 0, "spent_micros": 0, "spent_is_estimate": true,
		"courier": {"mode": "wisp", "human_id": null},
		"created_at": iso(300.0), "started_at": null, "finished_at": null,
		"result": null, "rewards": null, "version": 2,
	}


static func task_docs() -> Dictionary:
	return {
		"id": "tsk_docs", "agent_id": "agt_corvin", "party_id": null, "parent_task_id": null,
		"title": "Document the town save format",
		"prompt": "Write a page that explains what a town save holds, field by field, and how saves are versioned.",
		"size": "L", "acceptance": ["Every top-level field is described", "Versioning and migration are explained"],
		"rite": "npm run docs:check",
		"state": "awaiting_review", "state_reason": null, "attempt": 2,
		"seal_micros": 450 * MICROS, "reserved_micros": 0, "spent_micros": 286 * MICROS, "spent_is_estimate": false,
		"courier": {"mode": "human", "human_id": "u7"},
		"created_at": iso(3600.0), "started_at": iso(3300.0), "finished_at": iso(95.0),
		"result": {
			"summary": "Added docs/save-format.md, which walks through a town save field by field: the simulation snapshot, the ledger and the client block. It also explains schema versions and how older saves are migrated. The serializer now names its sections with constants, so the page and the code use the same words, and the README links the new page.",
			"diff_stat": {"files": 3, "added": 142, "removed": 18},
			"rite": {"passed": true, "output_tail": "> aurelhaven-web@0.3.0 docs:check\n> markdownlint docs && lychee docs\n\nChecked 14 files, 0 problems.\n[lychee] 38 links checked, 0 errors.\nDone in 6.2s."},
			"deliverable": true,
		},
		"rewards": null, "version": 9,
	}


static func approvals() -> Array:
	return [
		{"id": "apv_npm", "task_id": "tsk_login", "agent_id": "agt_mira", "tool": "Bash", "category": "command", "risk": "medium",
			"summary": "Run: npm install --save-dev vitest",
			"input_preview": "{\n  \"command\": \"npm install --save-dev vitest\",\n  \"cwd\": \"D:/work/aurelhaven-web\",\n  \"timeout_ms\": 120000\n}",
			"reason": "The session tests need a test runner; the project has none yet.", "status": "pending",
			"scopes": ["once", "task", "agent"], "seal_exhausted": false, "created_at": iso(42.0)},
		{"id": "apv_fetch", "task_id": "tsk_login", "agent_id": "agt_mira", "tool": "WebFetch", "category": "network", "risk": "low",
			"summary": "Fetch developer.mozilla.org: HTTP 302 Found",
			"input_preview": "{\n  \"url\": \"https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/302\",\n  \"prompt\": \"How do browsers treat repeated 302 redirects?\"\n}",
			"reason": null, "status": "pending",
			"scopes": ["once", "task", "agent"], "seal_exhausted": true, "created_at": iso(185.0)},
	]


## A get_task_detail reply for the task awaiting review, with its activity and diff.
static func task_detail(task_id: String = "tsk_docs") -> Dictionary:
	var t := task_docs() if task_id == "tsk_docs" else task_login()
	return {"task": t, "activity": activity(), "diff": {"files": diff_files(), "patch": patch()}}


static func activity() -> Array:
	return [
		{"time": iso(3290.0), "kind": "system", "text": "Tobin delivered the scroll. Attempt 2 begins."},
		{"time": iso(3280.0), "kind": "message", "text": "I'll read the serializer first to see exactly what goes into a save."},
		{"time": iso(3275.0), "kind": "tool_start", "text": "Read client/sim/save/sim_serializer.gd"},
		{"time": iso(3274.0), "kind": "tool_end", "text": "Read 212 lines"},
		{"time": iso(3100.0), "kind": "message", "text": "The save has three blocks: sim, ledger and client. The sections are named by string literals in two places; I'll give them constants."},
		{"time": iso(2900.0), "kind": "tool_start", "text": "Edit client/sim/save/sim_serializer.gd"},
		{"time": iso(2899.0), "kind": "tool_end", "text": "Edited 16 lines"},
		{"time": iso(1500.0), "kind": "tool_start", "text": "Write docs/save-format.md"},
		{"time": iso(1498.0), "kind": "tool_end", "text": "Wrote 118 lines"},
		{"time": iso(400.0), "kind": "error", "text": "lychee: 1 broken link: docs/save-format.md -> ../protocol/PROTOCOL.md#town"},
		{"time": iso(380.0), "kind": "message", "text": "Fixed the anchor; the protocol heading is 'Shared objects'."},
		{"time": iso(120.0), "kind": "system", "text": "Rite passed: npm run docs:check (6.2 s)."},
		{"time": iso(96.0), "kind": "message", "text": "Done. The page is at docs/save-format.md and the README links to it."},
	]


static func diff_files() -> Array:
	return [
		{"path": "docs/save-format.md", "status": "added", "added": 118, "removed": 0},
		{"path": "client/sim/save/sim_serializer.gd", "status": "modified", "added": 16, "removed": 12},
		{"path": "README.md", "status": "modified", "added": 8, "removed": 6},
	]


static func patch() -> String:
	var lines := PackedStringArray([
		"diff --git a/README.md b/README.md",
		"index 3f1c2aa..8d04e71 100644",
		"--- a/README.md",
		"+++ b/README.md",
		"@@ -12,12 +12,14 @@ AgentEmpire is a town-builder where the villagers are real AI agents.",
		" ## Documentation",
		" ",
		"-- `protocol/PROTOCOL.md`: the Town Hall protocol.",
		"-- `docs/spikes.md`: notes from the early spikes.",
		"+- [The Town Hall protocol](protocol/PROTOCOL.md)",
		"+- [The town save format](docs/save-format.md): what a save holds and how it is versioned",
		"+- [Spike notes](docs/spikes.md)",
		" ",
		" ## Building",
		"diff --git a/client/sim/save/sim_serializer.gd b/client/sim/save/sim_serializer.gd",
		"index 51a9e0c..c2f7d19 100644",
		"--- a/client/sim/save/sim_serializer.gd",
		"+++ b/client/sim/save/sim_serializer.gd",
		"@@ -1,9 +1,16 @@",
		" class_name SimSerializer",
		" extends RefCounted",
		"-## Turns a SimWorld into a dictionary and back.",
		"+## Turns a SimWorld into a dictionary and back. The format is documented in",
		"+## docs/save-format.md; keep the two in step.",
		"+",
		"+const SECTION_UNITS := \"units\"",
		"+const SECTION_BUILDINGS := \"buildings\"",
		"+const SECTION_NODES := \"nodes\"",
		" ",
		" static func to_dict(w: SimWorld) -> Dictionary:",
		"-\tvar out := {\"units\": [], \"buildings\": [], \"nodes\": []}",
		"+\tvar out := {SECTION_UNITS: [], SECTION_BUILDINGS: [], SECTION_NODES: []}",
		" \tfor u: SimUnit in w.units.values():",
		"-\t\tout[\"units\"].append(u.to_dict())",
		"+\t\tout[SECTION_UNITS].append(u.to_dict())",
		"@@ -48,7 +55,7 @@ static func from_dict(d: Dictionary, econ: EconomyData, ledger: Ledger) -> SimWorld:",
		" \tvar w := SimWorld.create_empty(econ, ledger)",
		"-\tfor u: Dictionary in d.get(\"units\", []):",
		"+\tfor u: Dictionary in d.get(SECTION_UNITS, []):",
		" \t\tw.add_unit_from_dict(u)",
		"diff --git a/docs/save-format.md b/docs/save-format.md",
		"new file mode 100644",
		"index 0000000..a41b2c9",
		"--- /dev/null",
		"+++ b/docs/save-format.md",
		"@@ -0,0 +1,118 @@",
		"+# The town save format",
		"+",
		"+A town save is one JSON document, gzipped and base64-encoded when it travels to the",
		"+Town Hall (`save_town`). The Town Hall never reads it; only the client does.",
		"+",
		"+## Top level",
		"+",
		"+| Field | What it holds |",
		"+|---|---|",
		"+| `sim` | The simulation snapshot: units, buildings, resource nodes and the tick. |",
		"+| `ledger` | The client's ledger mirror, so pending spends survive a reload. |",
		"+| `client` | The game version that wrote the save. |",
		"+",
		"+## Versions",
		"+",
		"+Every save carries `schema_version`. A client refuses saves from a newer schema and",
		"+migrates older ones step by step, one version at a time.",
	])
	return "\n".join(lines)


## A list_models reply for a harness.
static func models(harness: String) -> Array:
	match harness:
		"claude":
			return [
				{"id": "claude-opus-5-5", "label": "Claude Opus 5.5", "default": true, "cost_hint": "$5 / $25 per million tokens"},
				{"id": "claude-sonnet-5", "label": "Claude Sonnet 5", "default": false, "cost_hint": "$3 / $15 per million tokens"},
				{"id": "claude-haiku-4-5", "label": "Claude Haiku 4.5", "default": false, "cost_hint": "$1 / $5 per million tokens"},
			]
		"codex":
			return [
				{"id": "gpt-5.3-codex", "label": "GPT-5.3 Codex", "default": true, "cost_hint": "$1.25 / $10 per million tokens"},
				{"id": "gpt-5.3-codex-mini", "label": "GPT-5.3 Codex Mini", "default": false, "cost_hint": "$0.25 / $2 per million tokens"},
			]
		"pi":
			return [
				{"id": "anthropic/claude-sonnet-5", "label": "anthropic/claude-sonnet-5", "default": true},
				{"id": "openai/gpt-5.3", "label": "openai/gpt-5.3", "default": false},
			]
	return []


## A browse_folder reply for `path` ("" lists the roots).
static func browse(path: String) -> Dictionary:
	if path == "":
		return {"path": null, "parent": null, "roots": ["C:/Users/Tobin", "D:/"],
			"entries": [{"name": "C:/Users/Tobin", "path": "C:/Users/Tobin", "is_git_repo": false},
				{"name": "D:/", "path": "D:/", "is_git_repo": false}]}
	var entries: Array = []
	if path == "D:/work":
		for e: Array in [["aurelhaven-web", true], ["docs-site", true], ["notes", false], ["sandbox", false],
				["scratch-2026", false], ["town-hall", true], ["tools", false]]:
			entries.append({"name": String(e[0]), "path": "D:/work/" + String(e[0]), "is_git_repo": bool(e[1])})
		return {"path": "D:/work", "parent": "D:/", "entries": entries, "roots": ["C:/Users/Tobin", "D:/"]}
	for n in ["src", "docs", "tests"]:
		entries.append({"name": n, "path": path.path_join(n), "is_git_repo": false})
	return {"path": path, "parent": path.get_base_dir(), "entries": entries, "roots": ["C:/Users/Tobin", "D:/"]}
