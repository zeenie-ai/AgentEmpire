extends GutTest
## LocalLedger: all-or-nothing spends, the one-refund rule, storage caps.

var econ: EconomyData


func before_each() -> void:
	econ = SimFixture.econ()


func _ledger(start: Dictionary) -> LocalLedger:
	return LocalLedger.new(econ, start, 1)


func test_spend_is_all_or_nothing() -> void:
	var l := _ledger({"food": 100, "wood": 50})
	assert_true(l.spend("s1", "test", {"food": 60}, ""))
	assert_eq(l.amount("food"), 40)
	assert_false(l.spend("s2", "test", {"food": 30, "wood": 60}, ""), "not enough wood")
	assert_eq(l.amount("food"), 40, "nothing charged when a spend fails")
	assert_eq(l.amount("wood"), 50)
	assert_eq(l.missing({"wood": 60}), {"wood": 10})


func test_spend_op_id_is_idempotent() -> void:
	var l := _ledger({"food": 100})
	assert_true(l.spend("s1", "test", {"food": 10}, ""))
	assert_true(l.spend("s1", "test", {"food": 10}, ""))
	assert_eq(l.amount("food"), 90, "a repeated op id is charged once")


func test_refund_at_most_once_per_spend() -> void:
	var l := _ledger({"food": 100})
	l.spend("s1", "test", {"food": 50}, "")
	assert_eq(l.refund("r1", "s1", 1.0), {"food": 50})
	assert_eq(l.amount("food"), 100)
	assert_eq(l.refund("r2", "s1", 1.0), {}, "a second refund of the same spend pays nothing")
	assert_eq(l.amount("food"), 100)
	assert_eq(l.refund("r1", "s1", 1.0), {"food": 50}, "a repeated refund op returns the original result")
	assert_eq(l.amount("food"), 100, "...without paying again")


func test_refund_is_capped_at_amount_spent() -> void:
	var l := _ledger({"wood": 100})
	l.spend("s1", "test", {"wood": 30}, "")
	assert_eq(l.refund("r1", "s1", 1.5), {"wood": 30}, "fraction is clamped to 1")
	assert_eq(l.amount("wood"), 100)


func test_dismantle_fraction_refunds_half() -> void:
	var l := _ledger({"wood": 100})
	var f := econ.refund_fraction("dismantle")
	l.spend("s1", "test", {"wood": 30}, "")
	assert_eq(l.refund("r1", "s1", f), {"wood": int(floor(30 * f))})


func test_unknown_spend_refunds_nothing() -> void:
	var l := _ledger({"wood": 10})
	assert_eq(l.refund("r1", "nope", 1.0), {})
	assert_eq(l.amount("wood"), 10)


func test_deposit_respects_age_cap() -> void:
	var l := _ledger({"food": 0})
	var cap := econ.storage_cap("food", 1, 0)
	assert_eq(l.deposit("d1", {"food": cap + 100}, 0), {"food": cap})
	assert_eq(l.amount("food"), cap)
	assert_eq(l.deposit("d2", {"food": 5}, 0), {}, "a full store accepts nothing")
	assert_eq(l.amount("food"), cap)


func test_storehouses_raise_the_cap() -> void:
	var l := _ledger({"wood": 0})
	var cap0 := econ.storage_cap("wood", 1, 0)
	var bonus := int(econ.raw["storage"]["storehouse_bonus"])
	l.deposit("d1", {"wood": cap0}, 0)
	assert_eq(l.deposit("d2", {"wood": bonus * 3}, 2), {"wood": bonus * 2}, "two Storehouses add two bonuses")
	assert_eq(l.storage_cap("wood", 2), cap0 + 2 * bonus)


func test_cap_follows_age() -> void:
	var l := _ledger({"food": 0})
	l.set_age(2)
	assert_eq(l.storage_cap("food", 0), econ.storage_cap("food", 2, 0))
	assert_gt(l.storage_cap("food", 0), econ.storage_cap("food", 1, 0))


func test_uncapped_resources_accept_everything() -> void:
	var l := _ledger({"stone": 0})
	assert_eq(l.deposit("d1", {"stone": 99999}, 0), {"stone": 99999})
	assert_eq(l.storage_cap("stone", 0), -1)


func test_refunds_may_exceed_the_cap() -> void:
	var cap := econ.storage_cap("food", 1, 0)
	var l := _ledger({"food": cap})
	l.spend("s1", "test", {"food": 50}, "")
	l.deposit("d1", {"food": 50}, 0)
	assert_eq(l.amount("food"), cap)
	l.refund("r1", "s1", 1.0)
	assert_eq(l.amount("food"), cap + 50, "only gathering is capped")


func test_changed_signal() -> void:
	var l := _ledger({"food": 100})
	watch_signals(l)
	l.spend("s1", "train", {"food": 50}, "")
	assert_signal_emitted(l, "changed")
	var params: Array = get_signal_parameters(l, "changed")
	assert_eq(params[1], "train")
	assert_eq(params[2], {"food": -50})


func test_save_round_trip_keeps_refund_rights() -> void:
	var l := _ledger({"food": 100, "wood": 100})
	l.spend("s1", "build", {"wood": 40}, "")
	l.spend("s2", "train", {"food": 50}, "")
	l.refund("r1", "s2", 1.0)
	var copy := _ledger({})
	copy.load_dict(JSON.parse_string(JSON.stringify(l.to_dict())))
	assert_eq(copy.treasury(), l.treasury())
	assert_true(copy.is_refundable("s1"))
	assert_false(copy.is_refundable("s2"), "a refunded spend stays refunded after loading")
	assert_eq(copy.refund("r2", "s1", 1.0), {"wood": 40})
