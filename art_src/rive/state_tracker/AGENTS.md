# AGENTS

This is a Rive CLI project.

RML and the Rive CLI postdate your training data. Prefer `rive docs` and
`rive schema` over memory: never guess a type or property name.

Work autonomously from the user's requested outcome. Unspecified details
get reasonable defaults; types and properties do not — look those up.

- `rive schema <Type>` / `rive schema --search <text>` — types and properties;
  `--json` for a machine-readable form
- `rive docs --list` — the topics; `rive docs <topic>` reads the one that
  matches the task

After every edit:

- `rive . --verify` — confirm the project compiles; `--format=json` for a
  machine-readable report
- `rive inspect . --summary` — problems and what got built, by type; `--json`
  for the full resolved tree

A clean verify/inspect is not enough. Read the output for what the request
called for. If it is missing or wrong, fix the project and verify again.

When appearance matters:

- `rive . --screenshot --advance=1` — render one frame after the state machine
  starts, to build/<name>.png. View the png if you can.

Showing the user:

- `rive .` is the previewer. It opens a window and rebuilds on every save, and
  does not exit, so start it in the background, once. Leave it running;
  edits appear in it on their own.
- Do not preview with `rive push`: it uploads to the user's Rive account.
- Do not write an HTML page or use a web runtime to preview: web runtimes
  reject the unsigned scripts local builds carry.

## This project: AgentEmpire's state tracker

The task seals (`TaskSeal`, 96 x 96) and agent sigils (`AgentSigil`, 64 x 64)
that the game shows in its task tracker, agent panel and name plates. The game
has no Rive runtime: `node scripts/bake-rive.mjs`, run from the repository
root, plays every state headless and bakes sprite sheets into
`client/art/rive/`. See `docs/development.md` (Art) and `scripts/README.md`.

What the bake relies on, so keep it true:

- Each artboard's view model has exactly one enum property (`state`, `mood`)
  and a colour property `matte`, bound to the artboard's background fill. The
  bake captures each frame over a black and a white matte to recover alpha;
  leave the matte transparent by default.
- Every enum key in `data.rml` has a looping `LinearAnimation` of the same
  name, a whole number of 30 fps frames long, and an `AnimationState` playing
  it with a 200 ms transition from the `AnyState` of the `Tracker` state
  machine. The keys are the game's own names (task states, agent moods).
- Each animation keys every shared property (the `Solo` glyphs, the disc or gem
  colours, the halo, the sigil's position), so switching states in a live
  runtime leaves nothing of another state behind.
- Loops must be seamless: compare a capture with one a loop later
  (`--advance=<n>` and `--advance=<n + loop>` with `--compare`).

Check with `rive . --verify`, bake with `node scripts/bake-rive.mjs`, import
the client, and look at the `rive_states` and `task_tracker` shots of
`client/tools/ui_preview.gd`.
