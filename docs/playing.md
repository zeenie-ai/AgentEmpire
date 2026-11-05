# Playing AgentEmpire

How the game works once it runs. [README.md](../README.md) covers the download, the first start,
real agents and the controls; [security.md](security.md) explains what keeps real agents in check.
The numbers are the game's defaults, most of them from `protocol/economy.json`.

## The idea

AgentEmpire plays like Age of Empires, with townsfolk who gather and build around the Keep, but
its agents are real coding agents (Claude Code, Codex or pi) working in folders on your computer.
Each builds its own home and add-ons, townsfolk carry it your tasks as scrolls, a bell rings when
it wants to do something only you may allow, and you review its work before you accept it.
Accepted work pays the town and earns the agent experience. The real part runs in the
**Town Hall**, a small service the game starts beside itself, with practice agents (a scripted
stand-in that spends no money) or real ones; each has its own town.

## The town

Townsfolk gather **Food** from berry bushes and farms and **Wood** from trees; **Stone** and
**Gold** come only as rewards for accepted work. A new town has 200 Food, 200 Wood, 150 Stone,
100 Gold and three townsfolk. Food and Wood are stored up to 800 each in the first age, plus 300
for each Storehouse; gathering past that is lost, rewards never are.

- **Buildings.** The Keep trains townsfolk (50 Food and 20 seconds each, five queued at most) and
  summons agents. Townsfolk build Cottages (30 Wood, +5 population), Farms (40 Wood, Food without
  end for one worker) and Storehouses (100 Wood, a drop-off and 300 more storage). More builders
  finish sooner; cancelling a site refunds everything, dismantling a building refunds half.
- **Gathering.** Idle townsfolk start gathering by themselves: whichever of Food and Wood is
  lower, or what the Keep's **Gather Focus** names. Each carries 10 at a time to the Keep or a
  Storehouse, and bushes and trees grow back.
- **Population.** The Keep gives 10 and each Cottage 5, up to 25 in the first age. A townsperson
  counts 1 and an agent 2; training pauses at the cap.
- **No dead ends.** With no townsfolk and under 50 Food, free wanderers come until there are two.

## Agents

### Summoning

Select the Keep (H) and press **Summon** (W). The Summoning Font asks for:

