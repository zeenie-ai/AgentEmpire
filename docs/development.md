# Development guide

How to set up the tools, run the tests, build the game and change it safely. For how the parts
fit together, read [architecture.md](architecture.md) first.

## Tools

| Tool | Where | Needed for |
|---|---|---|
| Node.js 22.12+ and git | on PATH | the Town Hall, every script |
| Godot 4.7.2 | `.tools/godot/`, by `node scripts/setup.mjs` | running, testing and building the client |
| Godot 4.7.2 export templates | `.tools/godot/editor_data/export_templates/4.7.2.stable/` (macOS: your user Library), by `setup.mjs` | building the game |
| GUT 9.7.1 | `client/addons/gut/` (committed) | client tests |
| KayKit source kits | `.tools/vendor/` via `node scripts/fetch-assets.mjs` | rebuilding art only |
| Blender 5.1 | `C:\Program Files\Blender Foundation\Blender 5.1\` | rebuilding art only |

`.tools/` is git-ignored. `node scripts/setup.mjs` fills it: it downloads Godot 4.7.2 for your
system from Godot's GitHub release (checked against its SHA-512 list), the export templates your
builds need, and installs the Town Hall's packages (`npm ci` in `townhall/`). On Windows and
Linux Godot runs self-contained (an empty `._sc_` file next to the editor), so its settings and
templates live in `.tools/godot/editor_data/`; on macOS the templates go to
`~/Library/Application Support/Godot/export_templates/`. Every script also accepts a `GODOT`
environment variable pointing at a Godot console executable elsewhere.

## Everyday commands

Run from the repository root unless noted. `<godot>` is
`.tools\godot\Godot_v4.7.2-stable_win64_console.exe`.

| What | Command |
|---|---|
| Town Hall tests (unit and integration) | `cd townhall; npm test` |
| Town Hall type check | `cd townhall; npm run typecheck` |
| Town Hall from source | `cd townhall; npm start` (or `npm run dev` to restart on changes) |
| Import the client (new checkout, new assets) | `<godot> --headless --path client --import` |
| Client tests | `<godot> --headless --path client -s addons/gut/gut_cmdln.gd -gdir=res://tests/unit -gexit` |
| End-to-end check | `node scripts/e2e-client.mjs` (`--keep` leaves its temporary folder) |
| Real harness smoke tests | `cd townhall; $env:AURELHAVEN_SMOKE_CLAUDE = "1"; npm run test:smoke` (also `_CODEX`, `_PI`; each capped at $0.10 of real usage) |
| Copy shared files into the client | `node scripts/sync-economy.mjs` (`--check` only compares) |
| Regenerate the client's protocol constants | `cd townhall; npm run gen:gd`, then sync |
| Build | `node scripts/build-game.mjs` (`--windows-only` or `--web-only`) |
| Check the built exe | `pwsh scripts/check-exe.ps1` (launches it, captures `out/exe-check.png`, fails on any ERROR line in the game log) |
| Rebuild all art | `blender --background --factory-startup --python-exit-code 1 --python art_src/blender/build_all.py` |

The end-to-end check starts a Town Hall with the scripted agent in a temporary folder, makes a
fresh git repository as the work folder, and plays the whole loop headless: summon, train, place
the home, build the add-ons, send a task by courier, answer an approval, review, accept (merge),
collect the reward, then compares the treasury with the Town Hall's ledger and checks that
saving and reloading give the same town.

The console executable waits for every process it started, including a Town Hall the game
launches. When that matters, run the GUI executable or pass `-- --offline`.

`check-exe.ps1` runs the game the way a player does, so if no Town Hall is running the game
starts one from `townhall/` and leaves it running. Stop it afterwards (see Troubleshooting).

### Client tools

Scripts in `client/tools/`, run with `<godot> --path client -s res://tools/<name>.gd`. The
screenshot tools need a real window, so leave out `--headless`.

