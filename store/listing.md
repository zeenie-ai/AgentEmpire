# AgentEmpire store listing (en-US)

The Google Play main store listing for release 1, the offline town on phones and tablets. It
describes only what the Android app does, plus a closing paragraph about the PC version, which
names no other company's products. Paste each block as it is. Counts are characters as Play counts them, spaces and line breaks included.

## Title (25 of 30)

```text
AgentEmpire: Town Builder
```

The owner's choice, and the App name in the Create app dialog too (Play uses one name for both).
The phone's launcher still shows AgentEmpire. Without the descriptor: `AgentEmpire` (11 of 30).

## Short description (78 of 80)

```text
A calm town builder: gather food and wood, build cottages and train townsfolk.
```

Alternative (76 of 80): `Gather food and wood, build cottages and farms, and grow a town of your own.`

## Full description (1,931 of 4,000)

```text
Found a town in the world of Aurelhaven and grow it at your own pace.

AgentEmpire is a calm, real-time town builder. Your townsfolk gather food and wood, carry it to the Keep and your storehouses, and raise the buildings you place. You decide where the town grows, and there is no enemy to rush you.

GATHER AND BUILD
• Gather food from berry bushes and farms, and wood from the forests around the town walls. Bushes and trees grow back.
• Build cottages to house more townsfolk, farms for food that never runs out, and storehouses to shorten the walk and hold more.
• Train new townsfolk at the Keep and send them to work with a rally point.
• A tap on Idle finds the next townsperson with nothing to do.

MADE FOR TOUCH
• Tap to select. With townsfolk selected, tap a bush, a tree or a building site to put them to work.
• Drag to move around the town, pinch to zoom and twist to turn the view.
• Turn on Select, then drag a box to pick a whole group.
• Place a building where you want it, then tap Build.
• Back closes windows and clears the selection, and opens the menu when there is nothing left to close.

YOUR TOWN, SAVED
The town saves itself when you leave the game and is waiting where you left it when you come back. You can also save and load from the menu, or start a new town on a fresh map.

PLAYS OFFLINE
AgentEmpire needs no internet connection and no account. It has no ads and no in-app purchases, and it collects no data. It plays on phones and tablets in landscape, with Low, Medium and High graphics, a sound switch, and a How to play page in the menu.

The town has low-poly buildings and townsfolk, a walled Keep, music and the sounds of a working town.

On PC, AgentEmpire is also a productivity game: the villagers you summon at the Keep are real AI coding agents that you direct, and the town grows on the work you accept. This app for phones and tablets is the town builder on its own, without agents.
```

## Before submitting

Every line describes the release 1 build. Each claim was checked against the merged build (r1 at
6f4acfd); check again on the release candidate if any of these change:

| Claim | Where the build does it |
|---|---|
| Bushes and trees grow back; cottages (+5 population), farms (endless food), storehouses (drop-off and storage); townsfolk trained at the Keep | `protocol/economy.json` (`regrow_s`, the buildings, `units.townsfolk`) |
| Rally points; the walled Keep | the Keep's Rally card; the Keep Ring stands from the first age |
| Tap on Idle for the next idle townsperson | `top_bar.gd`: the Idle button calls `select_next_idle()` |
| Tap to select, tap a target to order, drag, pinch, twist, the Select toggle, placing then Build | `touch_controls.gd`, `rts_input.gd`, `select_toggle.gd`; the How to play panel says the same |
| Back closes windows, clears the selection, then opens the menu | `back_chain.gd` |
| Save, Load, New town (a random seed), Low, Medium and High graphics, Sound and How to play in the menu | `game_menu.gd` |
| Saves itself on leaving and resumes on return | `game.gd`: autosave on `NOTIFICATION_APPLICATION_PAUSED`, `resume_town()` at boot on mobile |
| Landscape | Godot's default orientation (the project sets none) |
| Offline, no account, no ads, no purchases, no data | `export_presets.cfg`: `permissions/internet=false`, no plugins or SDKs |

The texts avoid what Play's metadata rules forbid in a listing: no other games' names, no
rankings, prices or calls to action, and no emoji.
