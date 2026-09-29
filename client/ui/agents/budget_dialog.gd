class_name BudgetDialog
extends WindowFrame
## Mana, the town's real-money budget (1 Mana = $0.01), in a status window:
## - the pool of this period, what is spent, what running tasks have reserved and what is left,
##   with the level and when the period turns;
## - the spend by harness and the harnesses' own usage windows;
## - why Mana is apart: resources never buy Mana, and Mana never buys resources.
## The form sets the period, the pool in USD and each harness's billing (Game.link.set_budget).
## Raising the pool in the middle of a period needs the player's word: the Town Hall answers
## CONFLICT, a confirmation box appears, and ticking it saves again with confirm_raise. On
## success: saved(mana), close. Live from Realm.mana_changed and the harness list.

signal saved(mana: Dictionary)

const Protocol = preload("res://net/protocol.gd")

var period: String = ""
var pool_usd: float = 0.0
## harness id -> "subscription" | "api_key".
var billing: Dictionary = {}

var pool_field: NumberField
var confirm_check: CheckToggle

var _stat_values: Dictionary = {}
var _stat_usd: Dictionary = {}
var _level_pill: PanelContainer
var _pool_bar: ManaBar
var _period_label: Label
var _by_provider: VBoxContainer
var _windows_section: HBoxContainer
var _windows: VBoxContainer
var _estimate_note: Label
var _period_buttons: Dictionary = {}
var _pool_mana: Label
var _billing_rows: VBoxContainer
var _billing_selects: Dictionary = {}
var _confirm_box: VBoxContainer
var _save_button: Button
var _needs_confirm: bool = false
var _busy: bool = false


func _init() -> void:
	super()
	configure("Mana", "The town's real-money budget", AgentTheme.STATUS, 820)
	set_title_icon(Glyph.new("mana", Color("#7fe0ff"), 30))
	_build_head()
	_build_body()
	var cancel := add_button("Cancel", "ghost")
	cancel.pressed.connect(close)
	_save_button = add_button("Save", "primary", "Save the budget")
	_save_button.custom_minimum_size.x = 150
	_save_button.pressed.connect(save)
	_load_form()
	_refresh()


func _window_opened() -> void:
	listen(Realm.mana_changed, _on_mana)
	listen(Realm.changed, _on_realm_changed)
	_refresh()


# --- building --------------------------------------------------------------------------------------

func _build_head() -> void:
	var row := AgentUi.hbox(10, head)
	for key: Array in [["pool", "Pool"], ["spent", "Spent"], ["reserved", "Reserved"], ["left", "Left"]]:
		var p := PanelContainer.new()
		p.add_theme_stylebox_override("panel", AgentTheme.group_box(look))
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(p)
		var col := AgentUi.vbox(0, p)
		AgentUi.label(String(key[1]).to_upper(), "Section", col)
		var v := AgentUi.label("", "Value", col)
		v.add_theme_font_size_override("font_size", 24)
		_stat_values[String(key[0])] = v
		_stat_usd[String(key[0])] = AgentUi.label("", "MonoSmall", col)
	(_stat_values["spent"] as Label).add_theme_color_override("font_color", Color("#ffcf8a"))
	(_stat_values["reserved"] as Label).add_theme_color_override("font_color", UiTokens.GOLD_BRIGHT)
	(_stat_values["left"] as Label).add_theme_color_override("font_color", UiTokens.MINT)
	var bar_row := AgentUi.hbox(12, head)
	_pool_bar = ManaBar.new(300, 20)
	_pool_bar.look = look
	_pool_bar.bar_height = 12.0
	_pool_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pool_bar.show_caption = false
	_pool_bar.fill_top = Color("#ffe3a8")
	_pool_bar.fill_bottom = Color("#d08a2e")
	_pool_bar.warn_colors = false
	bar_row.add_child(_pool_bar)
	_level_pill = AgentUi.pill("", UiTokens.MINT, true, bar_row)
	_period_label = AgentUi.label("", "MonoSmall", head)
	show_head(true)


