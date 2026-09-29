# Phase 0 spikes

All runs were on this Windows 11 machine on 2026-09-28. Real model calls were kept tiny: one Haiku 4.5 task (estimated $0.013) and three Codex turns on the ChatGPT plan.

## S1: Claude Agent SDK (`@anthropic-ai/claude-agent-sdk` 0.3.283, bundles Claude Code)

**Approval round trip works.**
- With `permissionMode: "default"` and `tools: ["Read","Write"]`, the agent's `Write` call waited on our `canUseTool` callback (we delayed 3 s), then ran. The file was created.
- `canUseTool(toolName, input, options)` receives `signal`, `suggestions`, `blockedPath`, `decisionReason`, `mcpServer {name, source}` and **`title`**, a ready-made prompt sentence. Use `title` for approval cards.
- It returns `{behavior:"allow", updatedInput?}` or `{behavior:"deny", message, interrupt?}`.

**Cost.** The result message carries:
- `total_cost_usd`, which the SDK documents as an estimate that is cumulative per `query()`;
- `usage`: input, cache creation and cache read, output, and thinking tokens;
- `modelUsage`.

This test cost $0.0126 in 2 turns on Haiku 4.5.

**Interrupt.** In streaming-input mode, `interrupt()` returned `{"still_queued":[]}`, and the run ended with result subtype `error_during_execution` and `is_error: true`. The adapter must report a run it interrupted itself as **interrupted**, not failed.

**Billing detection.**
- `query.accountInfo()` is a control request with no model cost that answers in about 0.9 s. It returned `subscriptionType: "Claude Max"` and `apiProvider: "firstParty"`, with no `apiKeySource` under OAuth.
- So: `subscriptionType` present means subscription Mana (estimates); an `apiKeySource` of `ANTHROPIC_API_KEY` means API-key Mana.

**Models.** `query.supportedModels()` returns `{value, displayName}` pairs: default, opus (Opus 5.5), claude-fable-5-1, sonnet (Sonnet 5), haiku (Haiku 4.5), and older versions. Use it for `list_models`.

**Init message.** The `system/init` message arrives only after the first user message.

**Not tested yet** (for Phase 4):
- an approval held for 30 minutes or more;
- whether our PreToolUse hook takes precedence over project rules when `settingSources: ["project"]`;
- child-process cleanup when the Town Hall is killed on Windows.

## S2: Codex app server (`@openai/codex` 0.158.0, ChatGPT login)

**Launching.**
- Spawn the native exe directly: `node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe app-server`.
- Spawning the `.cmd` shim on Windows needs a shell, so avoid it.

**Protocol.** JSON-RPC over stdio, one JSON object per line, without a `jsonrpc` field:
1. `initialize {clientInfo:{name,title,version}, capabilities:null}`;
2. the `initialized` notification;
3. `model/list`;
4. `thread/start {cwd, approvalPolicy:"untrusted", sandbox:"workspace-write", ephemeral:true}`;
5. `turn/start {threadId, input:[{type:"text", text, text_elements:[]}]}`.

**Approvals work.**
- The server sends a request, `item/commandExecution/requestApproval {kind, threadId, turnId, itemId, command, cwd, reason}`.
- The client answers `{decision: "accept" | "acceptForSession" | "decline" | "cancel"}`.
- File changes use `item/fileChange/requestApproval` with the same decisions.

**Windows specifics.**
- Commands run through **PowerShell 7** (`pwsh -Command ...`). Role instructions for Codex on Windows must say so. A cmd-style `echo hi> out.txt` did not redirect.
- Writes inside the `workspace-write` sandbox work: `Set-Content` created the file after approval.

**Events:**
- `thread/started`, `turn/started`;
- `item/started` and `item/completed` for `userMessage`, `agentMessage`, `reasoning`, and `commandExecution` (with `exitCode`, `aggregatedOutput`, `cwd`);
- `turn/completed`;
- `thread/tokenUsage/updated {total, last, modelContextWindow}`.