| Tool | What it does |
|---|---|
| `e2e_client.gd` | The client half of `scripts/e2e-client.mjs` |
| `boot_check.gd` | Boots like a player and reports whether it reached the Town Hall's town or an offline one, and how long it took |
| `townhall_mode_check.gd` | Switches between the practice and real Town Halls and closes one, against Town Halls started from this checkout with temporary data (headless) |
| `agent_showcase.gd` | Screenshots of agents in a real town against a Town Hall (`AURELHAVEN_RUNTIME=<data>\runtime.json`, `-- --work=<git repo>`) |
| `ui_preview.gd` | Renders every agent window from a fake state into `out/ui_<name>.png` |
| `capture_screens.gd`, `snap_main.gd` | Screenshots of a demo town and of the main scene |
| `perf_stress.gd` | 90 busy townsfolk with the full scene and HUD; prints FPS, long frames and draw time |
| `input_smoke.gd` | Injects mouse and keyboard input into the main scene and checks the results |
| `char_check.gd`, `prop_check.gd` | Look-development renders for characters and carried props |

## Working on the code

**Keep the main checkout runnable.** The game and its exe are played straight from the main
checkout, so never leave it half edited. Do larger work in a git worktree:

```powershell
git worktree add -b my-change .wt/my-change master
```

`.wt/` is listed in `.git/info/exclude`. A new worktree has no Town Hall packages and no Godot
import cache: run `npm ci` in its `townhall/` and an import of its `client/`. A worktree has no
`.tools/` of its own: `scripts/e2e-client.mjs` finds the main checkout's copy from `.wt/<name>`,
and for the other scripts set `GODOT` to the main checkout's console executable.

Before merging, all of these must pass: the Town Hall type check and tests, the client tests,
`node scripts/sync-economy.mjs --check` and the end-to-end check. Merge with `--no-ff`. Before
handing anyone an exe, build it, run `check-exe.ps1` (0 error lines), and commit.

If you linked a worktree's `node_modules` to another checkout's with a directory junction,
remove the junction (`cmd /c rmdir <path>`) before deleting the worktree, or the delete follows
it into the other checkout.

### Changing the protocol

1. Change the zod schemas in `townhall/src/protocol/` (`commands.ts`, `events.ts`,
   `objects.ts`).
2. Update `protocol/PROTOCOL.md` in the same change. Raise `PROTOCOL_MINOR` in
   `townhall/src/protocol/version.ts` for a compatible addition, `PROTOCOL_MAJOR` for a breaking
   one.
3. `cd townhall; npm run gen:gd`, then `node scripts/sync-economy.mjs`.
4. Handle it in the client: state and events in `client/autoload/realm.gd`, actions in
   `client/game/town_link.gd`.
5. Add tests on both sides.

### Changing game constants

Edit only `protocol/economy.json`, then run `node scripts/sync-economy.mjs`. A client test fails
if the copy is stale, and a running Town Hall reads the file only at start.

## Releases

A release package is one zip per platform (`windows`, `linux`, `macos-arm64`, `macos-x64`) that
a player unzips and starts, with nothing else to install:

```
Aurelhaven-<version>-<target>/
  Aurelhaven.exe | Aurelhaven.x86_64 | Aurelhaven.app   the game (macOS: universal, ad-hoc signed)
  townhall/      the compiled Town Hall (dist/), its run-time files (src/), its packages for that
                 platform, and release.json, which marks it as a release
  runtime/node/  Node.js 22 for that platform, which runs the Town Hall
  protocol/      economy.json and pricing.json
  README.txt, CREDITS.md, licenses/
```

In a release the game finds `townhall/` next to itself (or next to `Aurelhaven.app`), starts it
with `runtime/node`, and keeps the towns in the player's data folder
(`%APPDATA%\Aurelhaven\townhall`, `~/Library/Application Support/Aurelhaven/townhall`,
`~/.local/share/Aurelhaven/townhall`). A development checkout keeps using `townhall/data`.

| What | Command |
|---|---|
| Godot, the templates for this computer, the Town Hall packages | `node scripts/setup.mjs` (`--all-templates` for every platform) |
| A package for this computer, also unzipped in `dist/` | `node scripts/package-release.mjs --unpacked` |
| Every package | `node scripts/package-release.mjs --targets all` |
| Start an unzipped package the way a player would | `node scripts/smoke-package.mjs dist/Aurelhaven-<version>-<target>` |

