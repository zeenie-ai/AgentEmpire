# Architecture

Aurelhaven has two programs that talk over a local WebSocket:

- the **Town Hall** (`townhall/`), a TypeScript service on Node 22, which owns everything real;
- the **client** (`client/`), a Godot 4.7.2 game in GDScript, which owns the simulated town.

```
Godot client (desktop or web)                         Town Hall (Node 22, 127.0.0.1 only)
  Game (boot, clock, saves)                             server: HTTP (web build), WebSocket,
  SimWorld: map, units, jobs, construction                      router, broadcaster
  TownLink: mirrors the Town Hall into the town  <-->   core: agents, tools, tasks, approvals,
  Realm: copy of the Town Hall's state                        Mana, ledger, rewards, ranks, ages,
  Net: WebSocket, requests, catch-up                          incidents, parties, workspaces
  world views, HUD, windows, input                      providers: fake | claude | codex | pi
                                                        db: SQLite (WAL), append-only logs
                                                               |
                                    child processes: Claude Code CLI, codex app-server, pi --mode rpc
                                                               |
                                                  git worktrees in the player's work folders
```

## Who owns what

| The Town Hall owns | The client owns |
|---|---|
| Agents, their add-ons, ranks and experience | The map, terrain and resource nodes |
| Tasks, their state machine and workspaces | Units: townsfolk, agents' bodies, couriers, wisps |
| Approvals and approval rules | Gathering, construction, training queues |
| Mana (the real budget) and provider usage | Placement of homes, add-ons and buildings |
| The resource ledger (the treasury) | The camera, HUD, windows and input |
| The age, parties and incidents | Offline towns (no Town Hall) |
| Saved towns (the client's snapshot, stored as given) | |

The client changes the economy only through commands (`spend_resources`, `refund_resources`,
`report_gather`, `trade`, `advance_age`), so the ledger in the Town Hall stays the single source
of truth. Every game constant lives in `protocol/economy.json`, which both sides load; the client
reads a byte-for-byte copy (`client/data/economy.json`, kept in step by
`node scripts/sync-economy.mjs`).

## The protocol

[protocol/PROTOCOL.md](../protocol/PROTOCOL.md) is the contract; the Town Hall's zod schemas in
`townhall/src/protocol/` must match it, and `npm run gen:gd` generates the GDScript constants
the client uses (`protocol/generated/protocol.gd`, copied to `client/net/protocol.gd`).

- WebSocket at `ws://127.0.0.1:<port>/ws`; messages are `{v, type, request_id, payload}` and each
  command is answered by `<type>_result`.
- The first message is `hello` with the session token. Only one client is active at a time; a
  second gets `SESSION_BUSY` unless it asks to take over, and the replaced client is told
  `session_revoked`.
- Events carry a sequence number and a `causation_id`. On reconnect the client sends its last
  sequence number and the Town Hall replays what it missed, or sends a full snapshot when the gap
  is too large. A gap the client notices itself triggers `get_state`.
- `request_id` is an idempotency key: repeating a command with the same id returns the first
  result instead of acting twice. The client's economy operations use their operation id as the
  request id.
- Version 1.3 adds `get_progress` (the town's facts, the next age's cost and milestones, the
  Quartermaster's current rates), the `progress_updated` event with the same data, and
  `shutdown`, which lets the game close the Town Hall.

## The Town Hall

| Folder | Role |
|---|---|
| `src/daemon.ts`, `src/main.ts` | Start-up: configuration, database, services, server, the runtime file; clean shutdown on SIGINT, SIGTERM or SIGBREAK |
| `src/server/` | `http.ts` serves the web build and upgrades `/ws`; `ws.ts` handles connections, `hello` and catch-up; `router.ts` validates and dispatches commands with the idempotency cache; `handlers.ts` implements them; `broadcaster.ts` numbers and fans out events |
| `src/core/` | The game's real state: `agents`, `tools`, `tasks/` (state machine, scheduler, run supervisor), `approvals`, `incidents`, `mana`, `ledger`, `bounty`, `ranks`, `ages`, `progress`, `parties`, `workspace`, `economy`, `settings`, `town` |
| `src/providers/` | One adapter per harness, plus the scripted `fake` provider |
| `src/db/` | SQLite in WAL mode with migrations; the event log and the ledger are append-only (enforced by triggers) |
| `src/security/` | The session token, Host and Origin checks, the work-folder path guard, secret redaction in logs and events |

### Tasks

A task moves through these states (`src/core/tasks/state-machine.ts`):

```
in_transit -> queued -> preparing -> running <-> awaiting_approval -> awaiting_review
                                                                        |
                              accepting -> accepted (reward paid)  <----+
                                        -> queued (sent back with feedback)
                                        -> rejected (abandoned)
any active state -> paused (budget, restart, stalled) | failed | cancelled
```

- **in_transit**: the task scroll is on its way. The task starts when a townsperson or the Font
  Wisp delivers it (`task_delivered`), or after a fixed time so a forgotten scroll never blocks
  work. "Express dispatch" skips the walk.
- **preparing**: the Town Hall reserves Mana for the task's seal and sets up the workspace: a git
  worktree (under `<data>/wt/`) on a branch `aurelhaven/<agent>/<task>` for a repository, or a
  versioned copy (under `<data>/mirrors/`) for a plain folder.
- **running / awaiting_approval**: the run supervisor starts the agent's harness. Every
  permission request becomes an approval; the run waits until the player answers it.
- **awaiting_review**: the work is committed as a snapshot and the changed files are recorded.
- **accepting / accepted**: the player accepted; the Town Hall merges (only into a clean checkout
  on the target branch), keeps the branch, or exports the files, then pays the reward in
  resources and experience.

After a restart, tasks resume their harness sessions and unanswered approvals reappear.

### Agents on real harnesses

The Town Hall runs no model loop of its own. Each provider adapter
(`src/providers/types.ts: ProviderAdapter { probe, listModels, start }`) launches an existing
harness as a child process and translates its headless interface:

| Provider | Harness | Interface | Approvals |
|---|---|---|---|
| `claude` | Claude Code CLI | `claude -p` with stream-json in and out | an MCP permission-prompt tool bridged to the Town Hall |
| `codex` | Codex CLI | `codex app-server`, JSON-RPC over stdio | the app server's approval requests |
| `pi` | pi coding agent (bundled npm package) | `pi --mode rpc`, JSON lines | a pi extension (`aurelhaven-gate.ts`) |
| `fake` | none | scripted scenarios in `src/providers/fake/scenarios/` | scripted |

`AURELHAVEN_PROVIDER` selects `fake` (practice agents for all three harness names) or `real`.
The add-ons decide which tools each harness gets; the approval mode decides which calls ask the
player. Cost comes from the harness (Claude Code's cost total) or from token counts priced with
`protocol/pricing.json` (Codex, pi), and the usage limits the harnesses report (Claude Code's
rate-limit events, Codex's rate-limit updates) appear in `Mana.provider_windows`.

A Claude agent leading a party also gets the Town Hall's own `town` tools, served by a small MCP
server, to delegate sub-tasks to its members (Claude, Codex or pi), follow them and collect their
results. Every member's approval requests still come to the player. The details, flags and known
limits are in [docs/spikes.md](spikes.md), section S5.

### Mana and the ledger

- Mana is stored in whole micro-dollars (1 Mana = $0.01). The pool refills each period at the
  Dawn Bell; unused Mana does not carry over.
- A task reserves its seal when it starts; spent plus reserved never exceeds the pool. A task
  that reaches its seal pauses and offers to extend it or stop for review. At 25% left the
  lanterns dim, at 10% the warning bell rings and automatic dispatch pauses, at 0 the Font goes
  dark. The player's controls never cost anything.
- The resource ledger records every change to Food, Wood, Stone and Gold as an append-only entry,
  so the treasury can always be rebuilt. Rewards (the bounty formula in `economy.json`) are paid
  only for accepted work.

## The client

### Autoloads

| Autoload | Role |
|---|---|
| `ClientLog` | Logging |
| `Settings` | `user://settings.cfg` and key bindings |
| `Economy` | `economy.json` |
| `Notify` | Toasts |
| `Audio` | Sound cues (a stub until Phase 5) |
| `Net` | The WebSocket: discovery, connection, requests (`Net.request` returns a `NetRequest`), reconnect with backoff, catch-up |
| `Realm` | The client's copy of the Town Hall's state (agents, tools, tasks, approvals, incidents, parties, Mana, age, treasury), with signals for every change |
| `Game` | Boot, the simulation clock, the current `SimWorld`, saves, switching between the practice and real Town Halls and closing one; owns `Game.link` (TownLink) |

### Boot

1. `Game.boot` looks for a Town Hall (`TownHallDiscovery`: the `AURELHAVEN_RUNTIME` file, then
   `%APPDATA%\Aurelhaven\runtime.json`, then `townhall/data/runtime.json` next to the project or
   the exported build).
2. If none answers within 3 seconds and `townhall/auto_start` is on, `TownHallLauncher` runs
   `townhall/scripts/launch.mjs`, which starts the Town Hall detached, in the mode named by the
   `townhall/provider` setting and on that mode's data folder: `townhall/data/practice/` for
   practice agents (the default), `townhall/data/` for real ones. The game waits up to 45 seconds
   for it, or until its log says it could not start.
3. Online, TownLink loads the town saved in the Town Hall (or makes a new one) and switches the
   ledger to a `RemoteLedger`. Offline, the game plays a local town with a `LocalLedger`.

The Town Hall keeps running after the game quits, so agents can work while the player is away.
`Game.switch_town_hall_mode(mode)` saves the town, asks the running Town Hall to `shutdown`,
waits for it to end and opens the other mode's Town Hall and town; `Game.close_town_hall()`
closes it and carries on offline. Whatever fails, the player keeps a town.

### The simulation

- `SimWorld` (`client/sim/`) is plain data stepped at 20 ticks a second from a real-time
  accumulator. All input goes through serializable `GameCommands`, applied by
  `command_applier.gd`, so the same command log can later drive shared towns.
- Units run jobs (`client/sim/jobs/`): idle, move, gather, deposit, build, courier and agent. The
  agent job walks an agent to its plot, builds its home and add-ons, and then lives at home,
  working at the add-on that matches its current tool.
- Pathfinding uses a 128 x 128 grid with footprints marked solid. Agent homes sit on 7 x 7 plots
  (`HomeLayout`): a 3 x 3 home with a ring of space for add-ons.
- Saves: an offline town is saved under `user://`; an online town is saved to the Town Hall as a
  gzip and base64 snapshot of the simulation, ledger and client state, so floats round-trip
  exactly.

### TownLink

`client/game/town_link.gd` joins the Town Hall to the town:

- It mirrors Realm into the simulation: an agent that is training becomes a queue item at the
  Keep, a trained agent becomes a unit that needs a plot, homes and add-ons become buildings, and
  task states drive what the agent is seen doing.
- It turns simulation events into commands: a finished home sends `home_built`, a finished
  add-on `tool_built`, a delivered scroll `task_delivered`.
- It picks couriers (an idle townsperson, then a gatherer; never a builder) and sends a Font Wisp
  when nobody carries a scroll.
- It offers the actions the windows use: summon, place a home, attach a tool, assign a task,
  answer an approval, accept, send back and the rest.

### The economy in the client

`RemoteLedger` keeps an optimistic copy of the treasury: the Town Hall's balance plus operations
still in flight. Each spend carries an operation id (also its request id); a spend the Town Hall
refuses is rolled back in the simulation (`revoke_spend`). Gathering is reported in one-second
batches.

### World and UI

- `client/world/`: views that interpolate the simulation (units, buildings, homes with their
  status signs, wisps, resource fields), the terrain and sky, effects, and the RTS camera.
- `client/ui/hud/`: the top bar (resources, population, Town Hall status, age, Mana orb), the
  bottom panel (minimap, selection panel, 5 x 3 command card) and stacked windows.
- `client/ui/agents/`: the agent windows (Summoning Font, task composer, approval tray, review,
  budget, folder browser, agent panel).
- `client/input/`: selection, the right-click rules, the command card model and key bindings.

## Files on disk

| Path | Contents |
|---|---|
| `townhall/data/practice/` | The practice town's Town Hall data, with the same layout as `townhall/data/` |
| `townhall/data/townhall.db` (+ `-wal`, `-shm`) | The Town Hall's database |
| `townhall/data/runtime.json` | `{pid, port, token, url, data_dir}` of the running Town Hall; removed on a clean stop |
| `townhall/data/townhall.log` | The log of a Town Hall the game started |
| `townhall/data/wt/` | Task worktrees of the player's repositories |
| `townhall/data/mirrors/` | Versioned copies of plain (non-git) work folders |
| `%APPDATA%\Aurelhaven\runtime.json` | A copy of the runtime file, where the game looks first |
| `%APPDATA%\Godot\app_userdata\Aurelhaven\` | The game's `settings.cfg`, offline saves and `logs/godot.log` |