**Cost.** Codex reports **tokens only, never USD**. A trivial turn used 35–41k input tokens, about half of them cached, so Mana needs a per-model price table.

**Models on this account.** gpt-6-astra, gpt-6-sol, gpt-6-luna, gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5.

**Parties.** With `generate-ts --experimental`, `thread/start` accepts `dynamicTools: [{type:"function", name, description, inputSchema}]`, and the server calls the client back with `item/tool/call`. A Codex agent can therefore lead a party later, using the same `town_*` tools.

**Types.** Generate them with `codex app-server generate-ts [--experimental] --out <dir>`.

## S3: git worktrees on Windows (sent to the Town Hall builder)

- A worktree **root** must be short. Adding one at a 281-character path fails with `fatal: '$GIT_DIR' too big`, even with `core.longpaths=true`.
- With a short root (`<data>/wt/<8 chars>`, 62 characters here), files inside it with 288-character paths work fine in both git and Node.
- Pass `-c core.longpaths=true` on every git call instead of writing it into the user's repo config.
- Node reports a missing `cwd` as `spawn git ENOENT`. Check that the folder exists before spawning.
- This sequence works with no force flags, at about 60 ms per step:
  1. `worktree add -b`, then `lock`;
  2. edit files;
  3. `add -A`, then `commit --no-verify` with `-c user.name/user.email`;
  4. `diff --numstat -M base..head`;
  5. confirm the main checkout is still clean and unchanged;
  6. `merge --no-ff`;
  7. `worktree unlock`, then `worktree remove`.

## S4: web token handoff

Pending. It will be checked once the Town Hall serves the Godot web export (Phase 3).

## S5: Phase 4, the real harnesses (2026-09-29)

**Decision.** The Town Hall runs no agent loop, tool or model API of its own, and no SDK (S1's Agent SDK plan is dropped). It launches existing harnesses as child processes and talks to each through its documented headless interface:

| Provider | Harness | Interface |
|---|---|---|
| `claude` | Claude Code CLI 2.1.281 | `claude -p`, stream-json in and out |
| `codex` | Codex CLI 0.144.2 | `codex app-server`, JSON-RPC over stdio |
| `pi` (any other model provider) | pi 0.87.1 (`@earendil-works/pi-coding-agent`, pinned in townhall/package.json) | `pi --mode rpc`, JSON Lines commands and events |

The only glue plugs into documented extension points: an MCP server for Claude Code's `--permission-prompt-tool` (`approval-mcp.mjs`, no dependencies) and a pi extension (`aurelhaven-gate.ts`). Code lives in `townhall/src/providers/{claude,codex,pi,common}`. `AURELHAVEN_PROVIDER=real` selects these adapters.

**Finding the executables, never through a shell.**
- Overrides: `AURELHAVEN_CLAUDE_BIN`, `AURELHAVEN_CODEX_BIN`, `AURELHAVEN_PI_BIN` (an .exe, a Node script, or an npm .cmd shim).
- Otherwise PATH, where an npm `.cmd` shim is read and followed to its target: Claude Code's `bin/claude.exe` (a native binary), and for Codex the `codex.js` launcher is replaced by the native `codex.exe` in `@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin` (S2).
- pi: `AURELHAVEN_PI_BIN`, then a `pi` on PATH, then the Town Hall's own copy, run as `node <pkg>/dist/bundle/cli.js`. The package exports only an `import` entry, so it is found by walking `node_modules` rather than `require.resolve`.
- `--ignore-scripts` is not needed locally: pi's README says it needs no lifecycle scripts, the three in its tree are a no-op (`@google/genai`), esbuild's binary check and a protobufjs version warning, and better-sqlite3 13 has no install script at all (its prebuilds ship in the package). `npm ci` works with or without scripts.
- Harness environments drop the markers a parent agent session sets (`CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_MESSAGING_TOKEN`, `PI_SESSION_*`, ...), so a Town Hall started from inside Claude Code, Codex or pi launches clean harnesses.

**Process ends.** A run ends on the harness process's `exit`, then waits at most 2 s for stdout and stderr to close. On Windows a program the harness started (a shell command, a dev server, a build server) can inherit those pipes and hold them open long after the harness is gone; Node-based harnesses end their own direct children on exit (libuv job object), but not the children's children, and Codex (Rust) does neither. Once the process has exited it is never signalled again, since Windows can give its id to another process; taskkill runs from `%SystemRoot%\System32`. A launch that fails at once is reported as a spawn error rather than thrown.

**When asking fails.** If the Town Hall cannot record an approval (a database error, say), every adapter denies that call and the run goes on; nothing is left unanswered and no error escapes. A nudge that arrives after a run started to finish is reported as not delivered, and Codex never starts a new turn for it after a stop.

**Waygate names.** Each harness gets a Waygate's server name with anything outside `[A-Za-z0-9_-]` replaced by `_` (Claude Code does that in `mcp__<server>__<tool>` names, and Codex's dotted `-c` paths cannot carry a dot). Two Waygates whose names match after that, ignoring case, are not both used.

