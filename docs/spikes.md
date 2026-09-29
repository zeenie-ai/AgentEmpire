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

Verified on 2026-09-29 with the Phase 3 client.

- The Town Hall serves `client/export/web` from its own origin. `index.html` is `text/html` and `index.wasm` is `application/wasm` (39.5 MB); the single-threaded export needs no COOP/COEP headers.
- Headless Edge, running WebGL 2 through SwiftShader, loaded `runtime.json`'s `url` (`http://127.0.0.1:<port>/#t=<token>`). The client:
  1. read the token from the fragment;
  2. moved it into `sessionStorage`, so a reload of the same tab still connects;
  3. cleared it from the address bar (`location.hash` was empty after load);
  4. connected to `ws://<same host>:<port>/ws` and opened the Town Hall's own town (`hall-...`).
- Software rendering took 50-60 s from page load to the first frame; a real GPU is much faster.
- Found and fixed along the way: the camera edge-scrolled toward the top-left while the pointer had never moved over the page (Godot reports it at 0,0). Edge scrolling now waits for a real mouse movement over the window.
