# scripts

The scripts that set up the tools, build and package the game, run the checks, and rebuild the
art sources and the sound. Run them from the repository root; the Node scripts need Node.js 22.12
or newer (`setup.mjs` checks it). [docs/testing.md](../docs/testing.md) explains the checks, and
[docs/development.md](../docs/development.md) the everyday commands.

| File | What it does | Also needs |
|---|---|---|
| `setup.mjs` | Installs Godot, its export templates and the Town Hall's packages | Network |
| `build-game.mjs` | The development build, into `client/export/` | Godot and its templates |
| `package-release.mjs` | The release packages, into `dist/` | Godot, its templates, the Town Hall's packages, network |
| `build.cmd`, `build.sh`, `build.command` | One-click builds, at the repository root | |
| `e2e-client.mjs` | The end-to-end check | Godot, git, the Town Hall's packages |
| `smoke-package.mjs` | Starts an unzipped release package the way a player would | |
| `check-exe.ps1` | Checks the exported Windows game | Windows, `pwsh`, an exported game |
| `sync-economy.mjs` | Copies the shared protocol files into the client | |
| `fetch-assets.mjs` | Fetches the KayKit art kits | git, network |
| `fetch-audio.mjs` | Builds the game's sound into `client/audio/` | ffmpeg, network |
| `lib/godot.mjs`, `lib/download.mjs`, `lib/zip.mjs` | Code the scripts share | |

## Setting up and building

**`setup.mjs`** `[--all-templates] [--no-templates] [--skip-townhall]` gets everything needed to
build and run from source. A second run does only what is missing.

1. **Godot 4.7.2** for this computer, into `.tools/godot/`, from Godot's GitHub release and
   checked against its `SHA512-SUMS.txt`. On Windows and Linux an empty `._sc_` file makes the
   editor self-contained, so its settings and templates stay in `.tools/godot/editor_data/`.
2. **Export templates**, from the one templates archive (about 1.2 GB): this computer's desktop
   platform, or Windows, Linux and macOS with `--all-templates`; `--no-templates` skips them. It
   never installs the Web templates. On macOS they go to Godot's folder in your user Library.
3. **The Town Hall's packages:** `npm ci --ignore-scripts` in `townhall/`, unless `node_modules`
   is up to date with `package-lock.json` or `--skip-townhall` is given.

The archives go to `.tools/downloads/` and are deleted once unpacked. It needs github.com and the
npm registry.

**`build-game.mjs`** `[--windows-only | --web-only]` is the development build. It runs
`sync-economy.mjs`, imports the client, exports the "Windows Desktop" preset to
`client/export/windows/AgentEmpire.exe` and the "Web" preset to `client/export/web/`, and lists
the files with their sizes. The exe uses its checkout's `townhall/`, and a Town Hall from that
checkout serves the web build.

