# Aurelhaven: notes for coding agents

[README.md](README.md) explains the game, [docs/architecture.md](docs/architecture.md) how the
Town Hall and the client work, and [docs/development.md](docs/development.md) every command.

## Rules

- **Keep the main checkout runnable.** The user plays the game and its exported exe straight
  from the main checkout. Do larger work in a git worktree under `.wt/` and merge only verified
  work.
- **Verify before merging:** in `townhall/`, `npm run typecheck` and `npm test`; the client GUT
  suite; `node scripts/sync-economy.mjs --check`; `node scripts/e2e-client.mjs`. Before handing
  over an exe: build it, run `pwsh scripts/check-exe.ps1` (0 error lines), and commit.
- **Look at what you render.** The user wants professional, polished visuals: check every visual
  change in a screenshot, at 1280x720 and at large resolutions.
- **Game constants** live only in `protocol/economy.json`; run the sync script after changing it.
  **Protocol changes** go into the zod schemas and `protocol/PROTOCOL.md` together, then
  `npm run gen:gd` and the sync script.
- **Agents run on existing harnesses only**: the Claude Code CLI, `codex app-server` and pi's RPC
  mode. Do not add an agent SDK or a model loop of our own.
- **No destructive git** in the Town Hall or its tests (`reset --hard`, `clean`, `stash`, forced
  worktree removal); a unit test enforces it.
- **Test Town Halls stay isolated:** a temporary `AURELHAVEN_DATA_DIR`,
  `AURELHAVEN_DISCOVERY_FILE=off` and `AURELHAVEN_PORT=0`; point the client at them with
  `AURELHAVEN_RUNTIME=<data>\runtime.json`, and stop them when done. Never touch the main
  checkout's `townhall/data` or `%APPDATA%\Aurelhaven`.
- **Real harness runs spend real usage.** Smoke tests are opt-in and capped at $0.10 each.
- No emojis in code, logs or output.

## GDScript pitfalls

- The `INFERENCE_ON_VARIANT` warning is an error: declare types for values from
  `Dictionary.get`, array elements and other Variants.
- Scripts run with `-s` compile before the autoloads exist: don't name classes that use autoloads
  in them; fetch autoloads with `get_root().get_node("Game")` into untyped variables.
- A multi-line lambda whose closing parenthesis lands inside a `match` block breaks the parser;
  use a named method with `.bind()`.
- `String(null)` and `String(<int>)` are runtime errors; use `str()` or the `J` helpers
  (`client/net/j.gd`).
- Only `GameCommands` change a `SimWorld`.
- The `*_console.exe` Godot wrapper waits for every process the game started, including a Town
  Hall it launched.
