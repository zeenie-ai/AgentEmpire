# protocol

What the Town Hall and the client share: the contract between them, and the data both load.

| File | What it is | Read by |
|---|---|---|
| [PROTOCOL.md](PROTOCOL.md) | The WebSocket protocol: connection, envelopes, shared objects, commands, events, and the rules both sides rely on | People. `townhall/test/unit/protocol.test.ts` checks its command, event, error-code, close-code and enum names against the Town Hall's zod schemas |
| `economy.json` | Every game constant: costs, rates, times, thresholds | The Town Hall at start (`AURELHAVEN_ECONOMY_PATH` moves it); the client through its copy, `client/data/economy.json` |
| `pricing.json` | US dollars per million tokens for Claude and Codex models, with aliases and a fallback model per provider | The Town Hall at start (`AURELHAVEN_PRICING_PATH` moves it) |
| `generated/protocol.gd` | GDScript constants made from the zod schemas: command, event and error names, close codes, the protocol version and every enum | The client through its copy, `client/net/protocol.gd` |

A release package ships `economy.json` and `pricing.json` in its own `protocol/` folder next to
the game.

## Changing them

- **`economy.json`**: edit it here, never the client's copy. Run `node scripts/sync-economy.mjs`
  to copy it into the client, and restart the Town Hall, which reads it only at start. The
  client test `test_economy_data.gd` fails while the copy is stale.
- **The protocol**: change the zod schemas in `townhall/src/protocol/` and `PROTOCOL.md`
  together, raise the version, then run `npm run gen:gd` in `townhall/` and the sync script. The
  steps are in [docs/development.md](../docs/development.md#changing-the-protocol).
- **`pricing.json`**: update a model's prices when its provider changes them, and add new models
  under their provider. Set `updated`, and mark any price you derived rather than read with
  `estimated`. The Town Hall reads it at start.
- **`generated/`**: never edit it by hand; `npm run gen:gd` rewrites it.

`node scripts/sync-economy.mjs --check` compares both copies with their sources without writing
anything.

## How Mana is priced

- **Claude Code** reports a running cost total for its session, which the Town Hall charges as
  it grows. `pricing.json` prices a Claude result only when it carries no cost, and gives the
  cost hints in Claude's model list.
- **Codex** reports only token counts, so Codex usage is always priced with `pricing.json`.
- **pi** prices every message itself from its own model catalogue, so pi models are not listed
  here.

1 Mana is $0.01 (`mana.usd_per_mana`). On a subscription the figures are API-equivalent
estimates, and the game marks them as such.

## `economy.json` at a glance

Times are in seconds unless the key says otherwise. Lists that end in `_by_age` hold one value per
age, from the first to the fourth.

| Key | What it sets |
|---|---|
| `tick_rate` | Simulation ticks per second |
| `map` | The map's size, the radii and gate counts of the four wall rings, and the agent home's plot and footprint |
| `start` | Starting resources, townsfolk and age |
| `resources`, `storage` | The four resources; the storage caps on Food and Wood by age, and what each Storehouse adds |
| `gather` | How much a townsperson carries, walking speeds, search radii, and each resource node's rate, amount and regrowth |
| `population`, `training_queue`, `units` | Population from the Keep and Cottages, the caps and agent limits by age, the population each unit takes, the queue length, and the townsperson's cost and training time |
| `agent_cost_scaling_per_existing` | How much each existing agent raises the cost of the next |
| `sizes` | The task sizes S, M, L and XL and their names |
| `roles` | The five agent roles: cost, training time, home, required, recommended and default add-ons, and how their rewards split across the resources |
| `buildings`, `construction` | Every building's footprint, cost, build time and population; the build-time formula for several builders |
| `tools` | The six add-ons: cost, build time, age, prerequisites, and what each grants on Claude Code, Codex and pi |
| `tool_slots_by_age`, `home_task_queue_by_age` | How many add-ons and queued tasks an agent's home holds, by age |
| `approval_modes` | The four approval modes, with the age, minimum rank and harnesses each needs |
| `ages` | The four ages: wall ring, cost, research time and milestones |
| `bounty` | The reward formula and its parts: base by size, first-try and efficiency bonuses, daily limits, the ceiling, the party split |
| `mana` | Mana's dollar value, the default pool and period, the seal for each task size, reservation rules, and the dim, warning and lights-out thresholds |
| `ranks`, `rank_first_try_window`, `levels` | What each rank needs and unlocks; the level curve |
| `parties` | When parties unlock, who may lead them, their size by age, and sub-task limits |
| `incidents` | When a quiet task rings the alarm bell or is paused, when an unanswered approval rings louder, and retry timings |
| `couriers` | How long a scroll waits before the Font Wisp takes it, and before it is delivered anyway |
| `anti_deadlock` | The wanderer who walks in when the town has no townsfolk and little food, and Font's Grace, which makes the first agent, its home and its required add-ons free |
| `quartermaster` | Trade amounts, and how the rates worsen with each trade and recover |
| `refunds` | What cancelling and dismantling give back |
