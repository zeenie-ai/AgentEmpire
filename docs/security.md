# Security

How AgentEmpire keeps real agents in check and the Town Hall safe, what each safeguard does not
do, and the known limits. How to play is in [playing.md](playing.md).

## What is protected, and against what

| Against | Safeguards |
|---|---|
| Agents acting without your consent or outside their work folder | Tools only from add-ons; the harnesses' permission requests go to the Town Hall, which passes them under the agent's approval mode and rules or asks you |
| Other programs and web pages driving the Town Hall | 127.0.0.1 only, Host and Origin checks, a token made at each start, one session at a time |
| Your work being lost, or changed without your acceptance | A worktree and branch per task, a merge only on acceptance and only into a clean checkout, archived discards, no destructive git |
| Files an agent writes that make the Town Hall's own git run commands | No hooks, fsmonitor command, external diff or textconv in the Town Hall's git, a checked `.git` in each worktree, nested repositories left out |
| Runaway spending | A Mana pool per period, a seal per task, reservations and pauses, a hard cap for Claude Code |

Out of scope:

- **A harness's own behaviour** beyond its headless interface; see [Known limits](#known-limits).
- **A tampered harness.** The Town Hall runs the `claude`, `codex` or `pi` it finds and trusts it.
- **What an approved command does.** It runs with your rights; only Codex sandboxes commands.
- **Other programs running as you,** which can read the session token.
- **What AI providers do with what they are sent;** see [privacy.md](privacy.md).

## The network surface

- **Loopback only.** The Town Hall listens on 127.0.0.1, on `AURELHAVEN_PORT` or a free port.
- **Host and Origin.** Every HTTP request must name `127.0.0.1:<port>` or `localhost:<port>` as
  its `Host`, which blocks DNS rebinding. The WebSocket upgrade is accepted only on `/ws`, with no
  `Origin` (the desktop client), the Town Hall's own origin or one in `AURELHAVEN_DEV_ORIGINS`;
  never with a `null` Origin.
- **The session token.** 32 random bytes, new at every start, compared in constant time, kept in
  `runtime.json` in the data folder (mode 0600 on macOS and Linux) and in the discovery copy,
  `<config dir>/AgentEmpire/runtime.json` (moved or turned off by `AURELHAVEN_DISCOVERY_FILE`).
  The web build gets it in the address's `#t=` fragment, which never reaches a server, and moves
  it to `sessionStorage`, clearing the address bar. Apart from the start-up message, which prints
  that address to the terminal or to `townhall.log`, no log line or event carries it.
- **The connection.** The first frame must be a `hello` with the token, within 5 seconds, or the
  socket closes (4002 no hello, 4001 bad token, 4400 protocol mismatch). One client at a time: a
  second gets `SESSION_BUSY`, and a hello with `take_over` closes the first with 4409. Frames are
  JSON text of at most 1 MiB, and every command is checked against its zod schema.
- **What HTTP serves.** `GET` and `HEAD` only: the web build (`client/export/web` or
  `AURELHAVEN_WEB_DIR`, nothing outside it), `/healthz` (versions only) and `/ws`.

The token stops web pages and programs that cannot read your files. Any program running as you
can read `runtime.json` and connect, and that includes a command you allow an agent to run.

## Tools come from add-ons

An agent can use only what its finished add-ons grant (`tools` in `protocol/economy.json`):

