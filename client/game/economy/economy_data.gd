class_name EconomyData
extends RefCounted
## Typed, read-only view over economy.json: the single source of truth for every cost, rate and
## threshold, shared with the Town Hall.
##
## The client copy lives at res://data/economy.json. It is a byte-for-byte copy of
## protocol/economy.json made by `node scripts/sync-economy.mjs`, which must be run after every
## change to the protocol file (tests/unit/test_economy_data.gd fails when the copy is stale).
## Nothing in the client should hard-code a value that exists in this file.

const DEFAULT_PATH := "res://data/economy.json"

var raw: Dictionary = {}
var load_error: String = ""


static func load_default() -> EconomyData:
	return load_from_file(DEFAULT_PATH)


static func load_from_file(path: String) -> EconomyData:
	var e := EconomyData.new()
	if not FileAccess.file_exists(path):
		e.load_error = "missing %s" % path
		return e
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		e.load_error = "invalid JSON in %s" % path
		return e
	e.raw = parsed
	return e


static func from_dict(d: Dictionary) -> EconomyData:
	var e := EconomyData.new()
	e.raw = d.duplicate(true)
	return e


func is_valid() -> bool:
	return load_error.is_empty() and not raw.is_empty()


func section(key: String) -> Dictionary:
	var v: Variant = raw.get(key, {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


# --- clock, map, ages -------------------------------------------------------------------

func tick_rate() -> int:
	return int(raw.get("tick_rate", 0))


func map_size() -> int:
	return int(section("map").get("size", 0))


func ring_radii() -> Array[int]:
	var out: Array[int] = []
	for r: Variant in section("map").get("ring_radii", []):
		out.append(int(r))
	return out


## Radius (tiles from the map centre) of the build zone in `age`. The next ring out from the
## current wall is surveyed and buildable: Age I reaches ring 2, Age II ring 3, and so on.
func build_radius(age: int) -> int:
	var radii := ring_radii()
	if radii.is_empty():
		return 0
	return radii[clampi(age, 0, radii.size() - 1)]


func start_age() -> int:
	return int(section("start").get("age", 1))


func start_resources() -> Dictionary:
	var out := {}
	var src: Dictionary = section("start").get("resources", {})
	for res in resource_names():
		out[res] = int(src.get(res, 0))
	return out


func start_townsfolk() -> int:
	return int(section("start").get("townsfolk", 0))


func ages() -> Array:
	var v: Variant = raw.get("ages", [])
	return v if typeof(v) == TYPE_ARRAY else []


func age_def(n: int) -> Dictionary:
	for a: Variant in ages():
		if typeof(a) == TYPE_DICTIONARY and int(a.get("n", 0)) == n:
			return a
	return {}


func age_name(n: int) -> String:
	return String(age_def(n).get("name", "Age %d" % n))


# --- resources and storage ---------------------------------------------------------------

func resource_names() -> Array[String]:
	var out: Array[String] = []
	for r: Variant in raw.get("resources", []):
		out.append(String(r))
	return out


func capped_resources() -> Array[String]:
	var out: Array[String] = []
	for r: Variant in section("storage").get("capped", []):
		out.append(String(r))
	return out


## Storage cap for `res` in `age` with `storehouses` completed Storehouses, or -1 if uncapped.
func storage_cap(res: String, age: int, storehouses: int) -> int:
	var s := section("storage")
	if not res in capped_resources():
		return -1
	var caps: Array = s.get("cap_by_age", [])
	if caps.is_empty():
		return -1
	var base := int(caps[clampi(age - 1, 0, caps.size() - 1)])
	return base + maxi(storehouses, 0) * int(s.get("storehouse_bonus", 0))


# --- gathering -----------------------------------------------------------------------------

func carry_capacity(age: int) -> int:
	var g := section("gather")
	return int(g.get("carry_base", 0)) + int(g.get("carry_per_age", 0)) * maxi(age - 1, 0)


func walk_speed(kind: String) -> float:
	var speeds: Dictionary = section("gather").get("walk_tiles_per_s", {})
	return float(speeds.get(kind, 0.0))


func search_radius() -> float:
	return float(section("gather").get("search_radius_tiles", 0))


func retry_radius() -> float:
	return float(section("gather").get("same_kind_retry_radius_tiles", 0))


func node_kinds() -> Array[String]:
	var out: Array[String] = []
	var nodes: Dictionary = section("gather").get("nodes", {})
	for k: Variant in nodes.keys():
		out.append(String(k))
	return out


func node_def(kind: String) -> Dictionary:
	var nodes: Dictionary = section("gather").get("nodes", {})
	var v: Variant = nodes.get(kind, {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


func node_resource(kind: String) -> String:
	return String(node_def(kind).get("resource", ""))


func node_rate(kind: String) -> float:
	return float(node_def(kind).get("rate_per_s", 0.0))


## Starting amount of a node, or -1 for endless sources (farms).
func node_amount(kind: String) -> int:
	return int(node_def(kind).get("amount", 0))


func node_regrow_s(kind: String) -> float:
	return float(node_def(kind).get("regrow_s", 0.0))


## Gather rate in thousandths of a resource unit per tick (integer, so yields are exact).
func gather_milli_per_tick(kind: String) -> int:
	var tr := tick_rate()
	if tr <= 0:
		return 0
	return int(round(node_rate(kind) * 1000.0 / float(tr)))


## Resources that townsfolk can gather (the resources produced by gather nodes).
func gatherable_resources() -> Array[String]:
	var out: Array[String] = []
	for res in resource_names():
		for k in node_kinds():
			if node_resource(k) == res and not res in out:
				out.append(res)
	return out


# --- buildings -----------------------------------------------------------------------------

func building_types() -> Array[String]:
	var out: Array[String] = []
	for k: Variant in section("buildings").keys():
		out.append(String(k))
	return out


## A building type's definition. Tool add-ons ("lectern", "forge", ...) are buildings too:
## their "tools" entry is returned with built_by "agent", so footprints, build times and names
## work the same way for them.
func building_def(type: String) -> Dictionary:
	var v: Variant = section("buildings").get(type)
	if typeof(v) == TYPE_DICTIONARY:
		return v
	var t := tool_def(type)
	if t.is_empty():
		return {}
	var d := t.duplicate()
	d["built_by"] = "agent"
	return d


func is_tool(type: String) -> bool:
	return not tool_def(type).is_empty()


## Agent homes: the buildings a role lives in.
func is_home(type: String) -> bool:
	var v: Variant = section("buildings").get(type)
	return typeof(v) == TYPE_DICTIONARY and String((v as Dictionary).get("role", "")) != ""


func has_building(type: String) -> bool:
	return not building_def(type).is_empty()


func building_name(type: String) -> String:
	return String(building_def(type).get("name", type.capitalize()))


func building_plain(type: String) -> String:
	return String(building_def(type).get("plain", ""))


func building_footprint(type: String) -> Vector2i:
	var fp: Array = building_def(type).get("footprint", [1, 1])
	if fp.size() < 2:
		return Vector2i.ONE
	return Vector2i(int(fp[0]), int(fp[1]))


func building_cost(type: String) -> Dictionary:
	return _int_dict(building_def(type).get("cost", {}))


func building_build_s(type: String) -> float:
	return float(building_def(type).get("build_s", 0.0))


func building_pop(type: String) -> int:
	return int(building_def(type).get("pop", 0))


func building_age(type: String) -> int:
	return int(building_def(type).get("age", 1))


func building_built_by(type: String) -> String:
	return String(building_def(type).get("built_by", ""))


func building_dropoffs(type: String) -> Array[String]:
	var out: Array[String] = []
	for r: Variant in building_def(type).get("dropoff", []):
		out.append(String(r))
	return out


## Buildings that are also gather sources (farms) are fields: walkable and worked from inside.
func building_is_field(type: String) -> bool:
	return has_building(type) and not node_def(type).is_empty()


## Buildings the given builder may place, in economy.json order.
func buildable_by(builder: String) -> Array[String]:
	var out: Array[String] = []
	for t in building_types():
		if building_built_by(t) == builder:
			out.append(t)
	return out


func builder_time_formula() -> String:
	return String(section("construction").get("builder_time_formula", ""))


# --- units, population, queue, refunds ---------------------------------------------------

func unit_def(type: String) -> Dictionary:
	var v: Variant = section("units").get(type, {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


func unit_cost(type: String) -> Dictionary:
	return _int_dict(unit_def(type).get("cost", {}))


func unit_train_s(type: String) -> float:
	return float(unit_def(type).get("train_s", 0.0))


func unit_train_ticks(type: String) -> int:
	return maxi(1, int(round(unit_train_s(type) * float(tick_rate()))))


func unit_pop(kind: String) -> int:
	return int(section("population").get(kind + "_pop", 1))


func pop_limit(age: int) -> int:
	var caps: Array = section("population").get("cap_by_age", [])
	if caps.is_empty():
		return 0
	return int(caps[clampi(age - 1, 0, caps.size() - 1)])


func training_queue_max() -> int:
	return int(section("training_queue").get("max", 0))


func refund_fraction(kind: String) -> float:
	return float(section("refunds").get(kind, 0.0))


# --- agents: roles, homes, tool add-ons -------------------------------------------------------

func role_names() -> Array[String]:
	var out: Array[String] = []
	for k: Variant in section("roles").keys():
		out.append(String(k))
	return out


func role_def(role: String) -> Dictionary:
	var v: Variant = section("roles").get(role, {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


func role_name(role: String) -> String:
	return String(role_def(role).get("name", role.capitalize()))


func role_plain(role: String) -> String:
	return String(role_def(role).get("plain", ""))


func role_age(role: String) -> int:
	return int(role_def(role).get("age", 1))


## The home building type of a role ("workshop" for an Artificer).
func role_home(role: String) -> String:
	return String(role_def(role).get("home", ""))


func role_train_s(role: String) -> float:
	return float(role_def(role).get("train_s", 0.0))


## The role's base summoning cost, before the per-existing-agent increase.
func role_cost(role: String) -> Dictionary:
	return _int_dict(role_def(role).get("cost", {}))


## What summoning costs when `existing` agents are already in town (the Town Hall rounds the
## same way: each resource scaled by 1 + scaling * existing, rounded to the nearest unit).
func agent_cost(role: String, existing: int) -> Dictionary:
	var f := 1.0 + float(raw.get("agent_cost_scaling_per_existing", 0.0)) * float(maxi(existing, 0))
	var out := {}
	var base := role_cost(role)
	for res: String in base:
		out[res] = int(round(float(base[res]) * f))
	return out


func role_tools(role: String, which: String) -> Array[String]:
	var out: Array[String] = []
	for t: Variant in role_def(role).get(which + "_tools", []):
		out.append(String(t))
	return out


## The role whose home is `type`, or "".
func home_role(type: String) -> String:
	return String(building_def(type).get("role", "")) if is_home(type) else ""


func tool_types() -> Array[String]:
	var out: Array[String] = []
	for k: Variant in section("tools").keys():
		out.append(String(k))
	return out


func tool_def(type: String) -> Dictionary:
	var v: Variant = section("tools").get(type, {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


func tool_requires(type: String) -> Array[String]:
	var out: Array[String] = []
	for t: Variant in tool_def(type).get("requires", []):
		out.append(String(t))
	return out


func tool_slots(age: int) -> int:
	return _by_age("tool_slots_by_age", age)


func home_task_queue(age: int) -> int:
	return _by_age("home_task_queue_by_age", age)


func agent_limit(age: int) -> int:
	var limits: Array = section("population").get("agent_limit_by_age", [])
	if limits.is_empty():
		return 0
	return int(limits[clampi(age - 1, 0, limits.size() - 1)])


func home_plot_size() -> int:
	return int(section("map").get("home_plot", 7))


# --- tasks, Mana, couriers -----------------------------------------------------------------

func task_sizes() -> Array[String]:
	var out: Array[String] = []
	for k: Variant in section("sizes").keys():
		out.append(String(k))
	return out


func size_name(size: String) -> String:
	return String(section("sizes").get(size, {}).get("name", size))


## Default Mana seal for a task size.
func seal_mana(size: String) -> int:
	return int(section("mana").get("seal_by_size", {}).get(size, 0))


func bounty_base(size: String) -> int:
	return int(section("bounty").get("base_by_size", {}).get(size, 0))


func micros_per_mana() -> int:
	return maxi(int(section("mana").get("micros_per_mana", 10000)), 1)


func wisp_after_s() -> float:
	return float(section("couriers").get("wisp_after_s", 20.0))


func force_deliver_after_s() -> float:
	return float(section("couriers").get("force_deliver_after_s", 90.0))


func approval_modes() -> Array[String]:
	var out: Array[String] = []
	for k: Variant in section("approval_modes").keys():
		out.append(String(k))
	return out


func approval_mode_def(mode: String) -> Dictionary:
	var v: Variant = section("approval_modes").get(mode, {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


func default_approval_mode() -> String:
	for m in approval_modes():
		if bool(approval_mode_def(m).get("default", false)):
			return m
	return "trusted_edits"


func _by_age(key: String, age: int) -> int:
	var v: Variant = raw.get(key, [])
	if typeof(v) != TYPE_ARRAY or (v as Array).is_empty():
		return 0
	var arr: Array = v
	return int(arr[clampi(age - 1, 0, arr.size() - 1)])


# --- helpers -------------------------------------------------------------------------------

static func _int_dict(v: Variant) -> Dictionary:
	var out := {}
	if typeof(v) != TYPE_DICTIONARY:
		return out
	for k: Variant in v.keys():
		out[String(k)] = int(v[k])
	return out