### Claude Code

**Launch:** `claude -p --input-format stream-json --output-format stream-json --verbose --setting-sources "" --settings {"permissions":{"ask":["*"]}} --strict-mcp-config --mcp-config <run>/mcp.json --permission-prompt-tool mcp__aurelhaven__approve --permission-mode manual|plan --tools <from add-ons> --append-system-prompt-file <run>/system-prompt.md --model <m> --session-id <uuid> | --resume <id> --max-budget-usd <restored session total + remaining seal x 1.1 + $0.01>` (the cap applies to Claude Code's running total, which on resume starts from the restored total), with `MCP_TOOL_TIMEOUT=604800000` (7 days), `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT=0` (the stdio idle limit would otherwise abort a pending approval after 30 minutes), `DISABLE_AUTOUPDATER=1`, and `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` when the agent has no Archive. Per-run files live under `<data>/harness/claude/` and are deleted after the run.

**Approvals.**
- `--setting-sources ""` keeps the player's user, project and local settings out: their allow rules (282 on this machine) and hooks would otherwise run tools without asking the Town Hall. OAuth sign-in is unaffected.
- `permissions.ask ["*"]` makes every tool call prompt, including reads inside the folder and Claude Code's built-in read-only commands, which Manual mode otherwise allows silently. Verified with Haiku: an in-folder `Read` reached the prompt tool.
- The prompt tool receives `{"tool_name","input","tool_use_id"}` and answers with a text result `{"behavior":"allow","updatedInput":{...}}` or `{"behavior":"deny","message":"..."}` (plus `"interrupt":true` when the run is stopping). The MCP server forwards each call to a per-run listener on 127.0.0.1 with a random bearer secret; the secret is in the per-run MCP config file only, not in Claude Code's environment, so the agent's shell never sees it. While waiting, the server sends MCP progress notifications.
- Categories: Read, Glob, Grep to read; Edit, Write, NotebookEdit (and ExitPlanMode) to write; Bash to command; WebSearch, WebFetch to network; `mcp__*` to mcp. A Waygate's `allowed_tools` is enforced by denying other tools of that server, matched on the server name as Claude Code writes it.
- The approval MCP server's own tool is visible to the model like any MCP tool. A call to `mcp__aurelhaven__*` by the agent is denied without asking, so it cannot put made-up requests in front of the player.
- `--mcp-config` expands `${VAR}` in `env`, `args` and `headers`, and stdio servers inherit the full environment (checked without a model call), so Waygate secrets are only ever named.

**Stream.** `system/init` arrives after the first message and carries `session_id`, the MCP server status and `capabilities` (`msg_lifecycle_v1`, `interrupt_receipt_v1`, `interrupt_cancel_queued_v1`). `command_lifecycle` reports queued, started and completed for each message uuid, which is how the adapter knows when every message (task, nudges) is answered before it closes stdin. Each content block comes as its own `assistant` message; tool results come as `user` messages; `result` has `total_cost_usd`, `user_message_uuids` and `terminal_reason`.

**Interrupt.** The documented `{"type":"control_request","request_id":...,"request":{"subtype":"interrupt","cancel_queued":true}}` answers `{"still_queued":[],"cancelled":[...]}` (a request with `type` in place of `subtype` is rejected). The adapter then closes stdin and Claude Code exits and saves the session. On Windows there is no SIGINT or SIGTERM for a child (Node terminates it), so the fallbacks are `taskkill /T` without `/F` (console programs refuse it) and then `/F`. `kill()` runs `taskkill /T /F` before closing stdin; a test checks that the approval MCP server dies with it.

**Cost.** `total_cost_usd` is a running total for the session, and Claude Code 2.1.277+ saves it when the process exits on its own and restores it on `--resume`. The adapter charges its growth and checkpoints, after each result, the total Claude Code will restore: the latest total, since Claude Code also exits on its own when the Town Hall dies and closes its stdin, or the process's starting total when a hard kill (`taskkill /F`, SIGKILL) reached the running process. An exit after a polite request (end of input, `taskkill` without `/F`, SIGTERM) counts as its own, so a wrong guess undercharges the next attempt a little and never charges twice. `estimate` is true when `claude auth status --json` shows a subscription.

**Probe and models.** `claude --version`; `claude auth status --json` (`loggedIn`, `authMethod`, `subscriptionType`; the email is never read into messages). Models come from the documented `initialize` control request, which answers without a model call: default, opus[1m], claude-fable-5-1[1m], sonnet, haiku. `cost_hint` comes from pricing.json.

**Resume.** `--resume <id>`. An unknown id prints "No conversation found with session ID" and exits 1; the adapter then starts a new session with the task and the feedback.

### Codex

**Launch:** `codex.exe app-server` with `-c features.<f>=false` for apps, plugins, multi_agent, computer_use, browser_use, browser_use_external, in_app_browser and image_generation (`--disable <f>` fails on an unknown feature name, `-c features.<f>=false` does not), `-c web_search="live"|"disabled"`, `-c project_doc_max_bytes=0` without an Archive, and per Waygate `-c mcp_servers.<name>.command/args/env_vars` or `url/env_http_headers`, `enabled_tools`, and `default_tools_approval_mode="prompt"`. `env_vars` and `env_http_headers` name variables, so no secret is copied.

**Protocol** (method names checked against `codex app-server generate-ts` from 0.144.2): `initialize` then `initialized`; `thread/start {cwd, approvalPolicy:"untrusted", sandbox, model, developerInstructions, ephemeral:false, config}` or `thread/resume {threadId, ...}`; `turn/start`; `turn/steer {expectedTurnId}` for nudges; `turn/interrupt`.

**Approvals.** Answers: accept, decline, or cancel when the run is stopping. A missing add-on declines without asking (the capability is missing; this is not a policy choice): without a Forge, commands; without a Quillworks, file edits and requests for write access, because Codex writes an approved patch even in a read-only sandbox.
- `item/commandExecution/requestApproval`: a command, or network when it carries `networkApprovalContext {host, protocol}`. The host goes into the request as a URL, so an answer for the task or the agent covers that host only; a host that does not parse can only be allowed once. `command` is optional in the request, so the adapter falls back to the `commandExecution` item started just before.
- `item/fileChange/requestApproval`: write. Its params have no paths, so they come from the `fileChange` item started just before, including the target of a move (`kind.move_path`); a path outside the worktree makes it outside_workspace. A request whose item was never announced is declined.
- `item/permissions/requestApproval`: parsed in full: `network.enabled`, the legacy `fileSystem.read`/`write` lists, and `fileSystem.entries`, each a path, a glob pattern or a special location (`root`, `minimal`, `project_roots`, `tmpdir`, `slash_tmp`, `unknown`) with read, write or deny access. Anything else declines without asking. The category is the strictest part: globs, special locations and paths outside the worktree (or starting with `~`, `$` or `%`) make it outside_workspace. Each kind of request has its own tool name (`network_access`, `file_access`, `permissions` for both, which can only be allowed once), so a scoped answer to one kind never covers another. Only what was understood is granted, for the turn.
- MCP tool approvals: `mcpServer/elicitation/request` (`_meta.codex_approval_kind: "mcp_tool_call"`), or `item/tool/requestUserInput` (question id `mcp_tool_call_approval_*`), named after the `mcpToolCall` item it belongs to; when that item is unknown, it can only be allowed once.
- The legacy `execCommandApproval` and `applyPatchApproval`.

**Trust.** The app server writes `[projects.'<folder>'] trust_level = "trusted"` into `~/.codex/config.toml` for every new folder whose sandbox can write it. Each thread therefore passes `config.projects.<cwd>.trust_level = "untrusted"`, which stops the write (verified) and keeps a repository's `.codex` config, which can start processes, from loading. The entries this spike's test runs had added were removed from the player's config.

**Usage.** `thread/tokenUsage/updated {total, last}` priced with pricing.json, charging the growth of `total`: from zero on a new thread, and on a resumed one from the total saved in the checkpoint, because the restored total includes earlier attempts and Codex can restate it (for example when rate limits update). A resumed thread without a saved total charges the first update's `last`.

**Probe and models.** `codex --version`; `codex login status` ("Logged in using ChatGPT", or "using an API key" followed by a masked key, which is never passed on); `model/list` (this account now offers gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna and gpt-5.5, not S2's list).

### pi

**Launch:** `pi --mode rpc --no-approve --session-dir <data>/pi-sessions/<task> --session-id aurelhaven-<task>` (or `--session <file>` from the checkpoint when resuming), `--provider <p> --model <id>` from `"<p>/<id>"`, `--tools <list>` or `--no-tools`, `--append-system-prompt <run>/system-prompt.md`, `--no-context-files --no-skills` without an Archive, `-e aurelhaven-gate.ts`, and `PI_SKIP_VERSION_CHECK=1`. Framing is LF-only; Node's readline is never used.

**The docs on GitHub are ahead of the release.** pi's `main` branch documents built-in MCP support, `pi.registerMcpServer` and a `data.disposition` on prompt responses; 0.87.1 has none of them. The docs bundled in `node_modules/@earendil-works/pi-coding-agent/docs` match the installed version.

**Approvals.** The gate's `tool_call` hook calls `ctx.ui.input("aurelhaven:approval", <call as JSON>, {signal})`; in RPC mode that is an `extension_ui_request`, answered with `extension_ui_response {value: {"decision":"allow"|"deny",...}}` or `{cancelled:true}`. A denial blocks with the player's message. `tool_execution_start` arrives before the dialog. `abort` cancels a pending dialog through `ctx.signal`, and the tool ends as "Operation aborted". Dialogs from other extensions are dismissed; their notifications become activity.

**Events.** `message_update` usage is cumulative per assistant message and `message_end` is final, so the adapter charges growth per message; `agent_settled` means done. `steer` and `follow_up` only queue while pi is idle (checked: they wait for the next prompt), so a nudge is a `steer` while streaming and a `prompt` otherwise. pi retries transient errors itself (`retry.*` settings), so a failure is classified on every error message seen, not only the last.

**Testing without a model.** pi-ai's faux provider (`createFauxCore`, `fauxAssistantMessage`, `fauxToolCall`) is registered with `pi.registerProvider` from a test extension (`test/fixtures/pi-faux-provider.mjs`, loaded with `-e`). The faux provider reports tokens but no cost, so the test extension prices them with `calculateCost`. Tests run the real pi this way, with a private `PI_CODING_AGENT_DIR`.

**Probe and models.** `pi --version`; `get_available_models` over RPC (only models whose provider has credentials); `pi auth check --provider <p> --json --no-refresh` for up to four of those providers (it prints a status and `authType`, never the credential). This machine has no pi credentials, so pi reports `logged_in: false`.

### Limitations found

- **Tools that do not ask.** Claude Code: none once `ask ["*"]` is set, except EndConversation, which ask rules never cover and `--tools` cannot remove; it only ends the conversation. Codex: its known-safe read-only commands (ls, cat, rg, Get-Content, git status and similar) run without asking under `untrusted`, and it has no ask-for-everything policy; web search is server side and never asks; MCP servers from the player's own `~/.codex/config.toml` keep their own approval mode. pi: none; every built-in, extension and MCP tool call goes through the gate.
- **Player configuration.** Codex still reads the player's `~/.codex/config.toml` (auth lives there): here that means `service_tier = "priority"` (1.5x usage), a `notify` command, hooks, and two user-level MCP servers (node_repl, openaiDeveloperDocs). pi still loads the player's user-level extensions (a custom provider may live there); project ones are refused.
- **Waygates on pi** need `pi.registerMcpServer`, which 0.87.1 lacks: the gate skips them and the run shows a warning. When pi ships MCP, the `--tools` allowlist may also need the MCP tool names.
- **Rookery on pi** gives nothing: pi has no web search or fetch tool.
- **Leftover programs.** A program an agent starts that outlives its harness (a dev server, a build server) is not ended by the Town Hall: `taskkill /T` reaches only the tree of a process that is still running, and there is no job object around the harness. The run no longer waits for such a program's inherited pipes.
- **Parties.** Party leads get no delegation tools yet on the real harnesses.
- **Provider windows.** Claude Code's `rate_limit_event` and Codex's `account/rateLimits/updated` are not yet fed into `Mana.provider_windows`.

### Smoke runs (opt-in: `npm run test:smoke` with `AURELHAVEN_SMOKE_CLAUDE=1`, `_CODEX=1` or `_PI=1`)

Each asks for one file, interrupts while the first approval waits (stop, then withdraw the approval, as the Town Hall does), resumes the session, and lets the write through, under a $0.10 cap.

- **Claude Code, Haiku 4.5, Max subscription: passed in 12 s.** Run 1: the Write waited, the interrupt answered it with a deny plus interrupt, and the transcript shows "[Request interrupted by user for tool use]"; Claude Code saved a session total of $0.0118845. Run 2 resumed session 74b5f608-7e9a-4f8c-9944-9dc3ff5e1869, the Write was approved, `smoke.txt` holds "aurelhaven smoke", and the reply was "Created smoke.txt with "aurelhaven smoke"." Claude Code's session total became $0.0167735, the restored $0.0118845 plus $0.004889 new. The adapter charged the deltas: 11,885 then 4,889 micro-USD, $0.0168 in all (an estimate: subscription). These figures come from the session transcript, because vitest 5 hid the console output of the passing test; the smoke config now prints reports and saves them to `%TEMP%\aurelhaven-smoke-<provider>.json`.
- **Codex, gpt-5.6-luna (the cheapest model model/list offers), ChatGPT plan: blocked by the account.** Its Codex usage limit is spent until 2026-10-05 16:50, so the turn failed before any model call: the adapter reported `failed`, code `provider_limit` ("You've hit your usage limit ... (usageLimitExceeded)"), which pauses a task and lights the Font Dark incident; no cost. The first attempt waited 240 s for an approval that could not come; the helper now races the run's outcome. Codex approvals are therefore tested only against the fake app server.
- **pi: skipped.** pi 0.87.1 is installed but has no provider credentials here.