func _build_body() -> void:
	AgentUi.section("By harness", look, "This period", body)
	_by_provider = AgentUi.vbox(8, body)
	_windows_section = AgentUi.section("Harness usage windows", look, "Their own limits", body)
	_windows = AgentUi.vbox(8, body)
	_estimate_note = AgentUi.para("", "Hint", body)
	AgentUi.callout(look, Color("#7fe0ff"),
		"1 Mana is $0.01 of real model spend, counted by the Town Hall as agents work. Resources never buy Mana and Mana never buys resources: the pool refills only when the period turns, or when you raise it here.",
		"What Mana is", "mana", body)

	AgentUi.section("Set the budget", look, "", body)
	var prow := AgentUi.hbox(10, body)
	var pl := AgentUi.label("PERIOD", "MonoSmall", prow)
	pl.custom_minimum_size.x = 90
	pl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var group := ButtonGroup.new()
	for p in Protocol.ManaPeriod.ALL:
		var b := Button.new()
		b.theme_type_variation = "ChipButton"
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.text = String({"day": "DAILY", "week": "WEEKLY", "month": "MONTHLY"}.get(p, String(p).to_upper()))
		b.custom_minimum_size = Vector2(96, 30)
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.toggled.connect(_on_period_toggled.bind(String(p)))
		prow.add_child(b)
		_period_buttons[String(p)] = b

	var urow := AgentUi.hbox(10, body)
	var ul := AgentUi.label("POOL", "MonoSmall", urow)
	ul.custom_minimum_size.x = 90
	ul.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var dollar := AgentUi.label("$", "Value", urow)
	dollar.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pool_field = NumberField.new("USD", look)
	pool_field.decimals = 2
	pool_field.step = 0.5
	pool_field.min_value = 0.0
	pool_field.max_value = 100000.0
	pool_field.edit.custom_minimum_size.x = 110
	pool_field.value_changed.connect(_on_pool_changed)
	urow.add_child(pool_field)
	_pool_mana = AgentUi.label("", "Mono", urow)
	_pool_mana.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pool_mana.add_theme_color_override("font_color", Color("#7fe0ff"))

	var brow := AgentUi.hbox(10, body)
	var bl := AgentUi.label("BILLING", "MonoSmall", brow)
	bl.custom_minimum_size.x = 90
	bl.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_billing_rows = AgentUi.vbox(8, brow)
	_billing_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_confirm_box = AgentUi.vbox(4, tray)
	_confirm_box.visible = false
	confirm_check = CheckToggle.new("Raise the pool now, in the middle of this period", look)
	confirm_check.toggled.connect(_on_confirm_toggled)
	_confirm_box.add_child(confirm_check)
	AgentUi.para("Mana already spent this period stays spent; the new pool applies at once.", "Hint", _confirm_box)


# --- data ---------------------------------------------------------------------------------------------

## Harness ids to show: those the Town Hall reported, then any in the Mana figures.
func harness_ids() -> Array[String]:
	var out: Array[String] = []
	for p: Variant in Realm.providers:
		var id := J.gs(J.d(p), "id")
		if id != "" and not id in out:
			out.append(id)
	for k: Variant in J.gd(Realm.mana, "by_provider").keys():
		var id := String(k)
		if not id in out:
			out.append(id)
	return out


func _default_billing(id: String) -> String:
	var hint := J.gs(Realm.provider(id), "billing_hint")
	if hint == Protocol.Billing.SUBSCRIPTION or hint == Protocol.Billing.API_KEY:
		return hint
	for a in Realm.active_agents():
		if J.gs(a, "provider") == id:
			var b := J.gs(a, "billing")
			if b != "":
				return b
	return Protocol.Billing.SUBSCRIPTION


func _load_form() -> void:
	var m := Realm.mana
	var econ_mana := Economy.data.section("mana")
	period = J.gs(m, "period", String(econ_mana.get("default_period", "day")))
	var cap := J.gi(m, "cap_micros", -1)
	pool_usd = float(cap) / 1000000.0 if cap >= 0 else float(econ_mana.get("default_pool_usd", 5.0))
	pool_field.set_value(pool_usd)
	for key: String in _period_buttons:
		(_period_buttons[key] as Button).set_pressed_no_signal(key == period)
	for id in harness_ids():
		if not billing.has(id):
			billing[id] = _default_billing(id)
	_rebuild_billing()
	_on_pool_changed(pool_field.value)