| Field | What to give |
|---|---|
| Harness | Claude Code, Codex or pi; each card shows its version, whether it is Ready, Not logged in or Not installed, and its billing |
| Model | One from the harness's list, with cost hints; type an id when it lists none (pi: `<provider>/<model>`) |
| Name | Up to 40 letters; the dice offers another |
| Role | The agent's work, home and required add-ons (see Roles) |
| Oath | Standing instructions it reads before every task, written for the role; edit freely |
| Work folder | Required: the only folder it may work in. **Browse...** marks git repositories |
| Approval mode | Which of its actions ask you first (see [Approvals](#approvals)) |
| Starting add-ons | The role's required add-ons, plus others up to the age's slots |
| Show advanced | The Mana seal for each task size, and a billing override |

- **Cost.** Each role costs Food and Gold, 20% more for every agent already in town. The agent is
  paid now, its home when placed and each add-on when built; the side column adds it all up.
- **Font's Grace.** While the town has no agent, the next one is free, and so are its home and
  its required add-ons.
- **Limits.** Two agents in the first age. An agent's model, oath, approval mode and seals cannot
  be changed after summoning yet.
- **Work folder.** In your home folder or, on Windows, on a drive other than the system drive. A
  git repository needs a commit; a plain folder is copied (20,000 files or 200 MB at most).

### Training, the plot and the home

1. The agent trains at the Keep for 35 to 50 seconds; cancelling it then (select the Keep, then
   **Cancel**) refunds it in full.
2. Choose its 7 x 7 plot, the home in the middle and its add-ons around it, on clear ground in the
   build zone away from the Keep and other plots. **Plot** (T) on its card picks one later.
3. It builds the home (paid when placed), then its starting add-ons, required ones first, waiting
   when the treasury is short. Once its home and required add-ons stand and its work folder is
   ready, it takes tasks.

### Roles

| Role | Work | Home | Required add-ons |
|---|---|---|---|
| Artificer | Coding | Workshop | Lectern, Quillworks |
| Scholar | Research | Observatory | Lectern, Rookery |
| Scribe | Writing and docs | Scriptorium | Lectern, Quillworks |

The Warden (review and testing; Lectern and Forge) comes with the Market Age and the Herald (ops
and automation; Lectern, Forge and Waygate) with the Guild Age; the town cannot reach either yet.

### Add-ons

Each add-on is a small building on the plot that grants one kind of tool, and an agent has no tool
its add-ons do not grant. A home holds four in the first age: add them from the middle row of the
agent's command card, or **Dismantle** one (B) for half its cost. Without its required add-ons an
agent is blocked.

| Add-on | Grants | Notes |
|---|---|---|
| Lectern | Reading and searching files | Codex: a read-only sandbox |
| Quillworks | Writing and editing files | Needs a Lectern. Codex: a sandbox that may write in the work folder |
| Forge | Shell commands | Needs a Lectern |
| Rookery | Web search and fetch | Codex gets web search; pi has no web tools, so it gains nothing |
| Archive | The project's own instruction files and skills, such as `CLAUDE.md` or `AGENTS.md` | Without one, agents ignore them; raises rewards |
| Waygate | An MCP server | From the Market Age; no window to set one up yet |

### Ranks and experience

An accepted task gives its agent as many XP as its reward points (RP); level L takes
50 x L x (L - 1) XP, up to level 30. Ranks run from F to S, each needing more XP and accepted
tasks (E: 150 XP and 2 tasks; S: 22,000 and 120) and, from D up, a share of tasks accepted on the
first try over the last 20. C also needs two passing Rites, B Mana use at or under the usual for
the role and size, A party tasks and S the Curtain Age. The rank is worked out after every reward
and can fall. What ranks unlock (party leads from E, Free Hand at B) needs later ages.

## Tasks

### Writing a task

Select an agent (its figure or its home) and press **Task** (Q) for the Quest Scroll:

| Field | What to give |
|---|---|
| Title | Required, up to 200 characters |
| The quest | Required, up to 32,000 characters: what needs doing, where, and how you will know it is done |
| Size | Errand (S), Quest (M), Expedition (L) or Campaign (XL): the base bounty and the Mana seal, 40, 150, 450 or 1,200 Mana unless changed at the Font |
| Acceptance criteria | Optional, up to 20: what must be true when the work is done; the agent checks each one |
| Rite | Optional check command, such as `npm test`, that the Town Hall runs in the agent's workspace when the work is done (for up to 10 minutes, without asking). A pass raises the reward; the output appears in the review |

There is no separate budget: the size picks the seal. **Send the scroll** (Ctrl+Enter) sends it.
The scroll warns when the Mana pool holds less than a quarter of the seal; the task then waits
until there is enough. A home holds one waiting scroll in the first age, besides the task in hand.

### The scroll's journey

1. **A courier**, the nearest idle townsperson or else the nearest gatherer (never a builder),
   walks the scroll from the Keep to the home. To choose one, select townsfolk and right-click the
   agent's home: they take its oldest scroll still on the way, or the next one you send.
2. **A Font Wisp** flies the scroll about 20 seconds after you sent it when no townsperson is
   free, and takes over from a courier who cannot get through.
3. **The time-out.** 90 seconds after you sent it, the Town Hall delivers a scroll still on its
   way by itself, unless the Mana pool is at 10% or less.
4. **Express** skips the walk: the scroll appears at the home at once. Either way the work starts
   when the agent is free and the Mana pool allows it.

### The task tracker

The task tracker at the top left, under the top bar, lists the town's tasks under way and hides
while there are none, and while the Town Hall is closed. Each row shows the task's seal, an animated emblem for its state, then its
title, then the agent and the state in the state's colour. When the state changes, the seal fades
into the new one with a small pop.

| Seal | Means |
|---|---|
| A scroll with speed lines | On its way |
| A scroll with three dots | In the queue |
| Cogs | Preparing |
| A hammer on an anvil | At work |
| A ringing bell | A petition waits for you |
| A chest | A result waits for review |
| A stamp on a wax seal | The work is being accepted |
| Two bars | Paused; the row says why |
| An exclamation mark | Failed |
| A check, a cross or a struck ring | Accepted, set aside or cancelled |

- **Order.** What needs you comes first: petitions, results to review, failures and pauses, then
  work, the queue and scrolls on their way. Within each, the oldest comes first. At most five rows
  show; a plate below counts the rest.
- **Finished tasks** keep their row, at the top with the final seal, for six seconds. A party
  member's sub-task has no row of its own: its lead's task stands for it.
- **A click** on a row does what the task needs. A result opens the review. A petition opens in
  the tray and the camera goes to the agent's home. Any other row selects the agent's home and
  moves the camera to it.
- **Folding.** A click on the header (TASKS and the count of tasks under way) folds the list
  away; another click unfolds it. The game remembers the fold.

### While the agent works

| At the home | Means |
|---|---|
| A warm light at an add-on, the agent beside it | It uses that add-on's tool: the Forge for a command, the Quillworks for an edit |
| The bell swinging on the post by the door, a banner raised | An approval waits (a blue banner: the task has spent its seal) |
| A glowing chest at the door | A result waits for review |
| Smoke from the roof | A task failed |
| A red "!" floating over the roof | Blocked: a required add-on is missing, there is not enough Mana to start, the harness is offline, or the work folder has a problem |

The name plate over the roof carries the agent's sigil, a small animated gem whose colour and
motion follow its mood: waiting for you, a result ready, trouble, working, settling in, retired or
idle. Beside the sigil are its name and a caption: what needs you (NEEDS YOUR APPROVAL, RESULT
READY, TASK FAILED, PAUSED, BLOCKED, NEEDS RESOURCES), WORKING or STARTING, SETTLING IN, or the
role and rank. The agent's panel has a status line led by the same sigil ("Working: using Bash at
the Forge"; click it for the review or the approvals), the task's Mana and the add-ons. The plate
and the panel always show the same status, and what needs you comes first, in the task tracker's
order: a petition, a result to review, a failed task, a paused one; then the work.

- **Trouble.** An alarm bell rings when an agent goes quiet or repeats itself, and a task silent
  for 15 minutes pauses. A broken link to the harness is retried once; other errors fail the task.
- **Your controls.** **Resume** (Z) restarts a paused or failed task. **Cancel** (X) stops the
  current or a waiting task with no reward, keeping its work. **Retire** (B) cancels the waiting
  scrolls, lets the current task finish, then sends the agent away with its home and add-ons.

## Approvals

When an agent asks for something its approval mode does not allow, the bell at its home rings, a
toast names the request and a petition joins the tray at the top right, oldest first. The task's
row in the task tracker shows a ringing bell and moves up to the petitions at the top; a click on
it opens the petition and finds the agent. **Space** jumps to the agent that has waited longest,
then the next. A petition shows the kind of request (Read, Write, Command, Network, Outside
workspace or MCP tool), the risk, the agent's reason and the request itself. The agent waits for
your answer, however long it takes.

Answer with **Allow once**; **Allow for this task**, for requests like it until the task ends;
**Always for** the agent, for requests like it on all its tasks from now on; or **Deny**, with a
word to the agent if you like.

- **Like it** means the same tool and, for a command, the same first two words (`npm test`); for
  a web request, the same host. A rule covers every command that starts with those two words,
  whatever follows them, so keep command rules narrow.
- **High risk.** Files outside the work folder ask in every mode. They, and commands that can
  destroy work or reach far (`rm -rf`, `git push`, `git reset --hard`, `sudo`, a download piped
  into a shell), get only **Allow once** and **Deny**; an earlier rule still covers a command with
  the same first two words. The Town Hall sees where a file tool reaches, not where a shell command
  reaches, so read commands before you allow them.
- **Network requests and MCP tools** ask in every mode unless a rule covers them.

| Approval mode | Asks first about | For |
|---|---|---|
| Ask Every Time | Everything | Every agent |
| Trusted Edits (default) | Everything except reading and changing files inside the work folder | Every agent |
| Plan First | Everything except reading; the agent first shows you its plan | Claude Code agents |
| Free Hand | Only network requests, MCP tools and files outside the work folder | Rank B in the Curtain Age, so not yet |

## Review

When a task is done, a toast says so and a chest glows at the home. Open the review with
**Review** (W) on the agent's card, by clicking its status line, or by clicking the task's row in
the task tracker. It shows the agent's summary, your acceptance criteria, the changed files and
the patch, the Rite's result and output, the Mana used (marked "about" when estimated) and the
**Chronicle**, everything the agent said and did.

- **Accept** pays the reward and integrates the work in one of three ways:
  - **Merge**, the default for a git repository, makes a merge commit on your checkout's branch.
    Each task works in its own git worktree on a branch `agentempire/<agent>/<task>`, started
    from your last commit (uncommitted changes are not part of it). The merge runs only when your
    checkout has no uncommitted changes to tracked files, is on the branch the task started from,
    and does not conflict with the work. Otherwise nothing changes and the window says why: fix
    it and **Try again**, or **Keep branch instead**.
  - **Keep branch** leaves your checkout alone and the work on its branch, to merge later.
  - **Export**, for a plain folder, writes the changed, new and deleted files from the Town
    Hall's copy back, all or nothing: if any changed in your folder meanwhile, nothing is written.
- **Send back** needs notes. The agent starts a new attempt from them, ahead of its other work;
  Mana already spent still counts against the seal, and the first-try bonus shrinks.
- **Abandon** sets the task aside with no reward. Its work is kept; no button discards it yet.

**The reward** is counted in reward points (RP), paid as resources split by the agent's role (an
Artificer pays mostly Gold and Stone, a Scholar mostly Gold) and as the same number of XP:

- **Base and bonuses.** 60, 180, 450 or 1,000 by size; +50% when accepted on the first attempt
  (+20% on the second), up to +30% for using less Mana than usual for the role and size, and +10%
  each for an Archive, all the role's recommended add-ons and a passing Rite.
- **Limits.** Halved once the town has been rewarded for 12 Errands, 8 Quests, 4 Expeditions or 2
  Campaigns in 24 hours; never more than 20 RP for each Mana used, or 60 if that is more.
- **Nothing** for the same title and quest as a task rewarded in the last 24 hours, for no
  deliverable (no changed files and, without a Quillworks, no summary either), or for a run under
  30 seconds.

## Mana

Mana is your real budget: 1 Mana is $0.01 of model usage, counted by the Town Hall as agents
work. Resources never buy Mana, Mana never buys resources, and your own actions never cost any.
The orb in the top bar shows what is left; click it or press F4 for the budget window.

- **The budget window** shows the pool, what is spent, reserved by running tasks and left, the
  spend by harness and the harnesses' own usage windows. It sets the period (daily, weekly or
  monthly), the pool in dollars ($5 a day to start) and each harness's billing: on a subscription
  Mana is estimated from tokens, with an API key it is exact.
