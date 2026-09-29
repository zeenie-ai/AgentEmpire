# Town Hall protocol, version 1.2

This is the contract between the Town Hall (the local service in `townhall/`) and the Godot client (`client/`). The Town Hall's zod schemas in `townhall/src/protocol/` must match this document. If the two ever disagree, fix the code or update this document in the same change.

**Changes in 1.2** (all backward compatible; a 1.1 client keeps working):
- A third provider, `pi`, runs agents on any other model provider through the pi coding agent. It appears in `Agent.provider`, `check_providers`, `list_models`, `Mana.by_provider` and `set_budget` billing.
- A pi agent's `model` is `"<pi provider>/<model id>"`, for example `"openrouter/deepseek/deepseek-chat"`. `create_agent` and `update_agent` refuse other forms with `BAD_REQUEST`.
- `set_budget` accepts an optional `billing.pi`.
- `hello_result.sdk_versions` now lists the installed harness versions, and `features` names the provider mode.

## Connection

- The endpoint is `ws://127.0.0.1:<port>/ws`, and the server listens on 127.0.0.1 only. The port and token are written to `runtime.json` in the Town Hall data folder, as `{pid, port, token, url, data_dir}`.
- The desktop client finds a running Town Hall through a copy of that file in the per-user config folder: `<config dir>/Aurelhaven/runtime.json`, where the config dir is `%APPDATA%` on Windows, `~/Library/Application Support` on macOS and `$XDG_CONFIG_HOME` or `~/.config` elsewhere (Godot's `OS.get_config_dir()`). `AURELHAVEN_DISCOVERY_FILE` moves it (`off` disables it). The client also honours `AURELHAVEN_RUNTIME`, a path to any runtime file. The web client gets the token in the page's `#t=` fragment instead.
- The server rejects the upgrade unless:
  - the `Host` header is `127.0.0.1:<port>` or `localhost:<port>`;
  - the `Origin` header is absent (the desktop client), the Town Hall's own origin, or a configured development origin. A `null` Origin is rejected.
- The first frame must be `hello`, and it must arrive within 5 s.
- Close codes:

  | Code | Meaning |
  |---|---|
  | 4001 | Bad token |
  | 4002 | No hello within 5 s |
  | 4400 | Protocol major version mismatch |
  | 4409 | Replaced by another client |

- Frames are UTF-8 JSON, at most 1 MiB each.
- JSON numbers reach Godot as floats. Every ID is therefore a **string**, and every amount is an integer, which the client converts with `int()`.

## Envelopes

**Command (client to server):**
```json
{"v":1,"type":"assign_task","request_id":"c-7f3a-42","payload":{}}
```

**Reply.** It goes only to the connection that sent the command:
```json
{"v":1,"type":"assign_task_result","request_id":"c-7f3a-42","ok":true,"payload":{}}
{"v":1,"type":"assign_task_result","request_id":"c-7f3a-42","ok":false,"error":{"code":"INSUFFICIENT_MANA","message":"...","retryable":false}}
```

**Event.** Broadcast to every authenticated connection:
```json
{"v":1,"type":"task_updated","seq":1842,"id":"evt_01J...","time":"2026-09-28T10:00:00.000Z","subject":"task/tsk_01J...","causation_id":"c-7f3a-42","payload":{}}
```

**`request_id`**
- The client makes it up. It must be unique per connection and at most 128 characters.
- For commands that change state, it doubles as an idempotency key for 10 minutes: resending the same `request_id` returns the original reply without doing the work twice.
- Only successful replies are remembered, so a failed command can be retried with the same `request_id`.
- Reusing a `request_id` with a different payload returns `CONFLICT`.
- The cache lives in memory and resets when the Town Hall restarts. Ledger operations are also protected by their `op_id`, which is stored in the database and survives restarts.

**`seq`**
- A global counter that only goes up. The client stores the last `seq` it saw.
- A gap means an event was missed; the client should call `get_state`.

**Error codes:** `AUTH_FAILED`, `BAD_REQUEST`, `NOT_FOUND`, `INSUFFICIENT_RESOURCES`, `INSUFFICIENT_MANA`, `AGE_REQUIRED`, `RANK_REQUIRED`, `LIMIT_REACHED`, `INVALID_STATE`, `CONFLICT`, `PROVIDER_UNAVAILABLE`, `WORKSPACE_DENIED`, `SESSION_BUSY`, `INTERNAL`.

## Shared objects

**Units:**
- Money is integer **micro-USD**, in fields named `*_micros`. 1 Mana = 10,000 micros.
- Resources are `{"food":int,"wood":int,"stone":int,"gold":int}`.
- Tiles are `{"x":int,"y":int}`.
- Times are ISO-8601 strings.
- Durations are `*_ms` integers.

```jsonc
// Agent
{
  "id": "agt_...", "name": "Mira", "provider": "claude|codex|pi", "model": "claude-opus-5-5",   // pi: added in 1.2, model "<pi provider>/<model id>"
  "role": "artificer|scholar|scribe|warden|herald", "instructions": "...",
  "approval_mode": "ask_every_time|trusted_edits|plan_first|free_hand",
  "workspace": { "path": "D:/work/app", "mode": "git_worktree|plain_folder", "repo_root": "D:/work/app" },
  "seals": { "S": 40, "M": 150, "L": 450, "XL": 1200 },   // Mana per task size
  "billing": "api_key|subscription",
  "lifecycle": "training|settling|active|retired",           // settling = walking out / building home or tools
  "activity": "idle|working|awaiting_approval|blocked",     // meaningful when lifecycle = active
  "blocked_reason": null,   // "missing_tools"|"no_mana"|"provider_offline"|"workspace_error"|null
  "home": { "tile": {"x":40,"y":52}, "built": false },      // null until placed
  "tool_ids": ["tl_..."], "starting_tools": ["lectern", "quillworks"],   // starting_tools: added in 1.1
  "current_task_id": null, "queue": ["tsk_..."],
  "xp": 0, "level": 1, "rank": "F",
  "stats": { "accepted": 0, "accepted_first_try": 0, "sent_back": 0, "failed": 0, "rites_passed": 0,
             "party_tasks": 0, "mana_spent_micros": 0 },
  "party_id": null, "version": 3, "created_at": "..."
}

// ToolAddon
{ "id": "tl_...", "agent_id": "agt_...", "type": "lectern|quillworks|forge|rookery|archive|waygate",
  "status": "building|active|error|removed", "tile": {"x":42,"y":50},
  "config_summary": null,   // waygate: {"server_name":"github","transport":"stdio|http","allowed_tools":["..."]}
  "health": null }          // waygate: {"ok":true,"tools":["..."],"checked_at":"..."}

// Task
{
  "id": "tsk_...", "agent_id": "agt_...", "party_id": null, "parent_task_id": null,
  "title": "...", "prompt": "...", "size": "S|M|L|XL", "acceptance": ["..."], "rite": "npm test",
  "state": "in_transit|queued|preparing|running|awaiting_approval|awaiting_review|accepting|accepted|rejected|paused|failed|cancelled",
  "state_reason": null,     // paused: "budget"|"restart"|"stalled"|"mana_depleted"|"provider_limit"; failed: a protocol error code
                            // Terminal states: accepted, rejected, cancelled. "failed" is not terminal:
                            // resume_task retries it and cancel_task dismisses it.
  "attempt": 1, "seal_micros": 1500000, "reserved_micros": 0, "spent_micros": 0, "spent_is_estimate": true,
  "courier": { "mode": "human|wisp|express", "human_id": "h12" },
  "created_at": "...", "started_at": null, "finished_at": null,
  "result": null,           // {"summary":"...","diff_stat":{"files":3,"added":40,"removed":5},"rite":{"passed":true,"output_tail":"..."},"deliverable":true}
  "rewards": null,          // {"rp":351,"xp":351,"resources":{...},"breakdown":{"base":180,"q":0.5,"e":0.15,"p":0.3,"d":1.0,"ceiling":1200,"zero_reason":null}}
                            // zero_reason (set when rp is 0): "duplicate"|"no_deliverable"|"too_short"|"party_subtask"
  "version": 5
}

// Approval
{ "id": "apv_...", "task_id": "tsk_...", "agent_id": "agt_...", "tool": "Bash",
  "category": "read|write|command|network|outside_workspace|mcp",
  "risk": "low|medium|high", "summary": "Run: npm install", "input_preview": "{...}",  // redacted, <= 4 KB
  "reason": "The agent's stated reason, if any", "status": "pending|orphaned",
  "scopes": ["once","task","agent"], "seal_exhausted": false, "created_at": "..." }

// Incident
{ "id": "inc_...", "kind": "smoke|alarm_bell|hand_bell|dim_lanterns|font_dark|rift|merge_blocked",
  "severity": "info|warn|urgent", "subject": { "agent_id": "agt_...", "task_id": "tsk_..." },
  "message": "...", "opened_at": "..." }

// Mana
{ "period": "day|week|month", "period_start": "...", "period_end": "...",
  "cap_micros": 5000000, "spent_micros": 0, "reserved_micros": 0, "remaining_micros": 5000000,
  "level": "normal|dim|warning|depleted",
  "by_provider": { "claude": 0, "codex": 0, "pi": 0 }, "estimates": true,   // pi: added in 1.2
  "provider_windows": [ { "provider": "codex", "used_percent": 12.5, "resets_at": "..." } ] }

// Party
{ "id": "pty_...", "lead_agent_id": "agt_...", "member_ids": ["agt_..."], "created_at": "..." }

// Age
{ "current": 1, "research": null }   // research: {"target":2,"started_at":"...","duration_ms":90000}
```

## Commands

The table shows each command's payload and the payload of its successful reply.

| Command | Payload | Result |
|---|---|---|
| `hello` | `{token, protocol:{major:1,minor:0}, client:{name,version,platform:"desktop"\|"web"}, last_seq?, take_over?}` | `{protocol, daemon_version, sdk_versions, features, seq, catchup:"replay"\|"snapshot"}`. When another client is active and `take_over` is not set, the reply is `SESSION_BUSY`. With `take_over`, the old client gets `session_revoked` and is closed with 4409. With `catchup:"replay"`, the missed events follow immediately. With `catchup:"snapshot"`, the client calls `get_state`. `sdk_versions` maps each installed harness to its version, for example `{"claude":"2.1.281","codex":"0.144.2","pi":"0.87.1"}` (1.2). `features` contains `fake_provider` when agents are scripted and `real_providers` otherwise (1.2). |
| `ping` | `{}` | `{}` |
| `get_state` | `{}` | `{seq, age, treasury, mana, agents, tools, tasks, approvals, parties, incidents, town:{rev,schema_version}\|null, settings, providers}` (`tasks` = open tasks plus the 50 most recent) |
| `check_providers` | `{}` | `{providers:[{id, installed, version?, logged_in, billing_hint:"api_key"\|"subscription"\|"unknown", message?}]}`. One entry per provider: `claude`, `codex` and `pi` (1.2). |
| `list_models` | `{provider}` | `{models:[{id,label,default,cost_hint?}]}`. pi model ids are `"<pi provider>/<model id>"` and list only models whose provider has credentials. |
| `browse_folder` | `{path?}` | `{path, parent, entries:[{name,path,is_git_repo}], roots}` (directories only, inside allowed roots) |
| `create_agent` | `{spec:{name, provider, model, role, instructions, approval_mode, workspace:{path}, seals?, billing?, starting_tools:[type]}}` | `{agent_id, cost, free:bool, training:{duration_ms}}`. Charges the agent's cost, or nothing under Font's Grace, and checks the age and agent limits. |
| `agent_trained` | `{agent_id}` | `{}`. The client's training timer finished and the unit has left the Keep. |
| `place_home` | `{agent_id, tile}` | `{cost}`. Charges the home's cost. |
| `home_built` | `{agent_id}` | `{}`. Construction finished in the simulation; the Town Hall finishes setting up the workspace. |
| `update_agent` | `{agent_id, patch:{name?,model?,instructions?,approval_mode?,seals?}, expected_version}` | `{agent}` |
| `retire_agent` | `{agent_id, when:"now"\|"after_current"}` | `{}` |
| `attach_tool` | `{agent_id, type, tile, config?}` | `{tool_id, cost}`. For a Waygate, `config` is `{server_name, transport:"stdio"\|"http", command?, args?, env_refs?, url?, header_refs?, allowed_tools?}`, where `env_refs` and `header_refs` name environment variables and never hold secrets. `header_refs` maps an HTTP header name to the environment variable that holds its value. |
| `tool_built` | `{tool_id}` | `{}` |
| `detach_tool` | `{tool_id}` | `{refund}` (the dismantle refund) |
| `assign_task` | `{agent_id? \| party_id?, title, prompt, size, acceptance?, rite?, seal_mana?, courier:{mode:"human"\|"wisp"\|"express", human_id?}}` | `{task_id}`. The task starts in `in_transit`, unless the courier mode is `express`, in which case it starts `queued`. |
| `task_delivered` | `{task_id}` | `{}`. The courier arrived. The server delivers automatically after `couriers.force_deliver_after_s`. |
| `cancel_task` | `{task_id}` | `{}` |
| `resume_task` | `{task_id, extend_seal_mana?}` | `{}`. Also retries a failed task. |
| `stop_and_review` | `{task_id}` | `{}`. Ends a task paused on its seal and moves the work done so far to `awaiting_review`. |
| `nudge_task` | `{task_id, message}` | `{}`. Sends extra text to a running agent. |
| `respond_approval` | `{approval_id, decision:"allow"\|"deny", scope:"once"\|"task"\|"agent", message?, updated_input?}` | `{}`. The first reply wins. |
| `get_task_detail` | `{task_id, include:["activity","diff"]}` | `{task, activity:[Activity], diff?:{files:[{path,status,added,removed}], patch?}}` (`patch` capped at 512 KB) |
| `accept_result` | `{task_id, integrate:"merge"\|"keep_branch"\|"export"}` | `{rewards, merge?:{commit?, blocked_reason?}}`. If the merge or export is blocked (for example, the main checkout is dirty or has a conflict), `rewards` is `null`, `merge.blocked_reason` explains why, the task stays `accepting`, and a `merge_blocked` incident opens. The player fixes the cause and accepts again, or accepts with `keep_branch`. |
| `send_back` | `{task_id, feedback}` | `{}` |
| `abandon_task` | `{task_id}` | `{}`. No reward; the workspace is kept until it is discarded. |
| `discard_workspace` | `{task_id, confirm:true}` | `{}` |
| `form_party` | `{lead_agent_id, member_ids}` | `{party_id}` |
| `disband_party` | `{party_id}` | `{}` |
| `set_budget` | `{period, refill_hour_local?, pool_usd, billing:{claude,codex,pi?}, confirm_raise?}` | `{mana}`. Raising the pool in the middle of a period requires `confirm_raise:true`. `billing.pi` was added in 1.2; when it is left out, the current pi billing is kept. |
| `spend_resources` | `{op_id, reason, cost, ref?}` | `{treasury}`. For simulation purchases such as a townsperson, Cottage, Farm, Storehouse or Quartermaster trade. The server checks the balance, and `op_id` makes retries safe. |
| `refund_resources` | `{op_id, spend_op_id, fraction}` | `{treasury}`. At most one refund per spend, and never more than the spend. |
| `report_gather` | `{op_id, deposits:{food?,wood?}, storehouses}` | `{treasury}`. Batched. Food and Wood are capped at `storage.cap_by_age[age] + storehouses × storage.storehouse_bonus`. `storehouses` is the number of completed Storehouses, as counted by the client. Rewards may push a resource past the cap; gathering may not. |
| `trade` | `{op_id, give:{resource,amount}, get:resource}` | `{treasury, rate}` (Quartermaster). `rate` is the town's price multiplier after this trade. Trades ignore storage caps. |
| `advance_age` | `{}` | `{research:{target,started_at,duration_ms}}` |
| `save_town` | `{base_rev, schema_version, snapshot}` | `{rev}`, or `CONFLICT` if `base_rev` is stale |
| `load_town` | `{}` | `{rev, schema_version, snapshot}` or `null` |
| `set_setting` | `{key, value}` | `{settings}`. Keys: `work_while_away`, `express_dispatch`, `lantern_hours:{start,end}` (whole local hours, 0–23). |
| `get_ledger` | `{limit?}` | `{entries, treasury}` |

## Events

| Event | Payload |
|---|---|
| `agent_updated` | `{agent}`. The full object; the client replaces its copy by `id`. Sent on create too. |
| `agent_retired` | `{agent_id}` |
| `tool_updated` | `{tool}` |
| `task_updated` | `{task}`. The full object, sent on every state change. |
| `task_progress` | `{task_id, phase, current_tool?, files_touched, spent_micros}`, at most 2 per second per task |
| `task_activity` | `{task_id, entry:{time, kind:"message"\|"tool_start"\|"tool_end"\|"error"\|"system", text}}`, rate-limited, with text capped at 2 KB |
| `approval_requested` | `{approval}` |
| `approval_resolved` | `{approval_id, decision, scope, by:"player"\|"rule"\|"pre_approval"\|"restart"\|"cancelled"}` |
| `mana_updated` | `{mana}` |
| `treasury_updated` | `{treasury, reason, delta}` |
| `incident_opened` | `{incident}` |
| `incident_resolved` | `{incident_id}` |
| `party_updated` | `{party}` |
| `party_disbanded` | `{party_id}` |
| `subtask_delegated` | `{parent_task_id, task_id, from_agent_id, to_agent_id}` |
| `age_updated` | `{age}`. Covers both research starting and the age advancing. |
| `providers_updated` | `{providers}` |
| `town_saved` | `{rev}` |
| `session_revoked` | `{}`. Transient: not logged, so it does not advance `seq` and is never replayed. |
| `daemon_shutdown` | `{}`. Transient: not logged, so it does not advance `seq` and is never replayed. |

## Rules both sides rely on

1. **Controls never cost anything.** Approving, stopping, resuming, nudging, reviewing, accepting, sending back and abandoning never cost resources and work even at 0 Mana.
2. **Rewards come only from the server.** They are paid by the Town Hall on `accept_result` and announced through `task_updated` (with `rewards` filled in) and `treasury_updated`. The client never creates resources, except by reporting gathering.
3. **Mana is never exchanged.** No command turns game resources into Mana or Mana into game resources.
4. **Tasks wait only for their courier.** `in_transit` becomes `queued` when the client sends `task_delivered` or when the timeout expires. Approvals and results never wait for a courier.
5. **Main checkouts are protected.** The Town Hall never changes the user's main checkout except through `accept_result` with `integrate:"merge"`, and only when that checkout is clean.
