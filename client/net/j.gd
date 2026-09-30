class_name J
extends RefCounted
## Null-safe readers for protocol objects parsed from JSON. Optional fields arrive as null
## (String(null) is an error in GDScript) and every number arrives as a float.


## A string field: `fallback` for null or a missing key, str() for numbers and booleans.
static func s(v: Variant, fallback: String = "") -> String:
	match typeof(v):
		TYPE_NIL:
			return fallback
		TYPE_STRING, TYPE_STRING_NAME:
			return String(v)
	return str(v)


static func i(v: Variant, fallback: int = 0) -> int:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
			return int(v)
		TYPE_STRING:
			return int(v) if String(v).is_valid_int() else fallback
	return fallback


static func f(v: Variant, fallback: float = 0.0) -> float:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_STRING:
			return float(v) if String(v).is_valid_float() else fallback
	return fallback


static func b(v: Variant, fallback: bool = false) -> bool:
	return bool(v) if typeof(v) in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT] else fallback


static func d(v: Variant) -> Dictionary:
	return v if typeof(v) == TYPE_DICTIONARY else {}


static func a(v: Variant) -> Array:
	return v if typeof(v) == TYPE_ARRAY else []


## obj[key] as a string (null-safe).
static func gs(obj: Dictionary, key: String, fallback: String = "") -> String:
	return s(obj.get(key), fallback)


static func gi(obj: Dictionary, key: String, fallback: int = 0) -> int:
	return i(obj.get(key), fallback)


static func gd(obj: Dictionary, key: String) -> Dictionary:
	return d(obj.get(key))
