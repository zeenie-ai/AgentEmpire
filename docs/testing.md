# Testing

Every check the project has: what it proves, how to run it and how to add to it. The everyday
commands are also in [development.md](development.md#everyday-commands), and the scripts behind
the checks in [scripts/README.md](../scripts/README.md).

Run commands from the repository root unless noted. `<godot>` is the Godot console executable,
`.tools\godot\Godot_v4.7.2-stable_win64_console.exe`; in a worktree, use the main checkout's.

| Check | What it proves | Command |
|---|---|---|
| Town Hall type check | `src/`, `test/`, `scripts/` and both vitest configs compile under strict TypeScript | `cd townhall; npm run typecheck` |
| Town Hall unit tests | Pure logic: the task state machine, bounty, Mana, ranks, the guards, the harness helpers; that `PROTOCOL.md` matches the schemas; that the source has no destructive git | `cd townhall; npm test` (with the integration tests) |
| Town Hall integration tests | A whole Town Hall over its WebSocket with scripted agents, and each harness adapter against a stand-in for its harness | `cd townhall; npm test` |
| Smoke tests | The adapters work with the installed harnesses and real models | `cd townhall; $env:AURELHAVEN_SMOKE_CLAUDE = "1"; npm run test:smoke` |
| Client GUT tests | The simulation, the ledgers, the agent windows, the Rive state tracker, Town Hall discovery and audio, headless | `<godot> --headless --path client -s addons/gut/gut_cmdln.gd -gdir=res://tests/unit -gexit` |
| End-to-end check | The whole loop between a real Town Hall and the real client, from summoning to a merged, rewarded task | `node scripts/e2e-client.mjs` |
| `input_smoke.gd` | Mouse and keyboard input reaches the simulation as a player's would | `<godot> --path client -s res://tools/input_smoke.gd` |
| `boot_check.gd` | The game boots as a player's does and opens a town | `<godot> --headless --path client -s res://tools/boot_check.gd` |
| `townhall_mode_check.gd` | Switching between the practice and real Town Halls, and closing one | `<godot> --headless --path client -s res://tools/townhall_mode_check.gd` |
| Sync check | The client's copies of `economy.json` and `protocol.gd` match their sources | `node scripts/sync-economy.mjs --check` |
| Rive sheet check | The task seals and agent sigils in `client/art/rive/` were baked from the current `art_src/rive/state_tracker` (the manifest's source hash), and every sheet `rive_sprites.json` names exists | `node scripts/bake-rive.mjs --check` (no Rive CLI needed) |
| Exe check | The exported Windows game starts, shows a window and logs no error | `pwsh scripts/check-exe.ps1` |
| Package smoke test | An unzipped release package runs as a player's would | `node scripts/smoke-package.mjs <package folder>` |
| Art verify | Every model, character and icon matches `art_src/manifest.json` | the last step of `art_src/blender/build_all.py` (see [development.md](development.md#art)) |
| Rive verify | The RML of the task seals and agent sigils compiles | `rive art_src/rive/state_tracker --verify` (needs the Rive CLI; also the first check of a bake) |
| CI | The release packages build, and three of them start on their own systems | `.github/workflows/release.yml`, on a `v*` tag or by hand |

## Town Hall tests

`npm test` runs `vitest.config.ts`: `test/unit/` and `test/integration/`, each file in its own
forked process and the files in parallel, with 60 s per test and per hook. `npm run test:smoke`
runs `vitest.smoke.config.ts`: `test/smoke/*.smoke.test.ts`, one file at a time, with 900 s per
test, printing each test's output even when it passes. vitest does not type-check, so run
`npm run typecheck` too. One file: `npm test -- test/integration/full-loop.test.ts`; tests by
name: `npm test -- -t "bounty"`.

| Path | Contents |
|---|---|
| `test/unit/` | Pure logic, partly as fast-check properties. `protocol.test.ts` fails when `protocol/PROTOCOL.md` and the zod schemas disagree on a command, event, error code, close code or enum value. `banned-git.test.ts` scans `townhall/src/` and `townhall/scripts/` (not the tests) for destructive git commands and checks that the runtime guard refuses them. `worktree-git.test.ts` covers the check of a worktree's `.git` and the settings on every git command the Town Hall runs |
| `test/integration/` | A Town Hall over the protocol (the full loop, approvals, couriers, budgets, incidents, parties, restarts and replay, the protected checkout, the Town Hall's own git against repositories an agent planted, shutdown, the web server and more), and each real adapter against its stand-in |
| `test/smoke/` | The opt-in real-harness runs and `smoke-helpers.ts` |
| `test/helpers/harness.ts` | `TestTown`, a Town Hall inside the test process; `town.client()` connects a `TestClient` and sends `hello`. `TestClient` sends commands (`ok()` throws on an error reply) and waits for events (`waitEvent`, `nextEvent`, `waitTask`). `summonAgent` takes an agent through creation, training, its home and its add-ons until it is active. `tempRoot` and `removeRoot`, which retries while Windows still holds a file |
| `test/helpers/git.ts` | `makeRepo` (a repository on `main` with one commit), `commitAll`, `git`, and `treeHashes`, which proves that a checkout did not change |
| `test/helpers/run-host.ts` | `MockHost`, a `RunHost` that records a run and answers its approvals with `decide`; `runRequest`; `testDeps` (the real `economy.json` and `pricing.json`); `writeJson`, `readLog` and `within` |

**Isolation.** `TestTown.start(label)` calls `loadConfig({}, overrides)`. With an empty
environment no `AURELHAVEN_*` variable from your shell applies, and no discovery file is written,
because its default comes from `APPDATA` or `HOME`. The overrides put the data, work and web
folders in a new temporary folder, `aurelhaven-<label>-*` in the system temp folder, on port 0
with logging off. The clock is a `TestClock`: real time that `town.clock.advance(ms)` moves on,
firing every timer that falls due. `town.stop()` stops the Town Hall and removes the folder.
Agents are the scripted practice agents unless the test passes `adapters`. `shutdown.test.ts`
runs `src/main.ts` as a process, on its own temporary data folder and discovery file.

**The stand-ins** in `test/fixtures/`, which the adapters find through `AURELHAVEN_CLAUDE_BIN`,
`AURELHAVEN_CODEX_BIN` and `AURELHAVEN_PI_BIN`:

| Fixture | Stands in for | Controlled by |
|---|---|---|
| `fake-claude.mjs` | The Claude Code CLI: `--version`, `auth status`, and `-p` with stream-json. It starts the approval MCP server named in `--mcp-config` and calls it for every tool call, so the whole approval path runs | `FAKE_CLAUDE_SCENARIO` (or `FAKE_CLAUDE_SCENARIOS`, picked by `[scenario:<name>]`), `FAKE_CLAUDE_HOME` (sessions, so `--resume` works), `FAKE_CLAUDE_LOG`, `FAKE_CLAUDE_AUTH` |
| `fake-codex.mjs` | The Codex CLI: `--version`, `login status`, and `app-server` speaking JSON-RPC with approval requests, as codex 0.144 does | `FAKE_CODEX_SCENARIO`, `FAKE_CODEX_HOME`, `FAKE_CODEX_LOG`, `FAKE_CODEX_AUTH` |
| `pi-faux-provider.mjs` | The model: a pi extension (`pi -e`) with a scripted provider, `faux/faux-1`, for the real pi bundled in `node_modules` | `AURELHAVEN_PI_FAUX_SCRIPT`, `AURELHAVEN_PI_FAUX_LOG` |

pi runs with `PI_OFFLINE=1` and a temporary `PI_CODING_AGENT_DIR`, so it needs no network and
never reads your `~/.pi`. The pi tests skip when the bundled pi is missing.

**Adding a test.** Put pure logic in `test/unit/<area>.test.ts`, and anything that goes through
the protocol in `test/integration/`, against a `TestTown` (`courier.test.ts` is a short example).

- **Stop the town** in `afterAll` or a `finally`, so a failing test leaves nothing behind.
- **Drive it through the protocol** (`c.ok`, `waitEvent`, `waitTask`). Use `town.ctx` only to set
  up or check what the protocol does not show, and `town.clock.advance` instead of sleeping.
- **Script the agent** with a `[fake:<name>]` prefix on the task prompt, which picks a scenario
  from `townhall/src/providers/fake/scenarios/`. Scenarios are validated when a practice Town
  Hall starts and ship with the game, so a new one is open to practice towns too.
- **Test an adapter** with `MockHost`, `runRequest`, a scenario written with `writeJson` into the
  temporary folder, and the stand-in's `_BIN` variable.

## Smoke tests

The smoke tests run the real harnesses on real models and spend real usage. Each file runs only
when its switch is `1`; with none set, every one is skipped.

| Switch | Runs | Needs |
|---|---|---|
| `AURELHAVEN_SMOKE_CLAUDE` | Claude Code on `haiku` | Claude Code installed and signed in |
| `AURELHAVEN_SMOKE_CODEX` | The Codex CLI on the cheapest model in `protocol/pricing.json` that it offers | The Codex CLI installed and signed in (`codex login`) |
| `AURELHAVEN_SMOKE_PI` | pi on the cheapest model among the providers it has credentials for | Credentials for a provider (an API key in the environment, or `/login` in pi); without them the test skips |
| `AURELHAVEN_SMOKE_PARTY` | A party in a `TestTown`: a Claude Code lead and member on `haiku`, the lead delegating through the town tools; Codex and pi stay scripted | Claude Code installed and signed in |

The first three ask for one file, interrupt the run while its first approval waits, resume the
session and let the write through. Each run gets a $0.08 seal, the test's host interrupts a run
once its reported usage reaches $0.10, and the test fails if the total is above $0.10 (at API
prices, also on a subscription). The party works within a 9 Mana ($0.09) seal.

Set one switch at a time, when you change an adapter, its launch flags or a harness version, and
clear it afterwards (`Remove-Item Env:AURELHAVEN_SMOKE_CLAUDE`). Each test prints its report and
saves it in the system temp folder as `aurelhaven-smoke-<provider>.json`, where the single-harness
runs also leave their `aurelhaven-smoke-<provider>-*` folders. The harnesses run with your own
installation, sign-in and settings, and keep their session files where they always do (Claude
Code under `~/.claude/projects`).

## Client GUT tests

| Path | Contents |
|---|---|
| `client/tests/unit/test_<area>.gd` | Scripts that extend `GutTest`, one `test_` function per test, with a `##` comment saying what the file covers |
| `client/tests/fixtures/sim_fixture.gd` | `SimFixture`: `empty_world()` (only the Keep) and `generated_world(seed)`, both with a deterministic path service; `econ()`, `ledger()`, `ticks(w, seconds)`, `big_purse()` |
| `client/.gutconfig.json` | Runs `res://tests/unit/` and its subfolders, files named `test_*.gd`, and exits when done |
| `client/addons/gut/` | GUT 9.7.1, committed and enabled as an editor plugin, so the GUT panel works in the editor |

```powershell
<godot> --headless --path client -s addons/gut/gut_cmdln.gd -gdir=res://tests/unit -gexit
<godot> --headless --path client -s addons/gut/gut_cmdln.gd -gselect=test_ledger.gd -gexit
<godot> --headless --path client -s addons/gut/gut_cmdln.gd -gunit_test_name=refund -gexit
```

`-gselect` runs the files whose names contain the text, `-gunit_test_name` the tests whose names
do. The run exits with code 1 when a test fails; under GUT's defaults an engine error or a
`push_error` during a test fails it too. In a new checkout or worktree, import the client first
(`<godot> --headless --path client --import`). The export presets leave `tests/`, `tools/` and
`addons/gut/` out of every build.

- **Covered:** the simulation (grid, pathing, placement, construction, gathering, training,
  commands, map generation, walls, wanderers, save and reload), the economy data and its copy,
  both ledgers, agents as TownLink drives them, the agent windows from a fake Town Hall state
  (and that they fit 1280 x 720), discovery, the age and progress, the camera and the audio cues,
  and the Rive state tracker (a baked sheet for every task state and agent mood that matches the
  manifest, the fallback states, RiveSprite's loop and crossfade, the task tracker's order,
  clicks, lingering finished tasks, five-row limit, folding and place under the top bar, and the
  agent sigils on the agent panel and the name plates).
- **Not covered:** a real Town Hall (no GUT test starts one), real input, how anything looks and
  the exported game, which the checks below and screenshots cover; no check runs the web client.

To add a test, build worlds with `SimFixture`, step them with `w.step(SimFixture.ticks(w, s))`,
type every variable, free nodes with `add_child_autofree`, and restore any autoload state or
environment variable you change in `after_each`, as `test_townhall_discovery.gd` does.

## The end-to-end check

`node scripts/e2e-client.mjs [--keep]` needs git, Godot (it exits with code 2 if it finds none),
the Town Hall's packages (`npm ci` in `townhall/`) and an imported client.

- **Set-up:** a temporary folder, `aurel-e2e-*` in the system temp folder, holds the Town Hall's
  data and a work root with a new repository, `app`, on `main`. The script starts this checkout's
  Town Hall through tsx (`node --import tsx src/main.ts`) with practice agents, that data and work
  root, port 0 and no discovery file. Once its `runtime.json` appears (within 20 s), it runs
  `client/tools/e2e_client.gd` headless with `AURELHAVEN_RUNTIME` set to that file.
- **The client's part**, at eight times game speed: summon an Artificer with the Lectern,
  Quillworks and Forge and place its home; once it is active and the Forge stands, send a task
  (the `e2e_reward` scenario) by courier, approve its shell command and accept the result with a
  merge; check the reward, the town's progress, and the treasury against the Town Hall's ledger;
  save, reopen the town and compare; close the Town Hall and check that the game plays on
  offline. Each step prints as `e2e: ...`; the last line is `E2E OK` or `E2E FAILED: ...`.
- **It passes when** the client exits with code 0 after `E2E OK`, its output has no line
  containing `SCRIPT ERROR` or starting with `ERROR:`, `src/greeting.txt` is in the work
  repository (the merge brought it), and the Town Hall ends by itself within 15 s with code 0,
  having removed its `runtime.json`. Otherwise the script exits with code 1.
- **`--keep`** leaves the temporary folder, as a failure does, with the Town Hall's output in
  `townhall.log` and, after a save mismatch, `saved.json` and `loaded.json`.

To extend it, add steps to `e2e_client.gd` with `_wait`, `_step` and `_fail`; a new agent
behaviour needs a scenario of its own next to `e2e_reward.json`.

## The client tool checks

Three scripts in `client/tools/` are checks with a pass or fail result. The others render
screenshots, sound and frame times for you to judge ([development.md](development.md#client-tools)).

- **`input_smoke.gd`** needs a real window (under `--headless` it stops with exit code 2). It
  opens the main scene at 1600 x 900 on an offline town and injects events as a player would:
  box-select the townsfolk, right-click a berry bush, Q and a click to place a Cottage, H and Q to
  train at the Keep, a right-click rally point, then Ctrl+2, Escape and 2. Each check prints `ok`
  or `FAIL`; the last line is `input_smoke: PASS` or `FAIL`, with exit code 0 or 1.
- **`boot_check.gd`** loads the main scene as the game does and prints `BOOT ...` lines: whether
  it reached the Town Hall's town or an offline one, and how long it took (`-- --timeout=40`). It
  exits with 1 only when no town opened, so read its last line. It is not isolated: it joins any
  Town Hall it finds (`AURELHAVEN_RUNTIME` names a test one), or starts one on the checkout's
  `townhall/data` that keeps running and keeps the console executable waiting.
- **`townhall_mode_check.gd`** (headless, up to 360 s) runs a child Godot with its `APPDATA` and
  XDG folders, its Town Hall data root (`AURELHAVEN_DATA_ROOT`) and its work root in a temporary
  folder, `aurelhaven-modecheck-*`, with port 0 and no discovery copy. The child boots past a
  stale runtime file into a new practice Town Hall, switches to real agents (that Town Hall probes
  the installed harnesses, with no model call), fails to start a practice Town Hall on a bad
  `AURELHAVEN_PORT`, returns to the saved practice town and closes the Town Hall. The parent stops
  any Town Hall left over, removes the folder unless the check failed or `-- --keep` was given,
  and prints `TOWNHALL MODE CHECK OK` or `FAILED`. It needs `node` and the Town Hall's packages.

## The exe check

`pwsh scripts/check-exe.ps1 [-Seconds 12] [-Exe <path>]` runs on Windows only. It deletes the
game's log (`%APPDATA%\Godot\app_userdata\AgentEmpire\logs\godot.log`), starts
`client/export/windows/AgentEmpire.exe` from the script's checkout (or `-Exe`) and waits
`-Seconds`. It fails if the game has exited or shows no window; otherwise it captures the window's
contents (PrintWindow, so windows on top do not matter) to `out/exe-check.png`. It ends the game
with `Stop-Process -Force`, so the game does not save on quitting, and fails if the log is missing
or any line matches `ERROR`, printing the first ten. `Select-String` ignores case, so any line
that contains "error" counts, a warning that mentions one included. Look at the screenshot too.

The check is not isolated. Besides deleting your current game log, the exe plays as a player
would: it joins the first Town Hall it finds ([architecture.md, Boot](architecture.md#boot)), or
starts one for the mode in your settings on the checkout's `townhall/data`, which in the main
checkout holds your own towns. That Town Hall keeps running and writes the shared discovery copy;
stop it afterwards ([development.md](development.md#troubleshooting)). To keep the check away
from your towns, set `AURELHAVEN_DATA_ROOT` to a temporary folder and `AURELHAVEN_DISCOVERY_FILE`
to `off` in the shell that runs it.

## CI

`.github/workflows/release.yml` is the only workflow. It runs when a tag `v*` is pushed, or by
hand from the Actions tab (then it builds and checks without publishing), and never on a branch
push or a pull request.

| Job | Runs on | What it does |
|---|---|---|
| `package` | `windows-latest` | `node scripts/setup.mjs --all-templates` (`.tools/godot` is cached between runs), then `node scripts/package-release.mjs --targets all` (with the tag's version); keeps the zips, `SHA256SUMS.txt` and `RELEASE_NOTES.md` on the run for 14 days |
| `check` | `windows-latest`, `ubuntu-24.04`, `macos-latest` | Unzips the Windows, Linux and Apple Silicon packages as players do and runs `smoke-package.mjs` on each |
| `publish` | `ubuntu-24.04`, tags only | Creates the GitHub release as a pre-release if it does not exist, and uploads the zips and `SHA256SUMS.txt` |

- **It runs no tests:** no type check, vitest, GUT, sync check, end-to-end check or exe check.
  Compiling the Town Hall (`npm run build`) does fail on a type error in `townhall/src/`, but not
  in the tests. `package-release.mjs` copies the shared files into the client before exporting,
  so a stale copy never reaches a package, and is never reported either.
- **The Intel Mac package is built but never started**, and no web build is made.

## Isolation and the checklist

A Town Hall started for a test stays apart from the player's ([CLAUDE.md](../CLAUDE.md)):

- **Its own data:** a temporary `AURELHAVEN_DATA_DIR`, `AURELHAVEN_DISCOVERY_FILE=off`,
  `AURELHAVEN_PORT=0`, and a temporary `AURELHAVEN_WORK_ROOTS` when it runs agents.
  `AURELHAVEN_DATA_ROOT` moves both modes' data folders for a Town Hall the game starts.
- **The client finds it** through `AURELHAVEN_RUNTIME=<data>\runtime.json`.
- **Stop it** when you are done. Never touch the main checkout's `townhall/data` or
  `%APPDATA%\AgentEmpire`.

| Check | Its Town Hall | Leaves behind |
|---|---|---|
| Town Hall tests | In the test process, in a temporary folder | Nothing |
| Smoke tests | None, or a `TestTown` for the party | Reports and run folders in the temp folder; session files in your harness settings |
| GUT tests, `input_smoke.gd` | None | Nothing |
| Rive sheet check | None | Nothing |
| End-to-end check, `townhall_mode_check.gd` | Their own, in a temporary folder | Nothing, unless kept |
| `boot_check.gd`, exe check | Yours, or one they start on `townhall/data` | That Town Hall, running; the exe check also deletes your game log |
| Package smoke test | Its own, in a temporary folder | Nothing |

Every Godot run of the project, tests and tools included, uses the game's own user folder
(`%APPDATA%\Godot\app_userdata\AgentEmpire\`): it reads `settings.cfg` and writes
`logs\godot.log`. Only the child Godot of `townhall_mode_check.gd` gets a temporary one.

Before merging, in this order:

1. `cd townhall; npm run typecheck`
2. `cd townhall; npm test`
3. The client GUT suite
4. `node scripts/sync-economy.mjs --check`
5. `node scripts/bake-rive.mjs --check`
6. `node scripts/e2e-client.mjs`

Add what the change calls for: the smoke test of a harness whose adapter you changed;
`townhall_mode_check.gd` after changing how the game starts, switches or closes a Town Hall;
`input_smoke.gd` after changing input or the main scene; after changing `art_src/rive/`,
`rive art_src/rive/state_tracker --verify`, a full bake (`node scripts/bake-rive.mjs`), an
import, and the `rive_states` and `task_tracker` shots of `ui_preview.gd`; for a visual change,
screenshots at 1280 x 720 and at a large size (`ui_preview.gd -- --size=1280x720`). Merge with
`--no-ff`.

Before handing anyone an exe: build it (`node scripts/build-game.mjs --windows-only`), run
`pwsh scripts/check-exe.ps1` (0 error lines, and look at the screenshot), and commit. Before
pushing a release tag, run the same list: CI only builds the packages and starts them.
