class_name ConstructionMath
extends RefCounted
## Build time with n builders, evaluated from economy.json construction.builder_time_formula
## ("build_s * 3 / (builders + 2)") with Godot's Expression, so the formula lives only in data.

static var _parsed: Dictionary = {}


## Seconds to finish a site whose base time is `build_s` with `builders` builders (INF for 0).
static func duration_s(econ: EconomyData, build_s: float, builders: int) -> float:
	if builders <= 0:
		return INF
	var formula := econ.builder_time_formula()
	var expr: Expression = _parsed.get(formula)
	if expr == null:
		expr = Expression.new()
		if formula.is_empty() or expr.parse(formula, PackedStringArray(["build_s", "builders"])) != OK:
			return build_s
		_parsed[formula] = expr
	var v: Variant = expr.execute([float(build_s), float(builders)])
	if expr.has_execute_failed() or (typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT):
		return build_s
	return float(v)


## Progress units (out of SimConst.WORK_SCALE) added per tick with `builders` builders.
static func work_per_tick(econ: EconomyData, build_s: float, builders: int, tick_rate: int) -> int:
	var d := duration_s(econ, build_s, builders)
	if is_inf(d):
		return 0
	if d <= 0.0:
		return SimConst.WORK_SCALE
	return maxi(1, int(round(float(SimConst.WORK_SCALE) / (d * float(tick_rate)))))