- **The Dawn Bell** rings when the pool refills: at local midnight, on Mondays for a weekly pool,
  on the 1st for a monthly one. Unused Mana does not carry over; usage past the pool comes off the
  next one. Raising the pool in the middle of a period asks you to confirm.
- **Seals.** A task's seal is the most it may spend. It starts only when the free Mana covers a
  quarter of what is left of its seal (5 Mana at least), and the rest is then reserved. A task
  that spends its whole seal pauses and the hand bell rings. The Town Hall can extend a seal or
  stop the task for review, but the game has no buttons for these yet and refuses **Resume**
  while the seal is spent, so give seals room at the Font.

| Mana left | What happens |
|---|---|
| 25% | The lanterns dim: a toast and a sound, and the orb turns amber |
| 10% | The warning bell rings; the Town Hall stops delivering forgotten scrolls itself |
| 2% | The Font goes dark: running tasks pause and none starts. They resume by themselves when the pool refills or you raise it |

**Provider usage limits.** The budget window also shows the usage windows Claude Code and Codex
report, and when each resets; a task that hits one pauses until you **Resume** it.

## Practice and real towns

The chip in the top bar reads **PRACTICE TOWN** or **TOWN HALL** (real agents); a click opens its
menu. **TOWN HALL OFFLINE** means no Town Hall runs (a click starts it again), and
**OPEN TOWN HALL TOWN** that one runs while you play an offline town (a click opens its town).