- **Web templates:** the Web preset, without threads or extensions, needs Godot's
  `web_nothreads_release.zip`, which `setup.mjs` never installs. Until the Web templates are
  installed another way (for example with the Godot editor's export template manager), the
  default run and `--web-only` fail at the Web export; use `--windows-only`.
- **macOS and Linux:** it exports the Windows preset unless given `--web-only`, so it needs the
  Windows templates (`setup.mjs --all-templates`). For this computer, use `package-release.mjs`.

**`package-release.mjs`** `[--targets <list>] [--version <x.y.z>] [--skip-export] [--unpacked]`
builds the release packages. `--targets` takes `host` (the default: this computer), `all`, or a
comma list of `windows`, `linux`, `macos-arm64` and `macos-x64`. `--version` defaults to
`config/version` in `client/project.godot`. `--skip-export` reuses the games already in
`client/export/`, and `--unpacked` also leaves each package unzipped in `dist/`, ready to play.

It syncs the shared files into the client, imports it, exports each preset once (the two Mac
targets share one universal export) and compiles the Town Hall into a new `townhall/dist/`. For
each target it stages a package in `build/release/<name>/`: the game; the compiled Town Hall with
its `src/` (read at run time), `scripts/launch.mjs`, `release.json` and its packages for that
platform (`npm ci --omit=dev --ignore-scripts --os --cpu`, keeping only that platform's
esbuild); Node.js 22.20.0 for that platform, checked against nodejs.org's `SHASUMS256.txt` and
cached in `.tools/downloads/`; `protocol/economy.json` and `pricing.json`; `CREDITS.md`,
`licenses/` and a `README.txt`. It zips each into `dist/AgentEmpire-<version>-<target>.zip`, with
Unix permissions that keep the programs runnable, and writes `dist/SHA256SUMS.txt` and
`dist/RELEASE_NOTES.md`. It needs `setup.mjs` first (`--all-templates` for other platforms), and
nodejs.org and the npm registry. There is no package for Linux on ARM.

**`build.cmd`** (Windows, double-click), **`build.command`** (macOS, double-click in Finder) and
**`build.sh`** (Linux or macOS, `./build.sh`), at the repository root, build the game in one step.
Each checks that `node` is on PATH, then runs `node scripts/setup.mjs` and
`node scripts/package-release.mjs --unpacked`. `build.cmd` pauses to show any error and opens
`dist` when done; `build.sh` stops at the first error; `build.command` runs `build.sh` and opens
`dist` when it succeeds. `.gitattributes` fixes their line endings (CRLF for `.cmd`, LF for the
others), whatever the cloning computer's git settings.

## Checks

**`e2e-client.mjs`** `[--keep]` is the end-to-end check
([docs/testing.md](../docs/testing.md#the-end-to-end-check)). It writes only to a temporary
folder, `aurel-e2e-*` in the system temp folder, which it removes unless the check failed or
`--keep` was given. It needs git, Godot, the Town Hall's packages and an imported client, and
exits with code 0 on a pass, 1 on a failure and 2 when it finds no Godot.

**`smoke-package.mjs`** `<unzipped package folder>` checks a package the way a player uses it:

1. The package's Node.js runs its compiled Town Hall with practice agents, which writes its
   runtime file and answers HTTP on its port.
2. esbuild's native program, which pi needs for its extensions, runs with that Node.js.
3. The game, started headless, starts its own practice Town Hall and connects to it, as that
   Town Hall's log shows within 90 s.

Everything runs with `AURELHAVEN_DISCOVERY_FILE=off`, port 0 and its data in a temporary folder,
`aurelhaven-smoke-*`; every process it started is stopped and the folder removed. The game still
reads your own game settings: if you last chose real agents in the game, it starts a real Town
Hall instead and the third check fails. It exits with code 1 on any failure, and 2 for a folder
without `townhall/release.json`. The release workflow runs it on Windows, Linux and Apple Silicon.

**`check-exe.ps1`** `[-Seconds 12] [-Exe <path>]` (Windows) starts the exported game
(`client/export/windows/AgentEmpire.exe` unless `-Exe` names another), captures its window to
`out/exe-check.png` and fails on any line of the game's log that contains "error" in any case. It
deletes that log first, and the game may start a Town Hall on `townhall/data` that keeps running:
see [docs/testing.md](../docs/testing.md#the-exe-check).

**`sync-economy.mjs`** `[--check]` copies `protocol/economy.json` to `client/data/economy.json` and
`protocol/generated/protocol.gd` to `client/net/protocol.gd`, unchanged. `--check` writes nothing
and exits with code 1 when a copy differs; either way it exits with 2 when `economy.json` is not
valid JSON. Run it after changing `economy.json` and after `npm run gen:gd`; `build-game.mjs` and
`package-release.mjs` run it first. Nothing checks that `protocol/generated/protocol.gd` matches
the Town Hall's schemas, so run `npm run gen:gd` after every schema change.

## Assets

**`fetch-assets.mjs`** `[--dest <dir>]` fetches the two CC0 KayKit kits the Blender pipeline
builds from, the Medieval Hexagon Pack and the Adventurers character pack, into
`.tools/vendor/kaykit-medieval/` and `.tools/vendor/kaykit-adventurers/` (or under `--dest`), each
a shallow git checkout at a pinned commit. A kit already at its commit is skipped; one at another
commit or with files missing is fetched and switched. `GIT_CEILING_DIRECTORIES` keeps git inside
the vendor folders. It needs git and github.com.

**`fetch-audio.mjs`** `[--vendor <dir>] [--out <dir>] [--only <cue,...>] [--no-music] [--offline]`
rebuilds the sound in `client/audio/`. It downloads the CC0 sources (Kenney packs, OpenGameArt
music, Freesound recordings), each pinned by URL and SHA-256, synthesises the bells, chimes and
magic from fixed seeds, then trims, layers, normalises and encodes everything, and writes
`client/audio/cue_files.gd`, the index the Audio autoload loads. `--vendor` moves the download
cache (by default the main checkout's `.tools/vendor/audio`), `--out` the output folder; `--only`
rebuilds just the named cues (`music` and `ambience` count as cues); `--no-music` skips the music
and ambience beds, the slowest part; `--offline` never downloads and fails when a source is not
in the cache. It needs ffmpeg with libvorbis on PATH (or `FFMPEG` set to its path), and
kenney.nl, opengameart.org and freesound.org for sources not yet cached. Its header gives the
loudness targets; `client/audio/cue_table.gd` holds each cue's mix.

## Shared code

| File | What it holds |
|---|---|
| `lib/godot.mjs` | Godot's version (4.7.2) and download names; `toolsDir`, `findGodot` (`GODOT`, else the editor in `.tools/godot/`) and `templatesDir`; the template files each release target needs (none for the web) |
| `lib/download.mjs` | Downloads with a progress line, checked against a SHA-256 or SHA-512 digest from a checksum list; a file already downloaded with the right digest is reused |
| `lib/zip.mjs` | Reads zips (Zip64 included) without loading them whole, and writes zips that keep Unix permissions |

## Worktrees

`.tools/` is git-ignored, so a worktree has none of its own.

- **`lib/godot.mjs`** uses the main checkout's `.tools/` when the checkout sits directly in a
  folder named `.wt` (`.wt/<name>`), has no `.tools/` of its own, and the main checkout has one.
  So `setup.mjs` (Godot, templates and downloads), `build-game.mjs`, `package-release.mjs` (Godot
  and the Node.js cache) and `e2e-client.mjs` use the main checkout's Godot. `setup.mjs` still
  installs the worktree's own Town Hall packages.
- **`fetch-audio.mjs`** finds the main checkout with `git rev-parse --git-common-dir`, so every
  worktree shares one audio cache, wherever it is.
- **`fetch-assets.mjs`** always writes the checkout's own `.tools/vendor/`. Run it in the main
  checkout: the Blender pipeline finds the kits in the nearest parent folder that has them, and a
  `.tools/` made in a worktree stops `lib/godot.mjs` from falling back.
- **`GODOT`** points every script that runs Godot at another executable. `check-exe.ps1`,
  `smoke-package.mjs` and `sync-economy.mjs` need no `.tools/`.

`townhall/scripts/` holds two more: `gen-gd.ts`, run by `npm run gen:gd`, writes the generated
GDScript constants from the zod schemas, and the game runs `launch.mjs` to start a Town Hall.
