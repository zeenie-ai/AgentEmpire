class_name SimConst
extends RefCounted
## Client-side simulation tuning that is not part of the shared economy: movement feel, reach,
## state names. Economy numbers (costs, rates, radii, caps) come from EconomyData only.

## Version of SimWorld.to_dict(); bump when the snapshot layout changes (save_town uses it).
## 2: agents (unit role and state, home plots, add-on tool ids) and Font Wisps.
const SCHEMA_VERSION := 2

# Unit jobs.
const JOB_IDLE := "idle"
const JOB_MOVE := "move"
const JOB_GATHER := "gather"
const JOB_BUILD := "build"
const JOB_DEPOSIT := "deposit"
## Townsfolk carrying a task scroll from the Keep to an agent's home.
const JOB_COURIER := "courier"
## An agent at home: working at its add-ons, waiting at the door, or pottering about its plot.
const JOB_AGENT := "agent"

# Path request states.
const PATH_NONE := 0
const PATH_PENDING := 1
const PATH_READY := 2
const PATH_DONE := 3
const PATH_FAILED := 4

# Path goal modes.
## Walk onto the cell, or to a free cell on its edge when it is solid.
const GOAL_CELL := 0
## Walk to a free cell on the edge of a solid rect (resource nodes, buildings, sites).
const GOAL_ADJACENT := 1
## Walk into a walkable rect (farms).
const GOAL_INSIDE := 2

## Construction progress units per building (progress = work / WORK_SCALE).
const WORK_SCALE := 1000000

## Distance in tiles between a unit and a target rect that counts as "at" the target.
const REACH := 0.95
## Farms are worked from inside; this is the tolerance for "inside".
const INSIDE_EPS := 0.05
## Desired spacing between unit centres, in tiles.
const SEPARATION := 0.55
## Largest separation push per tick, in tiles.
const MAX_PUSH := 0.08
const HASH_CELL := 2.0

## Idle townsfolk that were not told to wait start gathering after this delay.
const AUTO_GATHER_DELAY_S := 3.0
## How often idle townsfolk retry finding work, in ticks.
const RETRY_EVERY_TICKS := 20
## How many edge cells of a solid target are tried before giving up on a path.
const MAX_EDGE_CANDIDATES := 3
const MAX_PATH_RETRIES := 3
const MAX_BAD_TARGETS := 8
## Cells searched when spreading a group move over nearby target cells.
const FORMATION_SEARCH_CELLS := 800
## Ticks without progress on a path before a unit asks for a new one.
const STUCK_TICKS := 16

## Font Wisps (spirit couriers) fly straight to the home at this speed, in tiles per second.
const WISP_SPEED := 5.0
## A wisp this close to the home's centre has arrived.
const WISP_ARRIVE := 1.6
## An agent at home with nothing to do moves to another spot of its plot this often, in ticks.
const AGENT_WANDER_TICKS := 240
## A courier this close to the Keep has the scroll already and walks straight to the home.
const COURIER_PICKUP_RANGE := 3.0
