# AgentEmpire store listing (en-US)

The Google Play main store listing for release 1, the offline town on phones and tablets. It
describes only what the Android app does, plus one line about the PC version. Paste each block
as it is. Counts are characters as Play counts them, spaces and line breaks included.

## Title (11 of 30)

```text
AgentEmpire
```

The same name as in the Create app dialog. With a descriptor, if the owner wants one later:
`AgentEmpire: Town Builder` (25 of 30).

## Short description (78 of 80)

```text
A calm town builder: gather food and wood, build cottages and train townsfolk.
```

Alternative (76 of 80): `Gather food and wood, build cottages and farms, and grow a town of your own.`

## Full description (1,820 of 4,000)

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

On PC, AgentEmpire goes further: the villagers you summon at the Keep are real AI coding agents, and the town grows on the work you accept.
```

## Before submitting

Every line describes the release 1 build. Check these against the release candidate, since each
comes from one stream's work:

| Claim | From |
|---|---|
| Bushes and trees grow back; cottages, farms and storehouses; training, rally points; the walled Keep | `protocol/economy.json` and today's game |
| The Idle button and the Select toggle | stream D (the phone HUD) |
| Tap to select and order, drag, pinch, twist, placing a building and tapping Build | stream C (touch input) |
| Back closes windows, clears the selection, then opens the menu | stream F (the Back chain) |
| Save, load, new town on a fresh map, graphics, sound and How to play in the menu | stream F (the game menu) |
| Saves itself on leaving and resumes on return | stream B (autosave and resume) |
| Offline, no account, no ads, no purchases, no data | stream A's manifest (no Internet permission, no SDKs) |

The texts avoid what Play's metadata rules forbid in a listing: no other games' names, no
rankings, prices or calls to action, and no emoji.
