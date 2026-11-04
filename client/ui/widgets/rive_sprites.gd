class_name RiveSprites
extends RefCounted
## The Rive state tracker, baked: sprite sheets made by scripts/bake-rive.mjs from the RML project
## art_src/rive/state_tracker. Each set is one Rive artboard ("task_seal": a task's seal, one
## state per Task.state; "agent_sigil": an agent's gem, one state per AgentUi mood), and each of
## its states one sheet: a grid of the frames of that state's loop, as the artboard's state
## machine plays it. rive_sprites.json describes them; a sheet's texture loads the first time a
## sprite shows that state. RiveSprite draws them.

const MANIFEST := "res://art/rive/rive_sprites.json"
const DIR := "res://art/rive/"

static var _manifest: Dictionary = {}
static var _loaded: bool = false
static var _textures: Dictionary = {}


## The parsed rive_sprites.json ({} when it is missing or unreadable).
static func manifest() -> Dictionary:
	if not _loaded:
		_loaded = true
		if FileAccess.file_exists(MANIFEST):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
			if typeof(parsed) == TYPE_DICTIONARY:
				_manifest = parsed
		if _manifest.is_empty():
			push_warning("RiveSprites: %s is missing or unreadable; run node scripts/bake-rive.mjs" % MANIFEST)
	return _manifest


static func _set_info(set_name: String) -> Dictionary:
	var sets: Variant = manifest().get("sets")
	if typeof(sets) != TYPE_DICTIONARY:
		return {}
	return J.d((sets as Dictionary).get(set_name))


static func has_set(set_name: String) -> bool:
	return not _set_info(set_name).is_empty()


## The states a set has sheets for, in the manifest's order.
static func states(set_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	for k: Variant in J.d(_set_info(set_name).get("states")).keys():
		out.append(str(k))
	return out


static func has_state(set_name: String, state: String) -> bool:
	return J.d(_set_info(set_name).get("states")).has(state)


## The sheet that shows `state` of `set_name`, or the set's fallback state's when it has no sheet
## for it: {state, texture, frames, columns, size, pad, fps, blend_s}. {} for an unknown set or a
## missing texture.
static func sheet(set_name: String, state: String) -> Dictionary:
	var s := _set_info(set_name)
	if s.is_empty():
		return {}
	var all := J.d(s.get("states"))
	var shown := state if all.has(state) else J.gs(s, "fallback")
	var st := J.d(all.get(shown))
	if st.is_empty():
		return {}
	var tex := _texture(DIR + J.gs(st, "file"))
	if tex == null:
		return {}
	var dims := J.a(s.get("size"))
	var size := Vector2(float(dims[0]), float(dims[1])) if dims.size() == 2 else Vector2(tex.get_size())
	return {
		"state": shown,
		"texture": tex,
		"frames": maxi(J.gi(st, "frames", 1), 1),
		"columns": maxi(J.gi(st, "columns", 1), 1),
		"size": size,
		"pad": J.f(s.get("pad")),
		"fps": maxf(J.f(s.get("fps"), 30.0), 1.0),
		"blend_s": J.f(s.get("blend_ms"), 200.0) / 1000.0,
	}


## Where frame `index` (wrapped to the loop) of a sheet() lies in its texture.
static func frame_rect(sheet_info: Dictionary, index: int) -> Rect2:
	var frames: int = sheet_info.get("frames", 1)
	var columns: int = sheet_info.get("columns", 1)
	var size: Vector2 = sheet_info.get("size", Vector2.ONE)
	var pad: float = sheet_info.get("pad", 0.0)
	var i := posmod(index, frames)
	var cell := size + Vector2(pad, pad) * 2.0
	var row := floori(float(i) / float(columns))
	return Rect2(Vector2(float(i % columns) * cell.x + pad, float(row) * cell.y + pad), size)


## The frame showing `seconds` into a sheet's loop.
static func frame_at(sheet_info: Dictionary, seconds: float) -> int:
	var fps: float = sheet_info.get("fps", 30.0)
	var frames: int = sheet_info.get("frames", 1)
	return posmod(int(floor(seconds * fps)), frames)


static func _texture(path: String) -> Texture2D:
	if _textures.has(path):
		return _textures[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	if tex == null:
		push_warning("RiveSprites: no texture at %s" % path)
	_textures[path] = tex
	return tex