- **Switching.** Choose **Practice agents** or **Real agents** in the menu and confirm. The game
  saves the town, closes the Town Hall (its agents pause until it runs again), starts the other
  one and opens its town. Each town has its own agents, treasury and Mana.
- **Closing.** **Close the Town Hall** saves the town and stops the Town Hall, and you play on
  offline. Its agents pick up where they left off when it runs again; a task that was waiting for
  your answer shows as paused instead, and asks again after **Resume**.
- **Quitting.** Closing the game saves the town and leaves the Town Hall running: agents finish
  their tasks and start the waiting ones, and their requests wait for you.
- **Practice agents** stand in for all three harnesses and spend a few Mana, never money. One
  writes a small note in its copy of the work folder and finishes at once, so accepting puts the
  note into your folder: give it a scratch folder. It asks nothing under Trusted Edits (choose Ask
  Every Time to practise approvals), and its runs are usually too short to earn a reward.

## Saving

- **A Town Hall's town** saves to the Town Hall every minute; soon after you summon an agent or
  place its home, or an agent finishes its home or an add-on; before the Town Hall is switched or
  closed; and when you quit. F5 saves at once; F9 does nothing there. The Town Hall records
  agents, tasks, approvals, Mana and the treasury as they happen; the save holds the town around
  them: the map, townsfolk and buildings.
- **An offline town** has no agents. F5 saves it to one slot, `saves/quick.json` in the game's
  user folder (`%APPDATA%\Godot\app_userdata\AgentEmpire` on Windows), and F9 loads it.

## Not in the game yet

- **Ages.** The walls stand and later rings' lines are kept clear, but nothing advances the age:
  the town stays in the Founding Age, with two agents, four add-ons and one waiting scroll a home.
- **The Quartermaster's trades** (Food and Wood for Stone and Gold, and back): Town Hall only.
- **Parties**, agents working under a Claude Code lead from the Market Age: Town Hall only.
- **Menus and onboarding.** Esc only cancels or closes the top window; there is no menu or tutorial.
- **A quest log.** The task tracker lists only the tasks under way, plus a finished one for six
  seconds; there is no list of past tasks.
