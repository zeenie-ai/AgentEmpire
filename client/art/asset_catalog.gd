class_name AssetCatalog
extends RefCounted
## Where the processed art lives and how ModelLibrary keys map to art-manifest ids
## (art_src/manifest.json, "outputs.naming"):
## - a model with one source is res://art/models/<id>.glb; one with variants is <id>_0.glb,
##   <id>_1.glb, ... numbered from 0;
## - characters are res://art/characters/<id>.glb, icons res://art/icons/<id>.png;
## - res://art/models/anchors.json maps each model file stem to
##   {size: [x, y, z], height, door: [x, y, z], top: [x, y, z]} in model space.
## Only path logic and small caches live here; ModelLibrary does the loading. `exists` and
## `loader` can be replaced (tests, look-dev tools).

const MODELS_DIR := "res://art/models"
const CHARACTERS_DIR := "res://art/characters"
const ICONS_DIR := "res://art/icons"
const ANCHORS_PATH := "res://art/models/anchors.json"
const MAX_VARIANTS := 16

## ModelLibrary key -> manifest id.
const MODEL_IDS := {
	"building/keep": "keep",
	"building/cottage": "cottage",
	"building/farm": "farm",
	"building/storehouse": "storehouse",
	"building/workshop": "workshop",
	"building/observatory": "observatory",
	"building/scriptorium": "scriptorium",
	"building/watchhouse": "watchhouse",
	"building/beacon_tower": "beacon_tower",
	"building/lectern": "lectern",
	"building/quillworks": "quillworks",
	"building/forge": "forge",
	"building/rookery": "rookery",
	"building/archive": "archive",
	"building/waygate": "waygate",
	"node/tree_conifer": "tree_conifer",
	"node/tree_broadleaf": "tree_broadleaf",
	"node/berry_bush": "bush_berries",
	"node/bush_bare": "bush_bare",
	"node/stump": "stump",
	"decor/rock": "rock",
	"decor/stake": "stake",
	"decor/stake_flag": "stake",
	"decor/mountain": "mountain",
	"decor/cloud": "cloud",
	"decor/wood_pile": "wood_pile",
	"decor/stone_pile": "stone_pile",
	"decor/barrel": "barrel",
	"decor/crates": "crates",
	"decor/flag_blue": "flag_blue",
	"carry/wood": "carry_wood",
	"carry/food": "carry_food",
	"carry/scroll": "carry_scroll",
	"stage/a": "stage_a",
	"stage/b": "stage_b",
	"stage/c": "stage_c",
	"stage/scaffolding": "scaffolding",
	# Town walls (art_src/manifest.json "walls"): curtains normalised to thickness 1, towers to a
	# shaft 1 across, the gate to a door opening 1 wide.
	"wall/curtain": "wall_curtain",
	"wall/curtain_tall": "wall_curtain_tall",
	"wall/tower_squat": "wall_tower_squat",
	"wall/tower": "wall_tower",
	"wall/tower_roofed": "wall_tower_roofed",
	"wall/tower_spire": "wall_tower_spire",
	"wall/tower_catapult": "wall_tower_catapult",
	"wall/gate": "wall_gate",
}

## Unit kind -> character ids, picked by unit id. Agents wear their role's figure
## ("agent_" + role).
const CHARACTER_IDS := {
	"townsfolk": ["townsfolk_a", "townsfolk_b", "townsfolk_c", "townsfolk_d"],
	"agent_artificer": ["agent_artificer"],
	"agent_scholar": ["agent_scholar"],
	"agent_scribe": ["agent_scribe"],
	"agent_warden": ["agent_warden"],
	"agent_herald": ["agent_herald"],
}

## HUD icon name -> icon id, where they differ (resources map to resource_<name>).
const RESOURCE_ICONS := {
	"food": "resource_food", "wood": "resource_wood", "stone": "resource_stone", "gold": "resource_gold",
	"focus_food": "resource_food", "focus_wood": "resource_wood",
	"townsfolk": "townsfolk_a", "berry_bush": "bush_berries", "tree": "tree_broadleaf",
}