func _rebuild_billing() -> void:
	clear_box(_billing_rows)
	_billing_selects.clear()
	for id in harness_ids():
		if not billing.has(id):
			billing[id] = _default_billing(id)
		var row := AgentUi.hbox(10, _billing_rows)
		var n := AgentUi.label(AgentUi.harness_name(id), "", row)
		n.custom_minimum_size.x = 130
		n.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var sel := FormDropdown.new()
		sel.custom_minimum_size.x = 180
		sel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		sel.add_entry("Subscription", Protocol.Billing.SUBSCRIPTION, AgentUi.billing_note(Protocol.Billing.SUBSCRIPTION))
		sel.add_entry("API key", Protocol.Billing.API_KEY, AgentUi.billing_note(Protocol.Billing.API_KEY))
		sel.select_value(String(billing[id]))
		sel.item_selected.connect(_on_billing_selected.bind(id))
		row.add_child(sel)
		var hint := AgentUi.label(AgentUi.billing_note(String(billing[id])), "Hint", row)
		hint.name = "Hint"
		hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_billing_selects[id] = sel


func _refresh() -> void:
	var m := Realm.mana
	var mpm := AgentUi.micros_per_mana()
	var cap := J.gi(m, "cap_micros")
	var spent := J.gi(m, "spent_micros")
	var reserved := J.gi(m, "reserved_micros")
	var left := J.gi(m, "remaining_micros", maxi(cap - spent - reserved, 0))
	for pair: Array in [["pool", cap], ["spent", spent], ["reserved", reserved], ["left", left]]:
		var micros := int(pair[1])
		(_stat_values[String(pair[0])] as Label).text = AgentUi.mana_text(micros)
		(_stat_usd[String(pair[0])] as Label).text = "%s  ·  MANA" % AgentUi.usd_text(micros)
	_pool_bar.set_values(float(spent) / float(mpm), float(cap) / float(mpm), float(reserved) / float(mpm))
	_pool_bar.tooltip_text = "Spent %s, reserved by running tasks %s, left %s of %s Mana." % [AgentUi.mana_text(spent),
		AgentUi.mana_text(reserved), AgentUi.mana_text(left), AgentUi.mana_text(cap)]
	var level := J.gs(m, "level", Realm.mana_level())
	var level_color := UiTokens.MINT
	match level:
		Protocol.ManaLevel.DIM:
			level_color = Color("#f0c27a")
		Protocol.ManaLevel.WARNING:
			level_color = UiTokens.WARN
		Protocol.ManaLevel.DEPLETED:
			level_color = UiTokens.BAD
		"offline", "":
			level_color = Color("#8fa4c8")
	AgentUi.set_pill(_level_pill, level if level != "" else "offline", level_color, true)
	var period_name := String({"day": "Daily pool", "week": "Weekly pool", "month": "Monthly pool"}.get(J.gs(m, "period"), "Pool"))
	var ends := AgentUi.unix_of(J.gs(m, "period_end"))
	if ends > 0.0:
		_period_label.text = "%s  ·  refills in %s, at %s" % [period_name, AgentUi.duration_text(ends - AgentUi.now_unix()),
			AgentUi.local_clock(J.gs(m, "period_end"), false)]
	else:
		_period_label.text = "%s  ·  the Town Hall has not reported its Mana yet" % period_name if not m.is_empty() else "The Town Hall is not connected."
	_period_label.text = _period_label.text.to_upper()

	clear_box(_by_provider)
	var by := J.gd(m, "by_provider")
	var total := 0
	for k: Variant in by.keys():
		total += J.i(by[k])
	for id in harness_ids():
		var micros := J.gi(by, id)
		var row := AgentUi.hbox(12, _by_provider)
		var n := AgentUi.label(AgentUi.harness_name(id), "", row)
		n.custom_minimum_size.x = 130
		var bar := ManaBar.new(200, 14)
		bar.look = look
		bar.show_caption = false
		bar.warn_colors = false
		bar.bar_height = 8.0
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.set_values(float(micros), float(maxi(total, 1)))
		row.add_child(bar)
		var v := AgentUi.label("%s MANA  ·  %s" % [AgentUi.mana_text(micros), AgentUi.usd_text(micros)], "Mono", row)
		v.custom_minimum_size.x = 170
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	clear_box(_windows)
	var windows := J.a(m.get("provider_windows"))
	_windows_section.visible = not windows.is_empty()
	for w: Variant in windows:
		var wd := J.d(w)
		var row := AgentUi.hbox(12, _windows)
		var n := AgentUi.label(AgentUi.harness_name(J.gs(wd, "provider")), "", row)
		n.custom_minimum_size.x = 130
		var used := J.f(wd.get("used_percent"))
		var bar := ManaBar.new(200, 14)
		bar.look = look
		bar.unit = ""
		bar.show_caption = false
		bar.bar_height = 8.0
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.set_values(used, 100.0)
		row.add_child(bar)
		var resets := AgentUi.unix_of(J.gs(wd, "resets_at"))
		var text := "%d%% USED" % roundi(used)
		if resets > 0.0:
			text += "  ·  RESETS IN %s" % AgentUi.duration_text(resets - AgentUi.now_unix()).to_upper()
		var v := AgentUi.label(text, "MonoSmall", row)
		v.custom_minimum_size.x = 240
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_estimate_note.visible = J.b(m.get("estimates"), false)
	_estimate_note.text = "Some of this is estimated: harnesses on a subscription report tokens, not money, so the Town Hall prices them."


