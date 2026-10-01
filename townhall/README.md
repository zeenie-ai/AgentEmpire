# Town Hall

The Town Hall is Aurelhaven's local service. It owns everything real: agents and their add-ons,
tasks and their workspaces, approvals, Mana, the resource ledger, ranks, ages and saved towns. It
runs each agent on an existing harness (the Claude Code CLI, the Codex CLI or pi) as a child
process and sends every permission request to the player. The game talks to it over a WebSocket
on 127.0.0.1; see [../protocol/PROTOCOL.md](../protocol/PROTOCOL.md) and
[../docs/architecture.md](../docs/architecture.md).

## Running it

The game starts a Town Hall by itself when none is running (`scripts/launch.mjs`: detached, no
console, output in `townhall.log` in its data folder). It keeps two towns apart: practice agents
in `data/practice/`, real ones in `data/`. The game can also ask a Town Hall to stop (the
`shutdown` command). To run one yourself:

```powershell
npm ci           # once
npm start        # tsx src/main.ts; prints the web client address and the runtime file
npm run dev      # the same, restarting on source changes
```

Ctrl+C stops it cleanly: it stops the running harnesses (their tasks pick up again at the next
start) and removes its runtime files. Only one Town Hall may use a data folder at a time.

By default it runs **practice agents**, a scripted stand-in for every harness. Set
`AURELHAVEN_PROVIDER=real` to run the installed harnesses:

```powershell
$env:AURELHAVEN_PROVIDER = "real"
npm start
```

## Configuration

Environment variables, all optional:

| Variable | Default | Meaning |
|---|---|---|
| `AURELHAVEN_PROVIDER` | `fake` | `fake` (practice agents) or `real` (the installed harnesses) |
| `AURELHAVEN_DATA_DIR` | `townhall/data` | Database, runtime file, log, plain-folder copies |
| `AURELHAVEN_PORT` | `0` (any free port) | The HTTP and WebSocket port on 127.0.0.1 |
| `AURELHAVEN_DISCOVERY_FILE` | `%APPDATA%\Aurelhaven\runtime.json` | Where to write the copy of the runtime file the game looks for first; `off` writes none |
| `AURELHAVEN_WORK_ROOTS` | your home folder and every non-system fixed drive | Folders under which agents may be given a work folder, separated by `;` |
| `AURELHAVEN_WEB_DIR` | `client/export/web` | The web build to serve |
| `AURELHAVEN_ECONOMY_PATH` | `protocol/economy.json` | Game constants |
| `AURELHAVEN_PRICING_PATH` | `protocol/pricing.json` | Token prices for Codex and pi usage |
| `AURELHAVEN_DEV_ORIGINS` | none | Extra origins allowed to open the WebSocket, separated by `,` |
| `AURELHAVEN_CROSS_ORIGIN_ISOLATION` | off | `1` sends COOP and COEP headers (only threaded web builds need them) |
| `AURELHAVEN_RITE_TIMEOUT_S` | `600` | Time limit for a task's Rite (its optional check command) |
| `AURELHAVEN_PLAIN_MAX_FILES`, `AURELHAVEN_PLAIN_MAX_MB` | `20000`, `200` | Size limits for copying a plain (non-git) work folder |
| `AURELHAVEN_FAKE_SCENARIO` | `basic` | The default script for practice agents (`src/providers/fake/scenarios/`) |
| `AURELHAVEN_LOG_LEVEL` | `info` | pino log level |
| `AURELHAVEN_CLAUDE_BIN`, `AURELHAVEN_CODEX_BIN`, `AURELHAVEN_PI_BIN` | found on PATH | A harness executable to use instead (an .exe, a Node script or an npm .cmd shim) |

The Town Hall makes a new session token at every start and writes `{pid, port, token, url,
data_dir}` to `<data>/runtime.json` and to the discovery file. The web client's address carries
the token in its `#t=` fragment.

## Data folder

| Path | Contents |
|---|---|
| `townhall.db` (+ `-wal`, `-shm`) | SQLite in WAL mode: agents, tools, tasks, approvals, incidents, parties, Mana periods, the append-only event log and ledger, settings, saved towns |
| `runtime.json` | The running Town Hall's endpoint and token |
| `townhall.log` | Output of a Town Hall started by the game |
| `wt/` | Task worktrees (git worktrees of the player's repositories) |
| `mirrors/` | Versioned copies of plain (non-git) work folders |
| `harness/`, `pi-sessions/` | Per-run harness files and pi session files |

Work in a git repository happens in a worktree of that repository, created under `wt/`, on a
branch `aurelhaven/<agent>/<task>`. The player's own checkout is touched only when they accept
and choose to merge.

## Source layout

| Path | Contents |
|---|---|
| `src/main.ts`, `src/daemon.ts` | Start-up and shutdown |
| `src/config.ts`, `src/paths.ts` | Configuration and default paths |
| `src/protocol/` | zod schemas for every message; the source of `protocol/generated/protocol.gd` (`npm run gen:gd`) |
| `src/server/` | HTTP (web build), WebSocket connections, command routing, event broadcasting |
| `src/core/` | Agents, tools, tasks (state machine, scheduler, run supervisor), approvals, incidents, Mana, ledger, bounty, ranks, ages, parties, workspaces |
| `src/providers/` | `fake/` (scripted scenarios), `claude/`, `codex/`, `pi/`, `common/` (processes, approvals, pricing, prompts, Waygates) |
| `src/db/` | Database access and migrations |
| `src/security/` | Token, Host and Origin checks, work-folder path guard, secret redaction |

## Tests

```powershell
npm run typecheck
npm test                    # unit and integration tests, no network and no real harness
```

- `test/unit/`: pure logic (state machine, bounty, Mana, ranks, guards, the harness helpers). A
  test also checks that no destructive git command (`reset --hard`, `clean`, `stash`, forced
  worktree removal) appears anywhere in the source.
- `test/integration/`: a real Town Hall over WebSocket with the scripted agent (the full loop,
  approvals, restarts, budgets, auth, parties), and each real adapter against a fake Claude Code
  CLI, a fake Codex app server or the real pi with a scripted model.
- `test/smoke/`: opt-in runs against the real harnesses, each capped at $0.10 of real usage:

  ```powershell
  $env:AURELHAVEN_SMOKE_CLAUDE = "1"   # or _CODEX, _PI, or _PARTY (a Claude lead and member)
  npm run test:smoke
  ```

The harness findings, launch flags and known limits are in
[../docs/spikes.md](../docs/spikes.md), section S5.