## path -> bool. Replaced by tests.
static var exists: Callable = _default_exists
## path -> Resource (or null). Replaced by tests.
static var loader: Callable = _default_load

static var _paths: Dictionary = {}
static var _anchors: Variant = null


static func _default_exists(path: String) -> bool:
	return ResourceLoader.exists(path)


static func _default_load(path: String) -> Resource:
	return ResourceLoader.load(path)


## Forgets cached lookups (after new art is imported, and between tests).
static func clear_cache() -> void:
	_paths.clear()
	_anchors = null


static func reset_hooks() -> void:
	exists = _default_exists
	loader = _default_load
	clear_cache()


static func id_for(key: String) -> String:
	return String(MODEL_IDS.get(key, ""))


## The model files for manifest id `id`: [<dir>/<id>.glb] when it has one source, otherwise
## its numbered variants [<dir>/<id>_0.glb, <dir>/<id>_1.glb, ...]; empty when none exist.
static func variant_paths(id: String, dir: String = MODELS_DIR) -> PackedStringArray:
	if id == "":
		return PackedStringArray()
	var ck := dir + "/" + id
	if _paths.has(ck):
		return _paths[ck]
	var out := PackedStringArray()
	var single := "%s/%s.glb" % [dir, id]
	if bool(exists.call(single)):
		out.append(single)
	else:
		for n in MAX_VARIANTS:
			var p := "%s/%s_%d.glb" % [dir, id, n]
			if not bool(exists.call(p)):
				break
			out.append(p)
	_paths[ck] = out
	return out


static func model_paths(key: String) -> PackedStringArray:
	return variant_paths(id_for(key))


## Character files for a unit kind (any subset of its ids may exist).
static func character_paths(kind: String) -> PackedStringArray:
	var ck := "characters/" + kind
	if _paths.has(ck):
		return _paths[ck]
	var out := PackedStringArray()
	for id: String in CHARACTER_IDS.get(kind, []):
		var p := "%s/%s.glb" % [CHARACTERS_DIR, id]
		if bool(exists.call(p)):
			out.append(p)
	_paths[ck] = out
	return out


## The icon id of the character a unit of `kind` wears (the same pick as ModelLibrary), or ""
## when there is no character art.
static func character_icon_id(kind: String, variant: int) -> String:
	var paths := character_paths(kind)
	if paths.is_empty():
		return ""
	return stem(paths[posmod(variant, paths.size())])


## res://art/icons/<id>.png when it exists, otherwise "".
static func icon_path(id: String) -> String:
	var ck := "icon/" + id
	if not _paths.has(ck):
		var p := "%s/%s.png" % [ICONS_DIR, id]
		_paths[ck] = p if bool(exists.call(p)) else ""
	return String(_paths[ck])


## The icon id for a HUD icon name (resources map to resource_<name>).
static func icon_id(name: String) -> String:
	return String(RESOURCE_ICONS.get(name, name))


## File stem of a model path: "res://art/models/rock_3.glb" -> "rock_3".
static func stem(path: String) -> String:
	return path.get_file().get_basename()


## Parsed anchors.json ({} when missing or unreadable).
static func anchors() -> Dictionary:
	if _anchors == null:
		_anchors = {}
		if FileAccess.file_exists(ANCHORS_PATH):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ANCHORS_PATH))
			if typeof(parsed) == TYPE_DICTIONARY:
				_anchors = parsed
	return _anchors


## Anchor record for a model file stem ({} when unknown).
static func anchor(file_stem: String) -> Dictionary:
	var a: Variant = anchors().get(file_stem, {})
	return a if typeof(a) == TYPE_DICTIONARY else {}


## [x, y, z] from an anchor record as a Vector3, or `fallback`.
static func anchor_point(record: Dictionary, field: String, fallback: Vector3) -> Vector3:
	var v: Variant = record.get(field)
	if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return fallback