| Add-on | Claude Code | Codex | pi |
|---|---|---|---|
| Lectern: read files | `Read`, `Glob`, `Grep` | the `read-only` sandbox | `read`, `grep`, `find`, `ls` |
| Quillworks: write files | `Edit`, `Write` | the `workspace-write` sandbox | `edit`, `write` |
| Forge: run commands | `Bash` | commands beyond its known-safe reads | `bash` |
| Rookery: web search and fetch | `WebSearch`, `WebFetch` | `web_search = "live"` | nothing (pi has no such tool) |
| Archive: instructions and skills | `CLAUDE.md` files | `AGENTS.md` files | context files and skills |
| Waygate: an MCP server | the server, limited to its `allowed_tools` | the same | skipped (see [Known limits](#known-limits)) |

- **Claude Code and pi** get an explicit list of built-in tools (`--tools`, or pi's `--no-tools`).
- **Codex** has no tool list. Its sandbox is `read-only` without a Quillworks, and the Town Hall
  declines, without asking you, commands from an agent without a Forge and file edits or write
  access from one without a Quillworks. Web search is `disabled` without a Rookery.
- **Without an Archive** the instruction files are switched off (`CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`,
  `project_doc_max_bytes=0`, and pi's `--no-context-files` and `--no-skills`).
- **Fixed per run.** The tools are read when a run starts, so dismantling an add-on takes effect
  at the next run. An agent missing its role's required add-ons starts no task.

## Approvals

Each tool call that reaches the Town Hall gets a category: `read`, `write`, `command`,
`network`, `mcp`, or `outside_workspace` (a file outside the task's worktree, or a Codex request
for access outside it). The approval mode, read at every call, decides which pass unasked:

| Mode | Passes without asking | Available |
|---|---|---|
| Ask Every Time | nothing | from the start |
| Trusted Edits (the default) | reads and writes | from the start |
| Plan First (Claude Code only) | reads; Claude Code starts in plan mode, and its plan, then each edit and command, asks | from the start |
| Free Hand | reads, writes and commands | Age IV and rank B; the game cannot advance the age yet |

- **Always asks.** `outside_workspace` asks in every mode and can be allowed only once. No mode
  passes network or MCP calls; only a rule can.
- **Risk.** Reads and writes are low risk; commands, network and MCP calls medium; anything
  outside the work folder high. So is a command matching a few text patterns (`rm -rf`,
  `Remove-Item -Recurse`, `git push`, `git reset --hard`, `git clean`, `git checkout --`,
  `git stash`, a download piped into a shell, `format` of a drive, `sudo`), and a Codex request
  the Town Hall cannot pin down (a malformed host, an unknown MCP tool, network and files at once).
- **What high risk limits.** Only "Allow once" is offered, so no rule comes from it. It does not
  make a call ask: Free Hand passes a high-risk command, and a rule that matches one applies.
- **Rules.** "Allow for this task" and "Always for the agent" store a rule for every attempt at
  that task, or for all of the agent's tasks. It matches the tool, the category and a signature:
  a command's first two words, a network request's host, otherwise the tool name. A rule for
  `npm test` thus also passes `npm test && <anything>`. Rules cannot be listed or withdrawn yet.
- **Answers.** The first reply wins; a run that pauses or is cancelled withdraws its open
  approvals as denials. Each shows a summary, the redacted input (4 KB at most) and its reason.

## How each harness is held to this

The launch lines and the reasons for each flag are in [spikes.md](spikes.md), section S5.

- **Claude Code.** `--setting-sources ""` loads none of your user, project or local settings, so
  their allow rules and hooks cannot run tools past the Town Hall. `--settings` with
  `{"permissions":{"ask":["*"]}}` makes every call prompt, reads included. `--strict-mcp-config`
  limits MCP to the run's `mcp.json`: the approval server, the agent's Waygates and a party
  lead's `town` server. `--permission-prompt-tool mcp__aurelhaven__approve` sends each prompt to
  `approval-mcp.mjs`, which forwards it to a per-run listener on 127.0.0.1 (`POST /approve` with a
  random bearer secret); any failure is a deny. The agent's own calls to that tool, and Waygate
  tools outside `allowed_tools`, are denied without asking; a lead's `town` tools pass without a
  card. `--permission-mode` is `manual` (`plan` under Plan First); an approval may wait 7 days.
- **Codex.** `codex app-server` with `approvalPolicy: "untrusted"` asks about every command
  outside its known-safe list, every file edit, every request for more access and every Waygate
  tool call. A request for more access is parsed in full: anything not understood is declined,
  and an allowed one grants exactly what was understood, for one turn. Apps, plugins, multiple
  agents, browser and computer use and image generation are switched off. The worktree is
  marked `trust_level = "untrusted"`, so a repository's `.codex` config does not load.
- **pi.** `pi --mode rpc --no-approve` (pi then ignores the project's own pi settings, extensions
  and skills), with `--tools` from the add-ons and the gate, `-e aurelhaven-gate.ts`, which turns
  every tool call, built-in or from an extension, into an `aurelhaven:approval` dialog that the
  Town Hall answers. A denial, a missing dialog channel or an unreadable answer blocks the call.
  Dialogs from other extensions are dismissed.

## Work folders

You choose an agent's work folder when you summon it. The path guard
(`townhall/src/security/path-guard.ts`) refuses a relative, network (UNC) or device path. On the
real path, with links and junctions resolved, it then refuses a missing folder or a file; a
drive root or your home folder itself; a system folder or anything in it (such as `C:\Windows`,
`Program Files`, `ProgramData`, `/etc`, `/usr` or `/System`); the Town Hall's data folder,
anything in it or anything containing it; and anything outside the work roots.

**Work roots** come from `AURELHAVEN_WORK_ROOTS`, separated by `;` on Windows and `:` elsewhere.
By default they are your home folder and, on Windows, every other drive letter that exists. A
folder inside `.git` is refused too, and a git repository needs at least one commit. While the
agent works, "the work folder" in approvals means the task's whole worktree, even when you chose
a subfolder of the repository.

## Your files

- **A worktree per task.** In a git repository each task works in a worktree under `<data>/wt/`
  on a branch `agentempire/<agent>/<task>`, locked with `git worktree lock`. When the agent
  finishes, the Town Hall commits everything there except nested repositories as "AgentEmpire
  Town Hall", running no hook (see [The Town Hall's git](#the-town-halls-git)); the review shows
  that commit's changes.
- **Merging.** A merge on acceptance needs a checkout with no changes to tracked files (changes
  inside submodules do not count), on the branch it was on when the task started, and no
  conflict in `git merge-tree`. The Town Hall then runs `git merge --no-ff` (as you, or as itself
  when git has no `user.email`), removes the worktree without force and deletes the branch with
  `git branch -d`; a merge that still fails is aborted. A blocked merge leaves the task in review
  with a `merge_blocked` incident: fix the cause and accept again, or keep the branch, which
  removes only the worktree.
- **Plain folders** (not in git) go through a versioned copy under `<data>/mirrors/`, without
  symbolic links and without `.git` in any spelling Windows may take for it (any case, trailing
  dots or spaces, `GIT~1`), so nothing is copied into the copy's own git folder. The copy holds
  up to 20,000 files and 200 MB (`AURELHAVEN_PLAIN_MAX_FILES`, `AURELHAVEN_PLAIN_MAX_MB`).
  Exporting on accept is all-or-nothing: if a file the task changed has also changed in your
  folder since the task started, nothing is written.
- **Discarding.** Abandoned, cancelled and failed work stays until you discard it, which commits
  what is left, saves the branch tip as `refs/agentempire/archive/<task>`, and only then removes
  the worktree and the branch. `git branch <name> refs/agentempire/archive/<task>` restores it.
- **Practice agents** use the same workspaces: their worktrees, branches and merges are real.
- **No destructive git.** Every git command the Town Hall runs passes `assertSafeGitArgs`
  (`townhall/src/core/workspace.ts`), which refuses `stash`, `clean`, `reset --hard` and a forced
  `worktree remove` or `checkout`. `townhall/test/unit/banned-git.test.ts` scans the `.ts`,
  `.js`, `.mjs` and `.json` files in `townhall/src/` and `townhall/scripts/`, except the guard
  itself, for a forced `worktree remove`, `reset --hard`, a quoted `--hard` or `--force`, and
  `clean` or `stash` as git commands, and checks the run-time refusals. It does not scan the
  tests, and git commands an agent runs are left to approvals.

## The Town Hall's git

A worktree is the agent's to write in, its `.git` file included, and git takes commands to run
from files: a config's fsmonitor command, filters and diff programs, and hooks. A repository the
agent planted could thus make the Town Hall's own git, which runs with your rights and asks no
one, run what the agent chose. So:

- **Settings on every command.** Each git command the Town Hall runs (in a worktree, in your
  checkout or in a plain folder's copy) begins with `-c core.fsmonitor=false`,
  `-c core.hooksPath=<data>/no-hooks`, `-c protocol.ext.allow=never` and
  `-c submodule.recurse=false`. Settings on the command line win over every config file, and git
  passes them on to the git processes it starts itself. So no fsmonitor command or hook runs,
  yours included: a new worktree gets no `post-checkout` hook, and a merge on acceptance no
  `post-merge` hook. `no-hooks` is an empty folder outside every worktree; while anything is in
  it, the Town Hall runs no git. Every diff passes
  `--no-ext-diff --no-textconv --submodule=short`, and each status, and each diff against a
  worktree's files, `--ignore-submodules=all`, so that git never runs inside a submodule.
- **A worktree's `.git`.** Before it runs git in a worktree, the Town Hall checks that `.git` is
  still a plain file (not a folder or a link) naming the folder that `git worktree add` made for
  the worktree in the repository's `.git/worktrees/`, and that this folder names the worktree
  back. It then gives git that folder and the worktree on every command (`--git-dir`,
  `--work-tree`), so git never reads `.git` itself, even if it changes in the meantime. If the
  check fails, the task fails with "the work folder's .git was changed", and the review and the
  discard refuse for the same reason; delete the worktree folder to discard the task.
- **Nested repositories.** A folder in a worktree that holds a repository of its own, untracked
  or a submodule the agent filled in, stays out of the Town Hall's commits along with its files,
  and the Chronicle names it after the snapshot: `git add` would record the first as a bare
  commit id and run `git status` inside the second, under the configuration the agent wrote
  there. Such a worktree is not clean, so accepting the task leaves it in place.

## Spending

1 Mana is $0.01 of real usage; on a subscription it is what the same usage would cost on the
API, marked as an estimate.

- **Pool and seal.** The pool is $5 a day by default, refilled at local midnight; F4 sets the
  amount and the period (day, week or month), and raising it mid-period needs a confirmation.
  Unused Mana does not carry over. Each task has its own cap, its seal: by default 40, 150, 450
  or 1,200 Mana for sizes S, M, L and XL, or the amount set on the task.
- **Reservations and overdraft.** A task starts only when free Mana covers a quarter of what is
  left of its seal, and at least $0.05; it then reserves the rest of its seal as far as free Mana
  allows. Usage beyond the pool is overdraft, taken off the next period's pool.
- **Pauses.** A task warns at 80% of its seal and pauses at 100%, for you to extend the seal or
  stop and review. With 2% of the pool left or less, every run pauses until Mana is back. A run
  silent for 15 minutes pauses too (waiting for you or for party members does not count).
- **Measured after the fact.** Claude Code reports its running cost, pi each message's cost, and
  Codex its tokens, priced with `protocol/pricing.json`; usage that pi reports without a price
  costs nothing. A task pauses on the report that crosses its seal and has 10 seconds to stop
  before it is killed, so it can end slightly over.
- **Backstop.** Claude Code gets `--max-budget-usd`: its session's restored total, plus 1.1 times
  what is left of the seal, plus $0.01; the task fails if it stops there. Codex and pi have none.
- **Provider usage limits.** A run stopped by its provider's usage limit pauses (`provider_limit`)
  and lights the Font Dark incident; you resume it. F4 shows the usage windows harnesses report.

## Secrets

- **Redaction.** `townhall/src/security/redact.ts` blanks known key formats (private keys,
  `sk-ant-` and `sk-` keys, GitHub, Slack, AWS and Google keys, JSON web tokens), `Bearer` and
  `Basic` credentials, values after names such as `api_key`, `token` or `password`, the values of
  `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CODEX_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`,
  `GITHUB_TOKEN` and `GH_TOKEN`, and the session token, in activity, approvals, incidents, task
  summaries, harness errors and Rite output. The log censors `token`, `headers.authorization`
  and `env` fields. The diff you review is shown as it is.
- **Waygate secrets** are named, never stored: `env_refs` and `header_refs` name environment
  variables that the harness expands. A config that looks like it holds a secret is refused.
- **The approval channel's secret**, 32 random bytes per run, is only in the run's `mcp.json`
  (under `<data>/harness/claude/`, deleted after the run) and the approval server's environment,
  never on a command line or in Claude Code's environment; the agent's shell does not inherit it.
- **Sign-in checks** report only whether and how a harness is signed in, never an email or a key.

## Processes

- **No shell.** Harnesses start directly (an npm `.cmd` shim is followed to its program), with no
  console window on Windows and in a process group of their own elsewhere.
- **Ending process trees.** A stop asks the harness first (Claude Code's interrupt, Codex's
  `turn/interrupt`, pi's `abort`), closes its input, then ends the tree: `taskkill /T` from
  `System32`, then with `/F`, on Windows; `SIGTERM`, then `SIGKILL`, to the group elsewhere. A
  stop still running after 10 seconds kills the tree. An exited process is never signalled again.
- **The Rite**, a task's optional check command, is yours: it runs through the system shell in
  the worktree with the Town Hall's environment, killed after 600 s (`AURELHAVEN_RITE_TIMEOUT_S`).
- **Shutdown.** On Ctrl+C, `SIGTERM`, `SIGBREAK` or the `shutdown` command the Town Hall refuses
  new connections, ends every run's tree at once, leaving its task as it was, and removes its
  runtime files. If the Town Hall dies instead, the harnesses see their input close and finish.
- **The next start.** A Town Hall refuses a data folder another running one uses. Live runs
  become paused (`restart`) and release their Mana; waiting approvals return, marked orphaned. A
  task without one resumes its session first in its agent's queue. An answer to an orphaned
  approval covers that exact call once, within 10 minutes; resuming unanswered lets it ask again.

## Known limits

The first four are also described in [spikes.md](spikes.md), section S5.

- **Calls that never ask, in any mode.** Codex's known-safe read-only commands (`ls`, `cat`, `rg`,
  `Get-Content`, `git status` and the like) and its web search, which runs on the provider's
  side; and Claude Code's `EndConversation` tool, which only ends the conversation.
- **Your harness configuration still loads.** Codex reads your `~/.codex/config.toml`: its
  service tier, `notify` command, hooks and MCP servers apply, and the agent can use those
  servers without a Waygate, under their own approval mode. pi loads your user-level extensions;
  their tool calls still go through the gate.
- **No Waygates or Rookery on pi.** pi 0.87.1 (pinned in `townhall/package.json`) cannot add MCP
  servers, so a pi agent skips its Waygates with a warning; pi has no web search or fetch tool.
- **Leftover programs.** A program an agent starts that outlives its harness (a dev server, a
  build server) keeps running: ending a tree reaches only the processes of a running harness.
- **No sandbox on Claude Code and pi.** Their approved commands run with your rights and can read
  `runtime.json`, any key in the environment the harnesses inherit (the Town Hall's, minus a
  parent agent session's markers, so your Waygates' variables too), and anything else you can.
- **The path check is textual.** It resolves a tool's `file_path` or `path` against the working
  folder as written, without following symbolic links. pi's file tools expand `~/`, drop a
  leading `@` and accept `file://` URLs, so such a path counts as inside the work folder, and
  under Trusted Edits a pi agent reads or writes it without asking.
- **Worktrees share `.git`.** Git commands an agent runs reach the repository's branches, tags,
  configuration and hooks; only the approval of each command stands in the way. The Town Hall's
  own git then runs none of those hooks, no fsmonitor command and no external diff or textconv,
  but it still applies the filters and merge drivers configured there, which Git LFS needs.
- **Nested repositories stay out.** Work in a folder with a repository of its own (a project the
  agent made with `git init`, a submodule it updated) is not in the snapshot, the review or the
  merge.
- **The Rite runs the agent's version.** It runs without asking after the agent finishes, so if
  the agent changed what it runs (a `package.json` script, a test), that code runs too.
- **Free Hand outside Codex.** Its "network off" relies on Codex's sandbox; on Claude Code and
  pi it would let commands run unasked, with your rights and the network. No town has it yet.
