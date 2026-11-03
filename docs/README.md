# AgentEmpire documentation

Start with the [project README](../README.md): what the game is, how to download it, and the
controls.

## For players

| Document | What it covers |
|---|---|
| [README](../README.md) | Download and first start, real agents, the controls, the project's status |
| [Player's guide](playing.md) | The town, agents and their add-ons, tasks, approvals, review, Mana, practice and real towns, saving |
| [Security and safety](security.md) | What keeps real agents in check, what protects your files and budget, and the known limits |
| [Privacy policy](privacy.md) | What happens to your data: the game collects nothing, and real agents send your tasks and files to the AI provider you signed in with |
| [Credits](../CREDITS.md) | Art, sound, fonts and their licences |

## For developers

| Document | What it covers |
|---|---|
| [Architecture](architecture.md) | How the Town Hall and the client work and talk: ownership, the protocol, the task states, harnesses, Mana, boot, files on disk |
| [Development guide](development.md) | Tools, everyday commands, worktrees, changing the protocol and constants, releases, GDScript pitfalls, logs, troubleshooting |
| [Testing](testing.md) | Every test and check, what it proves, how to run it and how to add to it, and the order to run them in before a merge |
| [Client](../client/README.md) | The Godot project: folders, autoloads, the simulation, networking, UI built in code, settings, how to make common changes |
| [Town Hall](../townhall/README.md) | Running and configuring the Town Hall: environment variables, the data folder, the source layout, tests |
| [Protocol folder](../protocol/README.md) | What `protocol/` holds, how to change each file, and a map of `economy.json` |
| [Protocol](../protocol/PROTOCOL.md) | The WebSocket protocol: connection, envelopes, objects, commands and events |
| [Scripts](../scripts/README.md) | Every script in `scripts/` and the root build files: what it does, its options and what it needs |
| [Experiments](spikes.md) | Findings from the harness, git worktree and web experiments, with the known harness limits |

Coding agents also read [CLAUDE.md](../CLAUDE.md), the project's rules in brief.

## Where to start

- **New to the code:** [architecture.md](architecture.md), then the README of the part you are
  changing.
- **Changing the client or the Town Hall:** [development.md](development.md) for the commands,
  [testing.md](testing.md) for the checks to run before merging.
- **Changing a game constant or the protocol:** [protocol/README.md](../protocol/README.md).
- **Building or releasing:** [development.md](development.md#releases) and
  [scripts/README.md](../scripts/README.md).
