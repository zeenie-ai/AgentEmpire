class_name UiFonts
extends RefCounted
## The bundled OFL fonts (ui/fonts/<family>/, each with its OFL.txt, from google/fonts):
## Cinzel for titles and buttons, Cormorant for display text, Spectral for body text and
## JetBrains Mono for labels and numbers. Variable fonts get their weight via FontVariation.

const CINZEL := "res://ui/fonts/cinzel/Cinzel-VariableFont_wght.ttf"
const CORMORANT := "res://ui/fonts/cormorant/Cormorant-VariableFont_wght.ttf"
const CORMORANT_ITALIC := "res://ui/fonts/cormorant/Cormorant-Italic-VariableFont_wght.ttf"
const SPECTRAL := "res://ui/fonts/spectral/Spectral-%s.ttf"
const MONO := "res://ui/fonts/jetbrainsmono/JetBrainsMono-VariableFont_wght.ttf"

static var _cache: Dictionary = {}


static func cinzel(weight: int = 700, spacing: int = 1) -> Font:
	return _variable(CINZEL, weight, spacing)


static func cormorant(weight: int = 600, italic: bool = false) -> Font:
	return _variable(CORMORANT_ITALIC if italic else CORMORANT, weight, 0)


static func mono(weight: int = 500, spacing: int = 1) -> Font:
	return _variable(MONO, weight, spacing)


## style: "Regular", "Italic", "Medium" or "SemiBold".
static func spectral(style: String = "Regular") -> Font:
	var key := "spectral:" + style
	if not _cache.has(key):
		_cache[key] = load(SPECTRAL % style)
	return _cache[key]


static func _variable(path: String, weight: int, spacing: int) -> Font:
	var key := "%s:%d:%d" % [path, weight, spacing]
	if _cache.has(key):
		return _cache[key]
	var fv := FontVariation.new()
	fv.base_font = load(path) as Font
	fv.variation_opentype = {"wght": weight}
	fv.spacing_glyph = spacing
	_cache[key] = fv
	return fv