`build.cmd` (Windows), `build.command` (macOS) and `build.sh` (Linux) run the first two for
people who don't use a terminal.

To publish a release, set `config/version` in `client/project.godot` and the Windows file and
product versions in `client/export_presets.cfg`, commit, and push a tag `v<version>`. The
workflow in `.github/workflows/release.yml` builds every package on Windows, starts each one on
Windows, Linux and macOS with `smoke-package.mjs`, and publishes them, with `SHA256SUMS.txt`, as
a pre-release. Run it by hand from the Actions tab to build and check without publishing.

## GDScript conventions and pitfalls

- Type everything. The `INFERENCE_ON_VARIANT` warning is an error in this project, so declare
  the type when a value comes from `Dictionary.get`, an array element or any other Variant.
- Scripts run with `-s` are compiled before the autoloads exist. Don't reference classes that
  use autoloads by name in them; fetch autoload nodes with `get_root().get_node("Game")` into
  untyped variables.
- A multi-line lambda whose closing parenthesis lands inside a `match` block breaks the parser.
  Use a named method with `.bind()`.
- `String(null)` and `String(<int>)` are runtime errors. Use `str()` or the null-safe `J`
  helpers in `client/net/j.gd` for values from the network.
- Only `GameCommands` change a `SimWorld`; keep the simulation deterministic.
- Keep a reference to a `NetRequest` until its `done` signal fires.
- `OS.is_process_running(pid)` only knows processes the engine itself started.
- The engine clamps long frames, so the simulation clock is fed real elapsed time, not the
  frame delta.

## Art

`art_src/manifest.json` is the contract between the Blender pipeline and the client's
`client/art/model_library.gd`: one unit is one tile, +Y is up, models face +Z, and each static
model is a single mesh using the KayKit atlas. `art_src/blender/build_all.py` rebuilds every
model, character and icon into `client/art/` (committed) and writes contact sheets and a verify
report to `out/art/`. Sources come from `node scripts/fetch-assets.mjs`, pinned to fixed commits.
Credit new sources in [CREDITS.md](../CREDITS.md).

## Logs

| Log | Where |
|---|---|
| The game | `%APPDATA%\Godot\app_userdata\Aurelhaven\logs\godot.log` |
| A Town Hall the game started | `townhall/data/practice/townhall.log` (practice) or `townhall/data/townhall.log` (real) |
| A Town Hall started with `npm start` | its terminal |

## Troubleshooting

- **The top bar says OFFLINE.** The game found no Town Hall and could not start one. Check the
  `townhall.log` of the mode you play (see Logs), that `node` is on PATH, and that `npm ci` has
  been run in `townhall/`. Once a Town Hall runs (restart the game, or `npm start`), click the
  Town Hall chip in the top bar to connect.
- **The Town Hall refuses to start with "another Town Hall (pid N) is using ...", but none is
  running.** A Town Hall that was killed left its `runtime.json` behind (in `townhall/data/` or
  `townhall/data/practice/`), and Windows has since given its process id to another program.
  Delete that file and `%APPDATA%\Aurelhaven\runtime.json`.
- **A practice town from before the practice and real towns were split opens as the real
  town.** The game used to keep its practice town in `townhall/data/`, which is now the real
  town's folder; practice mode now starts a new town in `townhall/data/practice/`.
- **Stopping a Town Hall the game started.** The game can close it (`Game.close_town_hall()`),
  but the menu that offers this is still being built. Until then, end the `node.exe` process
  whose command line ends in `townhall\src\main.ts`, for example:
  ```powershell
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
    Where-Object CommandLine -match 'townhall\\src\\main\.ts' |
    ForEach-Object { Stop-Process -Id $_.ProcessId }
  ```
  A Town Hall in a terminal stops cleanly with Ctrl+C.
- **Real agents behave differently from the player's own harness setup.** Codex still reads the
  player's `~/.codex/config.toml`, and pi loads the player's own extensions. The full list of
  known harness limits is in [spikes.md](spikes.md), section S5.
- **Short freezes of about half a second on one machine.** Seen on a development machine with
  every renderer, even on an empty Godot scene, so it comes from the environment (overlay or
  capture software), not from the game. The simulation keeps real time through them.
