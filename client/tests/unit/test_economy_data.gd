extends GutTest
## economy.json loading, accessors, and that the client copy matches protocol/economy.json.

var econ: EconomyData


func before_each() -> void:
	econ = SimFixture.econ()


func test_client_copy_loads() -> void:
	assert_true(econ.is_valid(), "res://data/economy.json loads")
	assert_gt(econ.tick_rate(), 0)
	assert_gt(econ.map_size(), 0)


func test_client_copy_matches_protocol() -> void:
	var proto := ProjectSettings.globalize_path("res://").path_join("../protocol/economy.json")
	if not FileAccess.file_exists(proto):
		pending("protocol/economy.json is not next to the client")
		return
	var a: Variant = JSON.parse_string(FileAccess.get_file_as_string(proto))
	var b: Variant = JSON.parse_string(FileAccess.get_file_as_string(EconomyData.DEFAULT_PATH))
	assert_eq(JSON.stringify(b, "", true), JSON.stringify(a, "", true),
		"client/data/economy.json is stale: run node scripts/sync-economy.mjs")


func test_map_and_build_zone() -> void:
	var raw := econ.raw
	assert_eq(econ.map_size(), int(raw["map"]["size"]))
	assert_eq(econ.ring_radii().size(), (raw["map"]["ring_radii"] as Array).size())
	assert_eq(econ.build_radius(1), int(raw["map"]["ring_radii"][1]), "Age I builds up to ring 2")
	assert_eq(econ.build_radius(4), int(raw["map"]["ring_radii"][3]), "the last ring caps the zone")


func test_carry_capacity_grows_per_age() -> void:
	var g: Dictionary = econ.raw["gather"]
	assert_eq(econ.carry_capacity(1), int(g["carry_base"]))
	assert_eq(econ.carry_capacity(2), int(g["carry_base"]) + int(g["carry_per_age"]))


func test_walk_speed_and_rates() -> void:
	var g: Dictionary = econ.raw["gather"]
	assert_almost_eq(econ.walk_speed("townsfolk"), float(g["walk_tiles_per_s"]["townsfolk"]), 0.0001)
	for kind in ["berry_bush", "tree", "farm"]:
		var rate := float(g["nodes"][kind]["rate_per_s"])
		assert_eq(econ.gather_milli_per_tick(kind), int(round(rate * 1000.0 / econ.tick_rate())), kind)
	assert_eq(econ.node_amount("farm"), -1, "farms never run out")


func test_buildings() -> void:
	var fp: Array = econ.raw["buildings"]["keep"]["footprint"]
	assert_eq(econ.building_footprint("keep"), Vector2i(int(fp[0]), int(fp[1])))
	assert_true(econ.building_is_field("farm"), "farms are gather fields")
	assert_false(econ.building_is_field("cottage"))
	assert_eq(econ.buildable_by("townsfolk"), ["cottage", "farm", "storehouse"] as Array[String])
	assert_true("food" in econ.building_dropoffs("storehouse"))
	assert_eq(econ.gatherable_resources(), ["food", "wood"] as Array[String])


func test_storage_caps() -> void:
	var s: Dictionary = econ.raw["storage"]
	assert_eq(econ.storage_cap("food", 1, 0), int(s["cap_by_age"][0]))
	assert_eq(econ.storage_cap("wood", 2, 3), int(s["cap_by_age"][1]) + 3 * int(s["storehouse_bonus"]))
	assert_eq(econ.storage_cap("stone", 1, 0), -1, "stone is not capped")


func test_population() -> void:
	var p: Dictionary = econ.raw["population"]
	assert_eq(econ.building_pop("keep"), int(p["keep"]))
	assert_eq(econ.building_pop("cottage"), int(p["cottage"]))
	assert_eq(econ.pop_limit(1), int(p["cap_by_age"][0]))
	assert_eq(econ.unit_pop("townsfolk"), int(p["townsfolk_pop"]))
	assert_eq(econ.unit_pop("agent"), int(p["agent_pop"]))


func test_tool_add_ons_are_buildings_with_their_own_footprints_and_times() -> void:
	var e := EconomyData.load_default()
	assert_true(e.has_building("forge"))
	assert_true(e.is_tool("forge"))
	assert_false(e.is_home("forge"))
	assert_eq(e.building_footprint("forge"), Vector2i(2, 1), "the Forge is 2x1")
	assert_eq(e.building_footprint("waygate"), Vector2i(2, 2))
	assert_gt(e.building_build_s("forge"), 0.0)
	assert_eq(int(e.building_cost("forge").get("wood", 0)), 60)
	assert_eq(e.building_built_by("lectern"), "agent")
	assert_true(e.is_home("workshop"))
	assert_eq(e.role_home("artificer"), "workshop")
