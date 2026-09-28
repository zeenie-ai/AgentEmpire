class_name Palette
extends RefCounted
## Scene colours from the design handoff (design_handoff_aurelhaven/README.md and
## city-scene.js). UI colours live in UiTokens.

const STONE := Color("#cdbb9a")
const STONE_DARK := Color("#b8a17c")
const TERRACOTTA := Color("#a8472b")
const TERRACOTTA_DARK := Color("#8f3b25")
const SLATE := Color("#2f4d7a")
const GRASS := Color("#8d9a5b")
const DAWN := Color("#f2b98c")
const NIGHT := Color("#0d1230")
const HOUSE_WALL := Color("#efe2c6")
const GOLD := Color("#e0b560")
const GOLD_BRIGHT := Color("#ffd27a")
const GOLD_DEEP := Color("#d9a441")
const WINDOW_GLOW := Color("#ffb14a")
const MINT := Color("#a9f0d0")
const INK := Color("#3b2a1e")
const WOOD := Color("#8a5a3a")
const WOOD_DARK := Color("#6f4a3a")
const WOOD_LIGHT := Color("#b08a5a")
const TRUNK := Color("#6b4a2e")
const LEAF := Color("#5f7f3f")
const LEAF_DARK := Color("#4f6f3a")
const LEAF_LIGHT := Color("#7f9a52")
const BUSH := Color("#5c7a3e")
const BERRY := Color("#b8324a")
const ROCK := Color("#8a8f86")
const SOIL := Color("#7a5536")
const SOIL_LIGHT := Color("#8e6843")
const CROP := Color("#9aa564")
const SKIN := Color("#e8c39e")
const LEATHER := Color("#4a3322")
const SUN := Color("#ffc78f")
const SUN_NIGHT := Color("#7f95ff")
const HEMI_SKY := Color("#ffe9cf")
const HEMI_GROUND := Color("#5a4a36")
const FOREST_FLOOR := Color("#76844d")
const PLAZA := Color("#b8a17c")

const TUNICS: Array[Color] = [Color("#8f3b25"), Color("#4f6a8a"), Color("#7a6a3a"), Color("#4f6f5a")]
const HAIR: Array[Color] = [Color("#4a3322"), Color("#2a1d14"), Color("#b08a4a"), Color("#8f3b25")]

## Resource colours for icons, the minimap and floating text.
const RESOURCES := {
	"food": Color("#d0583f"),
	"wood": Color("#a06a3a"),
	"stone": Color("#b3ab9a"),
	"gold": Color("#e0b560"),
}


static func resource(res: String) -> Color:
	return RESOURCES.get(res, Color.WHITE)
