# Development guide

How to set up the tools, run the tests, build the game and change it safely. For how the parts
fit together, read [architecture.md](architecture.md) first. [testing.md](testing.md) explains
every check, [../scripts/README.md](../scripts/README.md) every script, and
[../client/README.md](../client/README.md) and [../townhall/README.md](../townhall/README.md) the
two programs.

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
system from Godot's GitHub release (checked against its SHA-512 list), the desktop export
templates for this computer (every desktop platform with `--all-templates`; never the Web
templates), and installs the Town Hall's packages (`npm ci --ignore-scripts` in `townhall/`: no
install script is needed, and skipping them keeps npm from compiling better-sqlite3, whose
programs for every platform ship in its package, so no C++ toolchain is needed). On Windows and
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
| Real harness smoke tests | `cd townhall; $env:AURELHAVEN_SMOKE_CLAUDE = "1"; npm run test:smoke` (also `_CODEX`, `_PI` and `_PARTY`; each capped at $0.10 of real usage) |
| Copy shared files into the client | `node scripts/sync-economy.mjs` (`--check` only compares) |
| Regenerate the client's protocol constants | `cd townhall; npm run gen:gd`, then sync |
| Build | `node scripts/build-game.mjs` (`--windows-only` or `--web-only`; the web build needs Godot's Web export templates, which `setup.mjs` does not download) |
| Check the built exe | `pwsh scripts/check-exe.ps1` (launches it, captures `out/exe-check.png`, fails on any game-log line containing "error" in any case) |
| Rebuild all art | `blender --background --factory-startup --python-exit-code 1 --python art_src/blender/build_all.py` |
| Rebuild all sound | `node scripts/fetch-audio.mjs` (needs ffmpeg; downloads the CC0 sources into `.tools/vendor/audio`) |

The end-to-end check starts a Town Hall with the scripted agent in a temporary folder, makes a
fresh git repository as the work folder, and plays the whole loop headless: summon, train, place
the home, build the add-ons, send a task by courier, answer an approval, review, accept (merge),
collect the reward, then compares the treasury with the Town Hall's ledger, checks that saving
and reloading give the same town, and closes the Town Hall, which must exit cleanly and remove
its runtime file.

The console executable waits for every process it started, including a Town Hall the game
launches. When that matters, run the GUI executable or pass `-- --offline`.

`check-exe.ps1` runs the game the way a player does, so it is not isolated. It first deletes the
game's current log. The game then joins a running Town Hall if it finds one, or starts one for
the mode in your settings on this checkout's `townhall/data` and leaves it running. To keep it
off your towns, set `AURELHAVEN_DATA_ROOT` to a temporary folder and
`AURELHAVEN_DISCOVERY_FILE=off` in the same shell: the game then starts a throwaway Town Hall in
that folder. Stop the Town Hall afterwards (its pid is in the folder's `runtime.json`, or see
Troubleshooting).

### Client tools

Scripts in `client/tools/`, run with `<godot> --path client -s res://tools/<name>.gd`. The
screenshot tools need a real window, so leave out `--headless`.

| Tool | What it does |
|---|---|
| `e2e_client.gd` | The client half of `scripts/e2e-client.mjs` |
| `boot_check.gd` | Boots like a player and reports whether it reached the Town Hall's town or an offline one, and how long it took. Like the game, it may start a Town Hall on this checkout's `townhall/data` and leave it running |
| `townhall_mode_check.gd` | Switches between the practice and real Town Halls and closes one, against Town Halls started from this checkout with temporary data (headless) |
| `agent_showcase.gd` | Screenshots of agents in a real town against a Town Hall (`AURELHAVEN_RUNTIME=<data>\runtime.json`, `-- --work=<git repo>`) |
| `ui_preview.gd` | Renders every agent window from a fake state into `out/ui_<name>.png` |
| `capture_screens.gd`, `snap_main.gd` | Screenshots of a demo town and of the main scene |
| `perf_stress.gd` | 90 busy townsfolk with the full scene and HUD; prints FPS, long frames, draw time, and per frame the draw calls, primitives (main view and shadows) and GPU time. For the phone build: `--rendering-method mobile -s res://tools/perf_stress.gd -- --quality=low` |
| `input_smoke.gd` | Injects mouse and keyboard input into the main scene and checks the results |
| `touch_smoke.gd` | Injects screen touches into the main scene as on a phone (tap, double tap, the Select box, a gather order, placement and Build, rally, pan, pinch, twist) and checks the results; run it with `-- --mobile --dpi=420` |
| `store_art.gd` | Renders the Google Play icon and feature graphic and the Android launcher icons, and checks them against Play's limits (`--check` only checks) |
| `touch_ui_preview.gd` | Screenshots of the phone and tablet panels over a demo town: the game menu, the touch help, a card's long-press tip, a chip's tip and the placement hint (`-- --mobile --dpi=<n> --size=WxH`) |
| `char_check.gd`, `prop_check.gd` | Look-development renders for characters and carried props |
| `walls_showcase.gd` | Renders towns at Age I to IV and a wall mid-rise |
| `audio_check.gd` | Renders every sound cue to a WAV file for review, with loudness figures |

## Phones and tablets

The Android build plays the offline town: there is no Town Hall on a phone, so no agents yet.
It uses touch controls and a HUD sized in dp (one logical pixel is one Android dp, 1/160 inch);
`client/game/platform.gd` decides both. On desktop, two options after `--` preview it in a
window:

| Option | What it does |
|---|---|
| `--mobile` | Plays the phone and tablet build: offline, touch controls, the dp-sized HUD; the mouse acts as a finger |
| `--dpi=<n>` | The screen density `--mobile` assumes (a phone is about 420, a 10-inch tablet about 320) |

For example, a 6.5-inch phone: `<godot> --path client --resolution 2400x1080 -- --mobile --dpi=420`.
A smaller window at half the density gives the same layout: `--resolution 1200x540 -- --mobile --dpi=210`.

A phone or tablet saves the town to the `auto` slot (`user://saves/auto.json`) when the app goes
to the background or quits, and the next start resumes it; closing the `--mobile` preview window
does the same. Graphics default to Low there.

### Android builds

Two presets in `client/export_presets.cfg` build for phones and tablets: "Android APK", a debug
APK from Godot's prebuilt template for quick emulator rounds, and "Android", the release App
Bundle (`.aab`) for Google Play, built with Gradle. Both are for arm64-v8a and x86_64, package
`ai.zeenie.agentempire`, minimum SDK 24, target SDK 36. The scripts were made and tested on
Windows.

**Setup, once per computer.** Install the Android SDK command-line tools (Android Studio's SDK
Manager puts them in `%LOCALAPPDATA%\Android\Sdk`) and a JDK 17 (Godot's Gradle build runs on
it). Close the Godot editor, which writes its settings back when it quits, then run
`node scripts/setup-android.mjs --jdk=<JDK 17 folder>`. It writes the JDK and the Android debug
keystore (`%USERPROFILE%\.android\debug.keystore`) into Godot's editor settings, adds the NDK and
build-tools 36.1.0 the Gradle build needs, creates the `ae_phone` (Pixel 7) and `ae_tablet`
(Pixel Tablet) emulators, and downloads a pinned, checksum-checked bundletool into
`.tools/bundletool/`. Later runs only check. The other Android scripts take the SDK and the JDK
from Godot's editor settings.

| What | Command |
|---|---|
| Debug APK (under a minute) | `node scripts/build-android.mjs --apk`, writes `client/export/android/AgentEmpire-debug.apk` |
| Release App Bundle | `node scripts/build-android.mjs --aab`, writes `client/export/android/AgentEmpire.aab` |
| Smoke test on an emulator | `node scripts/android-smoke.mjs --avd=ae_phone` (or `ae_tablet`; `--aab` for the bundle) |

The first `--aab` build installs Godot's Gradle template into `client/android/` (git-ignored),
and Gradle downloads itself and its packages (about 1 GB); later bundle builds take about a
minute and a half.

**Signing.** The debug APK is signed with the Android debug key. The App Bundle is signed with
the upload key, kept outside the repository in `%USERPROFILE%\AgentEmpireKeys\`
(`agentempire-upload.jks`, alias `upload`, and its password in
`agentempire-upload-password.txt`). Keep a backup of both, and never commit, print or log them.
Google Play signs the installed app with its own key; the upload key only proves that an upload
comes from us. Set three variables before `--aab` (the script names any that are missing):

```powershell
$env:GODOT_ANDROID_KEYSTORE_RELEASE_PATH = "$env:USERPROFILE\AgentEmpireKeys\agentempire-upload.jks"
$env:GODOT_ANDROID_KEYSTORE_RELEASE_USER = "upload"
$env:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD = Get-Content -Raw "$env:USERPROFILE\AgentEmpireKeys\agentempire-upload-password.txt"
```

`jarsigner -verify -certs client\export\android\AgentEmpire.aab` (JDK 17's) checks a bundle.

**Smoke test.** `android-smoke.mjs` boots the emulator unless one runs (one at a time), installs
the build (an `.aab` through bundletool, signed with the debug key), starts the game, presses
Home and comes back, force-stops and restarts it, and presses Back, which must leave the game
running in front. It then checks the installed APKs (package, version code, target SDK 36, min
SDK 24, no INTERNET or AD_ID permission, Android backup off, landscape, 16 KB alignment), fails on
an ERROR, SCRIPT ERROR, FATAL, crash or ANR in logcat, and reports the renderer. Screenshots and
`logcat.txt` go to `out/android/<avd>-<apk|aab>/`. The emulator keeps running afterwards; stop it
with the SDK's adb (`%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe -s emulator-5554 emu
kill`), not an older adb on PATH.

**A new build for Google Play.** Every upload needs a higher version code: raise `version/code`
in the "Android" preset and in "Android APK" (the smoke test compares them), change
`version/name` when the game's version changes, build the bundle again and run the smoke test
with `--aab` before uploading.

**Deliberate settings.**
- Android frame pacing (Swappy) is off until we move to Godot 4.8
  (`window/frame_pacing/android/enable_frame_pacing=false` in `project.godot`): in 4.7 the
  emulator's GPU driver breaks it and the game shows a black screen there
  (godotengine/godot#121035, fixed in 4.8). Phones present with plain vsync meanwhile.
- Neither Android preset is runnable: with a runnable Android preset, every Godot editor run
  (`--import` included) polls adb and stops the adb server when it quits, cutting off a running
  emulator session. Use the scripts, not the editor's one-click deploy.
- The minimum SDK 24 is set in the "Android" preset; Godot's Gradle build would default to 29
  for the Vulkan renderer. Android 7 to 9 devices without Vulkan 1.1 fall back to OpenGL ES 3
  (`rendering/rendering_device/fallback_to_opengl3`, on by default).

## Working on the code

**Keep the main checkout runnable.** The game and its exe are played straight from the main
checkout, so never leave it half edited. Do larger work in a git worktree:

```powershell
git worktree add -b my-change .wt/my-change master
```

`.wt/` is listed in `.git/info/exclude`. A new worktree has no Town Hall packages and no Godot
import cache: run `npm ci` in its `townhall/` and an import of its `client/`. A worktree has no
`.tools/` of its own: `setup.mjs`, `build-game.mjs`, `package-release.mjs` and `e2e-client.mjs`
find the main checkout's copy from `.wt/<name>` (`scripts/lib/godot.mjs`), and `GODOT` points
any of them at another console executable. For the commands that call Godot directly, use the
main checkout's `.tools\godot\` path.

Before merging, all of these must pass: the Town Hall type check and tests, the client tests,
`node scripts/sync-economy.mjs --check` and the end-to-end check. Merge with `--no-ff`. Before
handing anyone an exe, build it (`node scripts/build-game.mjs --windows-only`), run
`check-exe.ps1` (0 error lines), and commit. [testing.md](testing.md) lists the checklist in
order, with what each check proves.

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
if `client/data/economy.json` is stale (`--check` also catches a stale `client/net/protocol.gd`),
and a running Town Hall reads the file only at start. [../protocol/README.md](../protocol/README.md)
maps the file's sections.

## Releases

A release package is one zip per platform (`windows`, `linux`, `macos-arm64`, `macos-x64`) that
a player unzips and starts, with nothing else to install:

```
AgentEmpire-<version>-<target>/
  AgentEmpire.exe | AgentEmpire.x86_64 | AgentEmpire.app   the game (macOS: universal, ad-hoc signed)
  townhall/      the compiled Town Hall (dist/), its run-time files (src/), its packages for that
                 platform, and release.json, which marks it as a release
  runtime/node/  Node.js 22 for that platform, which runs the Town Hall
  protocol/      economy.json and pricing.json
  README.txt, CREDITS.md, licenses/
```

In a release the game finds `townhall/` next to itself (or next to `AgentEmpire.app`), starts it
with `runtime/node`, and keeps the towns in the player's data folder
(`%APPDATA%\AgentEmpire\townhall`, `~/Library/Application Support/AgentEmpire/townhall`,
`~/.local/share/AgentEmpire/townhall`). A development checkout keeps using `townhall/data`.

| What | Command |
|---|---|
| Godot, the templates for this computer, the Town Hall packages | `node scripts/setup.mjs` (`--all-templates` for every platform) |
| A package for this computer, also unzipped in `dist/` | `node scripts/package-release.mjs --unpacked` |
| Every package | `node scripts/package-release.mjs --targets all` |
| Start an unzipped package the way a player would | `node scripts/smoke-package.mjs dist/AgentEmpire-<version>-<target>` |

`build.cmd` (Windows), `build.command` (macOS) and `build.sh` (Linux) run the first two for
people who don't use a terminal.

To publish a release, set `config/version` in `client/project.godot`, and in
`client/export_presets.cfg` the Windows file and product versions and the macOS short version
and version; commit, and push a tag `v<version>`. Nothing checks that these agree with the tag.
The workflow in `.github/workflows/release.yml` builds every package on Windows, starts the
Windows, Linux and macOS (Apple Silicon) packages on their own systems with `smoke-package.mjs`
(the Intel Mac package is built but not started), and publishes them, with `SHA256SUMS.txt`, as
a pre-release. Run it by hand from the Actions tab to build and check without publishing. The
workflow runs no tests; run the checks in [testing.md](testing.md) before tagging.

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
| The game | `%APPDATA%\Godot\app_userdata\AgentEmpire\logs\godot.log` |
| A Town Hall the game started | `townhall/data/practice/townhall.log` (practice) or `townhall/data/townhall.log` (real) |
| A Town Hall a release package started | `%APPDATA%\AgentEmpire\townhall\practice\townhall.log` (practice) or `%APPDATA%\AgentEmpire\townhall\townhall.log` (real) |
| A Town Hall started with `npm start` | its terminal |

## Troubleshooting

- **The top bar says OFFLINE.** The game found no Town Hall and could not start one. Check the
  `townhall.log` of the mode you play (see Logs), that `node` is on PATH, and that `npm ci` has
  been run in `townhall/`. Once a Town Hall runs (restart the game, or `npm start`), click the
  Town Hall chip in the top bar to connect.
- **The Town Hall refuses to start with "another Town Hall (pid N) is using ...", but none is
  running.** A Town Hall that was killed left its `runtime.json` behind (in `townhall/data/` or
  `townhall/data/practice/`), and Windows has since given its process id to another program.
  Delete that file and `%APPDATA%\AgentEmpire\runtime.json`.
- **A practice town from before the practice and real towns were split opens as the real
  town.** The game used to keep its practice town in `townhall/data/`, which is now the real
  town's folder; practice mode now starts a new town in `townhall/data/practice/`.
- **Stopping a Town Hall the game started.** Click the Town Hall chip in the top bar and choose
  **Close the Town Hall**: the game saves the town, closes the Town Hall
  (`Game.close_town_hall()`) and carries on offline. If no game is connected to it, end the
  `node.exe` process whose command line ends in `townhall\src\main.ts`, for example:
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