# --- form --------------------------------------------------------------------------------------------

func _on_period_toggled(on: bool, p: String) -> void:
	if on:
		period = p
		_on_pool_changed(pool_field.value)


func _on_pool_changed(v: float) -> void:
	pool_usd = v
	var mana := roundi(v * 1000000.0 / float(AgentUi.micros_per_mana()))
	var per := String({"day": "each day", "week": "each week", "month": "each month"}.get(period, "each period"))
	_pool_mana.text = "= %s MANA %s" % [AgentUi.group(mana), per.to_upper()]


func _on_billing_selected(_idx: int, id: String) -> void:
	var sel: FormDropdown = _billing_selects[id]
	billing[id] = sel.value()
	for row in _billing_rows.get_children():
		if row.get_child_count() > 1 and row.get_child(1) == sel:
			var hint := row.get_node_or_null("Hint") as Label
			if hint != null:
				hint.text = AgentUi.billing_note(String(billing[id]))


func _on_confirm_toggled(on: bool) -> void:
	if on and _needs_confirm and not _busy:
		save()


## The set_budget billing: every harness the town knows, each "subscription" or "api_key".
func billing_payload() -> Dictionary:
	var out := {}
	for id in harness_ids():
		out[id] = String(billing.get(id, _default_billing(id)))
	return out


func save() -> void:
	if _busy:
		return
	_busy = true
	_save_button.disabled = true
	set_status("Saving the budget...", "busy")
	var req: NetRequest = the_link().set_budget(period, snappedf(pool_usd, 0.01), billing_payload(), confirm_check.button_pressed)
	if req == null:
		_busy = false
		_save_button.disabled = false
		return
	req.done.connect(_on_saved)


func _on_saved(req: NetRequest) -> void:
	_busy = false
	_save_button.disabled = false
	if req.ok:
		saved.emit(J.gd(req.payload_dict(), "mana"))
		close()
		return
	if req.error_code() == Protocol.ERR_CONFLICT and not confirm_check.button_pressed:
		_needs_confirm = true
		_confirm_box.visible = true
		show_tray(true)
		set_status("Raising the pool in the middle of a period needs your word: tick the box to save.", "warn")
		return
	set_status(req.error_message(), "error")


# --- events --------------------------------------------------------------------------------------------

func _on_mana(_m: Dictionary) -> void:
	_refresh()


func _on_realm_changed(kind: String, _id: String) -> void:
	if kind == "providers" or kind == "all":
		_rebuild_billing()
		_refresh()


func _window_key(event: InputEventKey) -> bool:
	if (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER) and not typing_in_text_edit():
		save()
		return true
	return false
