class_name SummonDialog
extends WindowFrame
## The Summoning Font: calls a new agent to town through Game.link.summon (create_agent).
##
## The player picks a harness (from Realm.providers: version, Ready / Not logged in / Not
## installed, billing), a model (list_models, loaded when the harness is chosen, with cost
## hints), a name, a role (cost, home, default add-ons, age), the oath (standing instructions,
## prefilled per role), the work folder (FolderBrowser), the approval mode, the starting add-ons
## and, under Advanced, Mana seals per task size and a billing override. The side column shows
## the new agent and a live account of what it costs against the treasury, marking what Font's
## Grace makes free while the town has no agent. Summon (Enter) stays disabled until the form is
## valid; errors from the Town Hall show in the footer. On success: summoned(agent_id), close.
## Everything live-updates from Realm (harnesses, agents, age) and the treasury.

signal summoned(agent_id: String)

const Protocol = preload("res://net/protocol.gd")
const NAME_MAX := 40
const OATH_MAX := 8000
## Needs its own configuration, so it is never a starting add-on.
const WAYGATE := "waygate"

var provider: String = ""
var model: String = ""
var role: String = ""
var approval_mode: String = ""
var workspace_path: String = ""
## 1 git repository, 0 plain folder, -1 unknown.
var workspace_git: int = -1
var chosen_tools: Array[String] = []
## "" for the Town Hall's default.
var billing: String = ""

var _providers: Array = []
var _models: Dictionary = {}
var _model_errors: Dictionary = {}
var _loading: Dictionary = {}
var _oath_edited: bool = false
var _busy: bool = false
var _tools_role: String = ""

var _grace_banner: PanelContainer
var _harness_row: HBoxContainer
var _harness_note: Label
var _harness_cards: Dictionary = {}
var _model_select: FormDropdown
var _model_edit: LineEdit
var _model_hint: Label
var _name_edit: LineEdit
var _name_count: Label
var _role_row: HBoxContainer
var _role_cards: Dictionary = {}
var _oath_section: HBoxContainer
var _oath_edit: TextEdit
var _path_edit: LineEdit
var _path_hint: Label
var _mode_select: FormDropdown
var _mode_hint: Label
var _tools_section: HBoxContainer
var _tools_grid: GridContainer
var _tool_cards: Dictionary = {}
var _tools_hint: Label
var _adv_toggle: Button
var _adv_box: VBoxContainer
var _seal_fields: Dictionary = {}
var _seal_usd: Dictionary = {}
var _billing_select: FormDropdown

var _preview_portrait: AgentPortrait
var _preview_name: Label
var _preview_role: Label
var _preview_harness: Label
var _count_value: Label
var _cost_list: VBoxContainer
var _total_row: HBoxContainer
var _have_row: HBoxContainer
var _afford_note: Label
var _summon_button: Button


func _init() -> void:
	super()
	configure("Summoning Font", "Call a new agent to Aurelhaven", AgentTheme.STATUS, 1120)
	set_title_icon("summon", 40)
	_build_form()
	_build_side()
	var cancel := add_button("Cancel", "ghost")
	cancel.pressed.connect(close)
	add_key_hint("ENTER")
	_summon_button = add_button("Summon", "primary", "Summon the agent (Enter)")
	_summon_button.custom_minimum_size.x = 160
	_summon_button.pressed.connect(summon)
	_name_edit.text = AgentUi.random_name(_taken_names())
	_name_count.text = "%d / %d" % [_name_edit.text.length(), NAME_MAX]
	_refresh_all()


func _window_opened() -> void:
	listen(Realm.changed, _on_realm_changed)
	listen(Economy.treasury_changed, _on_treasury_changed)
	_refresh_all()
	_ensure_models(provider)


# --- building -------------------------------------------------------------------------------------

func _build_form() -> void:
	_grace_banner = AgentUi.callout(look, UiTokens.GOLD_BRIGHT, "", "Font's Grace", "star", body)

	var hs := AgentUi.section("Harness", look, "", body)
	var recheck := _chip("Check again", "Ask the Town Hall to look for installed harnesses again.")
	recheck.pressed.connect(check_harnesses)
	hs.add_child(recheck)
	_harness_row = AgentUi.hbox(10, body)
	_harness_note = AgentUi.para("", "Hint", body)
	_harness_note.visible = false

	var pair := AgentUi.hbox(18, body)
	var mcol := AgentUi.vbox(8, pair)
	mcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mcol.size_flags_stretch_ratio = 1.5
	AgentUi.section("Model", look, "", mcol)
	_model_select = FormDropdown.new()
	_model_select.item_selected.connect(_on_model_selected)
	mcol.add_child(_model_select)
	_model_edit = LineEdit.new()
	_model_edit.placeholder_text = "Model id, for example provider/model"
	_model_edit.max_length = 100
	_model_edit.visible = false
	_model_edit.text_changed.connect(_on_model_typed)
	mcol.add_child(_model_edit)
	_model_hint = AgentUi.label("", "MonoSmall", mcol)
	var ncol := AgentUi.vbox(8, pair)
	ncol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	AgentUi.section("Name", look, "", ncol)
	var nrow := AgentUi.hbox(6, ncol)
	_name_edit = LineEdit.new()
	_name_edit.max_length = NAME_MAX
	_name_edit.placeholder_text = "What the town calls this agent"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_changed.connect(_on_name_changed)
	nrow.add_child(_name_edit)
	var reroll := Button.new()
	reroll.theme_type_variation = "GhostButton"
	reroll.focus_mode = Control.FOCUS_NONE
	reroll.custom_minimum_size = Vector2(40, 36)
	reroll.tooltip_text = "Another name from the old tales"
	reroll.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	Glyph.inside(reroll, "dice", AgentTheme.c(look, "text"), 18)
	reroll.pressed.connect(_reroll_name)
	nrow.add_child(reroll)
	var name_hint := AgentUi.label("Up to 40 letters", "MonoSmall", ncol)
	name_hint.name = "NameHint"
	_name_count = name_hint

	AgentUi.section("Role", look, "", body)
	_role_row = AgentUi.hbox(10, body)
	_build_roles()

	_oath_section = AgentUi.section("Oath", look, "0 / %d" % OATH_MAX, body)
	_oath_edit = TextEdit.new()
	_oath_edit.custom_minimum_size = Vector2(0, 150)
	_oath_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_oath_edit.placeholder_text = "The standing instructions this agent follows on every task."
	_oath_edit.text_changed.connect(_on_oath_changed)
	body.add_child(_oath_edit)
	AgentUi.para("The oath is the agent's standing instructions: it reads them before every task. Edit freely; it is prefilled for the role.", "Hint", body)

	AgentUi.section("Work folder", look, "Required", body)
	var frow := AgentUi.hbox(8, body)
	_path_edit = LineEdit.new()
	_path_edit.placeholder_text = "The folder this agent works in"
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_edit.add_theme_font_override("font", UiFonts.mono(500, 0))
	_path_edit.add_theme_font_size_override("font_size", 14)
	_path_edit.text_changed.connect(_on_path_typed)
	frow.add_child(_path_edit)
	var browse := Button.new()
	browse.theme_type_variation = "GhostButton"
	browse.text = "BROWSE..."
	browse.focus_mode = Control.FOCUS_NONE
	browse.custom_minimum_size = Vector2(120, 36)
	browse.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	browse.pressed.connect(browse_folder)
	frow.add_child(browse)
	_path_hint = AgentUi.para("", "Hint", body)

	AgentUi.section("Approval mode", look, "", body)
	_mode_select = FormDropdown.new()
	_mode_select.item_selected.connect(_on_mode_selected)
	body.add_child(_mode_select)
	_mode_hint = AgentUi.para("", "Hint", body)

	_tools_section = AgentUi.section("Starting add-ons", look, "0 / 0 slots", body)
	_tools_grid = GridContainer.new()
	_tools_grid.columns = 3
	_tools_grid.add_theme_constant_override("h_separation", 10)
	_tools_grid.add_theme_constant_override("v_separation", 10)
	body.add_child(_tools_grid)
	_tools_hint = AgentUi.para("", "Hint", body)

	var adv_row := AgentUi.hbox(10, body)
	_adv_toggle = _chip("Show advanced", "Mana seals per task size and the billing override.")
	_adv_toggle.toggle_mode = true
	_adv_toggle.toggled.connect(_on_advanced_toggled)
	adv_row.add_child(_adv_toggle)
	var adv_rule := AgentUi.Rule.new()
	adv_rule.color = AgentTheme.c(look, "line")
	adv_rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	adv_rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	adv_row.add_child(adv_rule)
	_adv_box = AgentUi.vbox(10, body)
	_adv_box.visible = false
	AgentUi.section("Mana seals", look, "Per task size", _adv_box)
	AgentUi.para("A seal is the most Mana one task may spend before it pauses and asks you. 1 Mana = $0.01.", "Hint", _adv_box)
	var seals := AgentUi.hbox(12, _adv_box)
	for sz in Economy.data.task_sizes():
		var col := AgentUi.vbox(4, seals)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		AgentUi.label("%s  %s" % [Economy.data.size_name(sz).to_upper(), sz], "MonoSmall", col)
		var f := NumberField.new("", look)
		f.min_value = 1.0
		f.max_value = 1000000.0
		f.step = 10.0 if Economy.data.seal_mana(sz) < 500 else 50.0
		f.set_value(float(Economy.data.seal_mana(sz)))
		f.edit.custom_minimum_size.x = 70
		f.value_changed.connect(_on_seal_changed.bind(sz))
		col.add_child(f)
		_seal_fields[sz] = f
		_seal_usd[sz] = AgentUi.label("", "MonoSmall", col)
	AgentUi.section("Billing", look, "", _adv_box)
	_billing_select = FormDropdown.new()
	_billing_select.item_selected.connect(_on_billing_selected)
	_adv_box.add_child(_billing_select)
	AgentUi.para("Subscription use is estimated from tokens; API keys are billed exactly. Leave it to the Town Hall unless you know better.", "Hint", _adv_box)
	_refresh_seal_usd()


func _chip(text: String, tip: String = "") -> Button:
	var b := Button.new()
	b.theme_type_variation = "ChipButton"
	b.text = text.to_upper()
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if tip != "":
		b.tooltip_text = tip
	return b


func _build_roles() -> void:
	var group := ButtonGroup.new()
	for r in Economy.data.role_names():
		var card := ChoiceCard.new(look, 10)
		card.button_group = group
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.custom_minimum_size.x = 118
		card.content.add_theme_constant_override("separation", 5)
		var prow := AgentUi.hbox(0)
		prow.alignment = BoxContainer.ALIGNMENT_CENTER
		var portrait := AgentPortrait.new(58)
		portrait.show_rank = false
		portrait.role = r
		portrait.mood = "idle"
		prow.add_child(portrait)
		card.add(prow)
		var n := AgentUi.label(Economy.data.role_name(r).to_upper(), "CardTitle")
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.add(n)
		var plain := AgentUi.label(Economy.data.role_plain(r), "Hint")
		plain.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		plain.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		card.add(plain)
		var home := Economy.data.role_home(r)
		var hrow := AgentUi.hbox(5)
		hrow.alignment = BoxContainer.ALIGNMENT_CENTER
		hrow.add_child(IconView.new(home, 22))
		var hn := AgentUi.label(Economy.data.building_name(home), "MonoSmall", hrow)
		hn.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		card.add(hrow)
		var trow := AgentUi.hbox(2)
		trow.alignment = BoxContainer.ALIGNMENT_CENTER
		for t in Economy.data.role_tools(r, "default"):
			trow.add_child(IconView.new(t, 22))
		card.add(trow)
		var cost := AgentUi.cost_row({}, look)
		cost.alignment = BoxContainer.ALIGNMENT_CENTER
		card.add(cost)
		var arow := AgentUi.hbox(0)
		arow.alignment = BoxContainer.ALIGNMENT_CENTER
		var age_pill := AgentUi.pill("Age I", AgentTheme.c(look, "accent"), false, arow)
		card.add(arow)
		card.toggled.connect(_on_role_toggled.bind(r))
		_role_row.add_child(card)
		_role_cards[r] = {"card": card, "cost": cost, "age": age_pill}


func _build_side() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", AgentTheme.group_box(look))
	panel.custom_minimum_size = Vector2(312, 0)
	side.add_child(panel)
	var col := AgentUi.vbox(8, panel)
	var prow := AgentUi.hbox(0, col)
	prow.alignment = BoxContainer.ALIGNMENT_CENTER
	_preview_portrait = AgentPortrait.new(96)
	_preview_portrait.rank = AgentUi.rank_order()[0]
	_preview_portrait.mood = "training"
	prow.add_child(_preview_portrait)
	_preview_name = AgentUi.label("", "Display", col)
	_preview_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_name.clip_text = true
	_preview_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_preview_role = AgentUi.label("", "MonoSmall", col)
	_preview_role.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_role.add_theme_color_override("font_color", AgentTheme.c(look, "accent"))
	_preview_harness = AgentUi.label("", "MonoSmall", col)
	_preview_harness.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_harness.clip_text = true
	_preview_harness.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var crow := AgentUi.hbox(8, col)
	crow.alignment = BoxContainer.ALIGNMENT_CENTER
	var cl := AgentUi.label("AGENTS IN TOWN", "MonoSmall", crow)
	cl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count_value = AgentUi.label("", "Value", crow)
	AgentUi.spacer(col, false, 2)
	AgentUi.section("Offering", look, "", col)
	_cost_list = AgentUi.vbox(7, col)
	var rule := HSeparator.new()
	col.add_child(rule)
	_total_row = AgentUi.hbox(8, col)
	_have_row = AgentUi.hbox(8, col)
	_afford_note = AgentUi.para("", "Hint", col)
	AgentUi.para("Only the agent is paid now. Its home is paid when you place it, and each add-on when it is built.", "Hint", col)
	show_side(true)


# --- state ------------------------------------------------------------------------------------------

func _taken_names() -> Array:
	var out: Array = []
	for a in Realm.active_agents():
		out.append(J.gs(a, "name"))
	return out


func _grace() -> Dictionary:
	var ad: Dictionary = Economy.data.section("anti_deadlock")
	var g: Variant = ad.get("fonts_grace", {})
	return g if typeof(g) == TYPE_DICTIONARY else {}


## True while the next agent is summoned under Font's Grace.
func grace_active() -> bool:
	var g := _grace()
	return not g.is_empty() and Realm.agent_count() == int(g.get("when_agents", 0))


func _grace_frees(what: String) -> bool:
	return grace_active() and what in J.a(_grace().get("free"))


func _provider_info(id: String) -> Dictionary:
	for p: Variant in _providers:
		if J.gs(J.d(p), "id") == id:
			return J.d(p)
	return {}


func _provider_ready(id: String) -> bool:
	return id != "" and AgentUi.harness_state(_provider_info(id)) == "ready"


func _role_locked(r: String) -> bool:
	return Economy.data.role_age(r) > Realm.current_age()


func _refresh_all() -> void:
	if not Realm.providers.is_empty() or _providers.is_empty():
		_providers = Realm.providers.duplicate()
	_refresh_header()
	_rebuild_harnesses()
	_refresh_roles()
	_refresh_oath()
	_refresh_modes()
	_rebuild_tools()
	_refresh_billing()
	_refresh_side()
	_validate()


func _refresh_header() -> void:
	var age := Realm.current_age()
	set_title("Summoning Font", "Call a new agent  ·  %d of %d in town  ·  %s Age" % [Realm.agent_count(),
		Economy.data.agent_limit(age), Economy.data.age_name(age)])
	_grace_banner.visible = grace_active()
	if _grace_banner.visible:
		var parts: PackedStringArray = []
		var free := J.a(_grace().get("free"))
		if "agent" in free:
			parts.append("your first agent")
		if "home" in free:
			parts.append("its home")
		if "required_tools" in free:
			parts.append("its required add-ons")
		var text := "The Font is generous to a town with no agents: %s cost nothing." % _join_and(parts)
		AgentUi.callout_text(_grace_banner).text = text


static func _join_and(parts: PackedStringArray) -> String:
	if parts.size() <= 1:
		return "".join(parts)
	return ", ".join(parts.slice(0, parts.size() - 1)) + " and " + parts[parts.size() - 1]


func _rebuild_harnesses() -> void:
	clear_box(_harness_row)
	_harness_cards.clear()
	var group := ButtonGroup.new()
	for pv: Variant in _providers:
		var p := J.d(pv)
		var id := J.gs(p, "id")
		if id == "":
			continue
		var state := AgentUi.harness_state(p)
		var card := ChoiceCard.new(look, 12)
		card.button_group = group
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.custom_minimum_size.x = 150
		var top := AgentUi.hbox(8)
		var n := AgentUi.label(AgentUi.harness_name(id).to_upper(), "CardTitle", top)
		n.add_theme_font_size_override("font_size", 15)
		var version := J.gs(p, "version")
		if version != "":
			var v := AgentUi.label("v" + version.trim_prefix("v"), "MonoSmall", top)
			v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		card.add(top)
		var srow := AgentUi.hbox(8)
		AgentUi.pill(AgentUi.harness_state_text(state), AgentUi.harness_state_color(state, look), state == "ready", srow)
		var bill := AgentUi.label(AgentUi.billing_name(J.gs(p, "billing_hint")), "MonoSmall", srow)
		bill.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		card.add(srow)
		var note := J.gs(p, "message")
		var tip := AgentUi.harness_name(id)
		if state == "ready":
			tip += "\n" + AgentUi.billing_note(J.gs(p, "billing_hint"))
		else:
			var why := note if note != "" else ("Install it, then check again." if state == "missing" else "Log in to it in a terminal, then check again.")
			tip += "\n" + why
			var w := AgentUi.label(why, "Hint")
			w.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			card.add(w)
		card.tooltip_text = tip
		card.set_locked(state != "ready")
		card.toggled.connect(_on_harness_toggled.bind(id))
		_harness_row.add_child(card)
		_harness_cards[id] = card
	_harness_note.visible = _harness_cards.is_empty()
	_harness_note.text = "No harness has reported in yet. Start the Town Hall, then check again."
	if not _provider_ready(provider):
		var first := ""
		for id: String in _harness_cards:
			if _provider_ready(id):
				first = id
				break
		_set_provider(first)
	for id: String in _harness_cards:
		(_harness_cards[id] as ChoiceCard).set_chosen(id == provider)


func _set_provider(id: String) -> void:
	if id == provider:
		return
	provider = id
	model = ""
	if is_inside_tree():
		_ensure_models(id)
	_apply_models_ui()
	_refresh_modes()
	_refresh_billing()


func _refresh_roles() -> void:
	var age := Realm.current_age()
	var count := Realm.agent_count()
	var have := _treasury()
	for r: String in _role_cards:
		var e: Dictionary = _role_cards[r]
		var card: ChoiceCard = e["card"]
		var locked := _role_locked(r)
		var cost := Economy.data.agent_cost(r, count)
		var free := _grace_frees("agent")
		AgentUi.fill_cost_row(e["cost"], cost, look, have, free, 15.0)
		(e["cost"] as HBoxContainer).mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ra := Economy.data.role_age(r)
		AgentUi.set_pill(e["age"], "Age %s" % AgeBadge.NUMERALS[clampi(ra - 1, 0, 4)],
			AgentTheme.c(look, "accent2") if locked else AgentTheme.c(look, "accent"), false)
		var tip := "%s\n%s. Lives in a %s.\nRequired add-ons: %s\nCost: %s" % [Economy.data.role_name(r), Economy.data.role_plain(r),
			Economy.data.building_name(Economy.data.role_home(r)), _names(Economy.data.role_tools(r, "required")), AgentUi.cost_text(cost)]
		if free:
			tip += "\nFree under Font's Grace."
		if locked:
			tip += "\nSummoned from the %s Age." % Economy.data.age_name(ra)
		card.tooltip_text = tip
		card.set_locked(locked)
	if role == "" or _role_locked(role):
		for r in Economy.data.role_names():
			if not _role_locked(r):
				role = r
				break
	for r: String in _role_cards:
		((_role_cards[r] as Dictionary)["card"] as ChoiceCard).set_chosen(r == role)


func _names(types: Array[String]) -> String:
	var out: PackedStringArray = []
	for t in types:
		out.append(AgentUi.structure_name(t))
	return ", ".join(out)


func _refresh_oath() -> void:
	if not _oath_edited:
		_oath_edit.text = AgentUi.oath_for(role, _name_edit.text.strip_edges())
	_count_oath()


func _count_oath() -> void:
	var note := AgentUi.section_note(_oath_section)
	if note != null:
		note.text = "%s / %s" % [AgentUi.group(_oath_edit.text.length()), AgentUi.group(OATH_MAX)]


## Why `mode` cannot be chosen now, or "".
func mode_block(mode: String) -> String:
	var d := Economy.data.approval_mode_def(mode)
	var age := int(d.get("age", 1))
	if age > Realm.current_age():
		return "Opens in the %s Age." % Economy.data.age_name(age)
	var first_rank := AgentUi.rank_order()[0]
	var min_rank := String(d.get("min_rank", first_rank))
	if not AgentUi.rank_at_least(first_rank, min_rank):
		return "Needs rank %s; a new agent starts at rank %s." % [min_rank, first_rank]
	var provs: Variant = d.get("providers")
	if typeof(provs) == TYPE_ARRAY and not (provs as Array).is_empty() and not provider in (provs as Array):
		var names: PackedStringArray = []
		for pid: Variant in provs:
			names.append(AgentUi.harness_name(J.s(pid)))
		return "Only for %s." % " and ".join(names)
	return ""


func _refresh_modes() -> void:
	var want := approval_mode
	_mode_select.clear()
	for m in Economy.data.approval_modes():
		var d := Economy.data.approval_mode_def(m)
		var why := mode_block(m)
		var tip := String(d.get("plain", ""))
		if why != "":
			tip += "\n" + why
		_mode_select.add_entry(String(d.get("name", m)) + ("   (%s)" % why.trim_suffix(".") if why != "" else ""), m, tip, why != "")
	if want == "" or mode_block(want) != "":
		want = Economy.data.default_approval_mode()
		if mode_block(want) != "":
			want = ""
			for m in Economy.data.approval_modes():
				if mode_block(m) == "":
					want = m
					break
	approval_mode = want
	_mode_select.select_value(want)
	_show_mode_hint()


func _show_mode_hint() -> void:
	var d := Economy.data.approval_mode_def(approval_mode)
	_mode_hint.text = String(d.get("plain", "")) + "."
	if approval_mode == "":
		_mode_hint.text = "No approval mode is open to this harness."


func _refresh_billing() -> void:
	var want := billing
	_billing_select.clear()
	var hint := J.gs(_provider_info(provider), "billing_hint")
	var default_text := "Town Hall default"
	if hint == Protocol.Billing.SUBSCRIPTION or hint == Protocol.Billing.API_KEY:
		default_text += " (%s detected)" % AgentUi.billing_name(hint).to_lower()
	_billing_select.add_entry(default_text, "", "Use the billing the Town Hall has set for this harness.")
	_billing_select.add_entry("Subscription", Protocol.Billing.SUBSCRIPTION, AgentUi.billing_note(Protocol.Billing.SUBSCRIPTION))
	_billing_select.add_entry("API key", Protocol.Billing.API_KEY, AgentUi.billing_note(Protocol.Billing.API_KEY))
	_billing_select.select_value(want)


func _rebuild_tools() -> void:
	var required := Economy.data.role_tools(role, "required")
	if _tools_role != role:
		_tools_role = role
		chosen_tools.clear()
		for t in required:
			if t != WAYGATE and not t in chosen_tools:
				chosen_tools.append(t)
		for t in Economy.data.role_tools(role, "default"):
			if t != WAYGATE and not t in chosen_tools:
				chosen_tools.append(t)
	clear_box(_tools_grid)
	_tool_cards.clear()
	var recommended := Economy.data.role_tools(role, "recommended")
	for t in Economy.data.tool_types():
		if t == WAYGATE:
			continue
		var card := ChoiceCard.new(look, 9)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.custom_minimum_size.x = 150
		var row := AgentUi.hbox(9)
		var icon := IconView.new(t, 38)
		row.add_child(icon)
		var col := AgentUi.vbox(1, row)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		AgentUi.label(AgentUi.addon_name(t).to_upper(), "CardTitle", col)
		var plain := AgentUi.label(AgentUi.addon_plain(t), "Hint", col)
		plain.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		card.add(row)
		var foot := AgentUi.hbox(8)
		foot.add_child(AgentUi.cost_row(AgentUi.addon_cost(t), look, {}, _grace_frees("required_tools") and t in required, 14.0))
		AgentUi.spacer(foot)
		if t in required:
			AgentUi.pill("Required", AgentTheme.c(look, "accent"), true, foot)
		elif t in recommended:
			AgentUi.pill("Recommended", AgentTheme.c(look, "accent2"), false, foot)
		card.add(foot)
		card.locked_on = t in required
		card.set_chosen(t in chosen_tools)
		var tip := "%s\n%s.\nCost: %s" % [AgentUi.addon_name(t), AgentUi.addon_plain(t), AgentUi.cost_text(AgentUi.addon_cost(t))]
		var needs := Economy.data.tool_requires(t)
		if not needs.is_empty():
			tip += "\nNeeds the %s first." % _names(needs)
		if t in required:
			tip += "\nRequired for a %s: always built." % Economy.data.role_name(role)
		card.tooltip_text = tip
		var tage := int(Economy.data.tool_def(t).get("age", 1))
		if tage > Realm.current_age():
			card.set_locked(true, tip + "\nBuilt from the %s Age." % Economy.data.age_name(tage))
		card.toggled.connect(_on_tool_toggled.bind(t))
		_tools_grid.add_child(card)
		_tool_cards[t] = card
	_refresh_tool_slots()


func _refresh_tool_slots() -> void:
	var slots := Economy.data.tool_slots(Realm.current_age())
	var note := AgentUi.section_note(_tools_section)
	if note != null:
		note.text = "%d / %d slots" % [chosen_tools.size(), slots]
	var full := chosen_tools.size() >= slots
	for t: String in _tool_cards:
		var card: ChoiceCard = _tool_cards[t]
		var tage := int(Economy.data.tool_def(t).get("age", 1))
		if tage > Realm.current_age():
			continue
		var blocked := full and not t in chosen_tools
		card.disabled = blocked
		card.content.modulate = Color(1, 1, 1, 0.42) if blocked else Color.WHITE
		card.set_chosen(t in chosen_tools)
	var hint := "Required add-ons are built first, once the home stands. The Waygate (MCP) needs its own setup, so add it from the home later."
	if WAYGATE in Economy.data.role_tools(role, "required"):
		hint = "A %s also needs a Waygate (MCP server); set it up from its home once it stands. Required add-ons are built first." % Economy.data.role_name(role)
	if full:
		hint += " Every slot of the %s Age is taken." % Economy.data.age_name(Realm.current_age())
	_tools_hint.text = hint


func _refresh_seal_usd() -> void:
	for sz: String in _seal_fields:
		var f: NumberField = _seal_fields[sz]
		(_seal_usd[sz] as Label).text = "= %s" % AgentUi.mana_usd(f.value)


func _treasury() -> Dictionary:
	return Economy.ledger.treasury() if Economy.ledger != null else {}


func _refresh_side() -> void:
	var nm := _name_edit.text.strip_edges()
	_preview_name.text = nm if nm != "" else "Unnamed"
	_preview_portrait.role = role
	_preview_role.text = "%s  ·  %s" % [Economy.data.role_name(role).to_upper(), Economy.data.role_plain(role).to_upper()] if role != "" else ""
	var model_text := _model_label(model) if model != "" else "no model yet"
	_preview_harness.text = "%s  ·  %s" % [AgentUi.harness_name(provider).to_upper(), model_text.to_upper()] if provider != "" else "CHOOSE A HARNESS"
	var age := Realm.current_age()
	var count := Realm.agent_count()
	var limit := Economy.data.agent_limit(age)
	_count_value.text = "%d / %d" % [count, limit]
	_count_value.add_theme_color_override("font_color", AgentTheme.c(look, "bad") if count >= limit else AgentTheme.c(look, "text"))

	clear_box(_cost_list)
	var have := _treasury()
	var total := {}
	var now := {}
	if role != "":
		var agent_cost := Economy.data.agent_cost(role, count)
		var agent_free := _grace_frees("agent")
		_cost_line("%s" % Economy.data.role_name(role), "Paid now", agent_cost, agent_free, have)
		if not agent_free:
			total = AgentUi.add_costs(total, agent_cost)
			now = agent_cost
		var home := Economy.data.role_home(role)
		var home_free := _grace_frees("home")
		_cost_line(Economy.data.building_name(home), "When placed", Economy.data.building_cost(home), home_free, have)
		if not home_free:
			total = AgentUi.add_costs(total, Economy.data.building_cost(home))
		var required := Economy.data.role_tools(role, "required")
		for t in _ordered_tools():
			var free := _grace_frees("required_tools") and t in required
			_cost_line(AgentUi.addon_name(t), "When built", AgentUi.addon_cost(t), free, have)
			if not free:
				total = AgentUi.add_costs(total, AgentUi.addon_cost(t))
	clear_box(_total_row)
	var tl := AgentUi.label("TOTAL", "Section", _total_row)
	tl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	AgentUi.spacer(_total_row)
	_total_row.add_child(AgentUi.cost_row(total, look, have))
	clear_box(_have_row)
	var hl := AgentUi.label("TREASURY", "MonoSmall", _have_row)
	hl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	AgentUi.spacer(_have_row)
	_have_row.add_child(AgentUi.cost_row(have, look))
	var short_now := Economy.ledger.missing(now) if Economy.ledger != null else {}
	var short_all := Economy.ledger.missing(total) if Economy.ledger != null else {}
	if not short_now.is_empty():
		_afford_note.text = "Not enough to summon: %s short." % AgentUi.cost_text(short_now)
		_afford_note.add_theme_color_override("font_color", AgentTheme.c(look, "bad"))
	elif not short_all.is_empty():
		_afford_note.text = "You can summon now, but gather %s more before the home and add-ons are built." % AgentUi.cost_text(short_all)
		_afford_note.add_theme_color_override("font_color", AgentTheme.c(look, "warn"))
	elif total.is_empty():
		_afford_note.text = "Everything here is free."
		_afford_note.add_theme_color_override("font_color", AgentTheme.c(look, "good"))
	else:
		_afford_note.text = "The treasury covers all of it."
		_afford_note.add_theme_color_override("font_color", AgentTheme.c(look, "good"))


func _cost_line(what: String, when: String, cost: Dictionary, free: bool, have: Dictionary) -> void:
	var row := AgentUi.hbox(8, _cost_list)
	var col := AgentUi.vbox(0, row)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var n := AgentUi.label(what, "Body", col)
	n.add_theme_font_size_override("font_size", 14)
	AgentUi.label(when.to_upper(), "MonoSmall", col).add_theme_font_size_override("font_size", 9)
	var right := AgentUi.vbox(2, row)
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	var chips := AgentUi.cost_row(cost, look, have, free, 14.0)
	chips.alignment = BoxContainer.ALIGNMENT_END
	right.add_child(chips)
	if free:
		var fr := AgentUi.hbox(0, right)
		fr.alignment = BoxContainer.ALIGNMENT_END
		AgentUi.pill("Free: Font's Grace", UiTokens.GOLD_BRIGHT, true, fr)


## The chosen add-ons in build order: required ones first, then the others by type order.
func _ordered_tools() -> Array[String]:
	var out: Array[String] = []
	for t in Economy.data.role_tools(role, "required"):
		if t in chosen_tools and not t in out:
			out.append(t)
	for t in Economy.data.tool_types():
		if t in chosen_tools and not t in out:
			out.append(t)
	return out


# --- models --------------------------------------------------------------------------------------------

func _ensure_models(id: String) -> void:
	if id == "" or _models.has(id) or _loading.has(id):
		_apply_models_ui()
		return
	_loading[id] = true
	_apply_models_ui()
	var req := request(Protocol.CMD_LIST_MODELS, {"provider": id})
	req.done.connect(_on_models.bind(id))


func _on_models(req: NetRequest, id: String) -> void:
	_loading.erase(id)
	if req.ok:
		_models[id] = J.a(req.payload_dict().get("models"))
		_model_errors.erase(id)
	else:
		_model_errors[id] = req.error_message()
	if id == provider:
		_apply_models_ui()


## The models of a harness, as list_models returned them (also used by tests and previews).
func apply_models(id: String, list: Array) -> void:
	_models[id] = list
	_loading.erase(id)
	_model_errors.erase(id)
	if id == provider:
		_apply_models_ui()


func _apply_models_ui() -> void:
	_model_select.clear()
	var list: Array = _models.get(provider, [])
	if provider == "":
		_model_select.visible = true
		_model_edit.visible = false
		_model_select.add_entry("Choose a harness first", "", "", true)
		_model_select.disabled = true
		_model_hint.text = ""
		model = ""
	elif _loading.has(provider):
		_model_select.visible = true
		_model_edit.visible = false
		_model_select.add_entry("Asking %s for its models..." % AgentUi.harness_name(provider), "", "", true)
		_model_select.disabled = true
		_model_hint.text = "LOADING"
		model = ""
	elif list.is_empty():
		_model_select.visible = false
		_model_edit.visible = true
		model = _model_edit.text.strip_edges()
		var err := String(_model_errors.get(provider, ""))
		_model_hint.text = ("NO MODEL LIST: %s TYPE AN ID." % err.to_upper()) if err != "" else "THIS HARNESS LISTS NO MODELS: TYPE AN ID."
	else:
		_model_select.visible = true
		_model_select.disabled = false
		_model_edit.visible = false
		var pick := -1
		var fallback := -1
		for m: Variant in list:
			var md := J.d(m)
			var id := J.gs(md, "id")
			if id == "":
				continue
			var label_text := J.gs(md, "label", id)
			var hint := J.gs(md, "cost_hint")
			var i := _model_select.add_entry(label_text + ("    " + hint if hint != "" else ""), id, hint)
			if id == model:
				pick = i
			if fallback < 0 and J.b(md.get("default"), false):
				fallback = i
		if pick < 0:
			pick = fallback if fallback >= 0 else 0
		_model_select.select(pick)
		_on_model_selected(pick)
		return
	_validate()
	_refresh_side()


func _on_model_selected(idx: int) -> void:
	model = _model_select.value()
	var list: Array = _models.get(provider, [])
	var label_text := model
	var hint := ""
	for m: Variant in list:
		var md := J.d(m)
		if J.gs(md, "id") == model:
			label_text = J.gs(md, "label", model)
			hint = J.gs(md, "cost_hint")
	if idx >= 0:
		_model_select.text = label_text
	_model_hint.text = ("COST  " + hint.to_upper()) if hint != "" else model.to_upper()
	_validate()
	_refresh_side()


## The label list_models gave `id`, or the id itself.
func _model_label(id: String) -> String:
	for m: Variant in _models.get(provider, []):
		if J.gs(J.d(m), "id") == id:
			return J.gs(J.d(m), "label", id)
	return id


func _on_model_typed(t: String) -> void:
	model = t.strip_edges()
	_validate()
	_refresh_side()


# --- events -------------------------------------------------------------------------------------------

func _on_realm_changed(kind: String, _id: String) -> void:
	match kind:
		"all", "age":
			_refresh_all()
		"providers":
			_providers = Realm.providers.duplicate()
			_rebuild_harnesses()
			_refresh_modes()
			_refresh_billing()
			_refresh_side()
			_validate()
		"agent":
			_refresh_header()
			_refresh_roles()
			_rebuild_tools()
			_refresh_side()
			_validate()


func _on_treasury_changed(_t: Dictionary, _reason: String, _delta: Dictionary) -> void:
	_refresh_roles()
	_refresh_side()
	_validate()


func _on_harness_toggled(on: bool, id: String) -> void:
	if on:
		_set_provider(id)
		_refresh_side()
		_validate()


func _on_role_toggled(on: bool, r: String) -> void:
	if not on or r == role:
		return
	role = r
	_refresh_oath()
	_rebuild_tools()
	_refresh_side()
	_validate()


func _on_name_changed(t: String) -> void:
	_name_count.text = "%d / %d" % [t.length(), NAME_MAX]
	if not _oath_edited:
		_refresh_oath()
	_refresh_side()
	_validate()


func _reroll_name() -> void:
	_name_edit.text = AgentUi.random_name(_taken_names() + [_name_edit.text])
	_on_name_changed(_name_edit.text)


func _on_oath_changed() -> void:
	if _oath_edit.text.length() > OATH_MAX:
		var line := _oath_edit.get_caret_line()
		var column := _oath_edit.get_caret_column()
		_oath_edit.text = _oath_edit.text.substr(0, OATH_MAX)
		_oath_edit.set_caret_line(mini(line, _oath_edit.get_line_count() - 1))
		_oath_edit.set_caret_column(column)
	_oath_edited = _oath_edit.text != AgentUi.oath_for(role, _name_edit.text.strip_edges())
	_count_oath()
	_validate()


func _on_path_typed(t: String) -> void:
	workspace_path = t.strip_edges()
	workspace_git = -1
	_show_path_hint()
	_validate()


## Sets the work folder (the browser, tests). git: 1 repository, 0 plain folder, -1 unknown.
func set_workspace(path: String, git: int = -1) -> void:
	workspace_path = path.strip_edges()
	workspace_git = git
	if _path_edit.text != workspace_path:
		_path_edit.text = workspace_path
	_show_path_hint()
	_validate()


func _show_path_hint() -> void:
	if workspace_path == "":
		_path_hint.text = "Required. The agent can read and change files only inside this folder."
	elif workspace_git == 1:
		_path_hint.text = "A git repository: the agent works on its own branch and you merge what you accept."
	elif workspace_git == 0:
		_path_hint.text = "A plain folder: the agent works on a copy, and accepted work is exported back as files."
	else:
		_path_hint.text = "The Town Hall checks the folder when you summon: git repositories get their own branch, plain folders a copy."


func browse_folder() -> void:
	var fb := FolderBrowser.new()
	fb.link = link
	fb.requester = requester
	fb.start_path = workspace_path
	fb.chosen.connect(_on_folder_chosen.bind(fb))
	open_window(fb)


func _on_folder_chosen(path: String, fb: FolderBrowser) -> void:
	set_workspace(path, fb.chosen_git)


func _on_mode_selected(_idx: int) -> void:
	approval_mode = _mode_select.value()
	_show_mode_hint()
	_validate()


func _on_billing_selected(_idx: int) -> void:
	billing = _billing_select.value()


func _on_seal_changed(_v: float, _size: String) -> void:
	_refresh_seal_usd()


func _on_advanced_toggled(on: bool) -> void:
	_adv_box.visible = on
	_adv_toggle.text = "HIDE ADVANCED" if on else "SHOW ADVANCED"


func _on_tool_toggled(on: bool, t: String) -> void:
	var card: ChoiceCard = _tool_cards[t]
	if card.locked_on:
		return
	if on and not t in chosen_tools:
		chosen_tools.append(t)
		for need in Economy.data.tool_requires(t):
			if not need in chosen_tools:
				chosen_tools.append(need)
	elif not on:
		chosen_tools.erase(t)
		for other: String in chosen_tools.duplicate():
			if t in Economy.data.tool_requires(other) and not (_tool_cards.has(other) and (_tool_cards[other] as ChoiceCard).locked_on):
				chosen_tools.erase(other)
	var slots := Economy.data.tool_slots(Realm.current_age())
	while chosen_tools.size() > slots:
		chosen_tools.pop_back()
	_refresh_tool_slots()
	_refresh_side()
	_validate()


# --- summoning ----------------------------------------------------------------------------------------

## Mana seals that differ from the defaults, or {}.
func seal_patch() -> Dictionary:
	var out := {}
	for sz: String in _seal_fields:
		var v := int((_seal_fields[sz] as NumberField).value)
		if v != Economy.data.seal_mana(sz):
			out[sz] = v
	return out


## The create_agent spec the form describes.
func build_spec() -> Dictionary:
	var spec := {
		"name": _name_edit.text.strip_edges(),
		"provider": provider,
		"model": model,
		"role": role,
		"instructions": _oath_edit.text.strip_edges(),
		"approval_mode": approval_mode,
		"workspace": {"path": workspace_path},
		"starting_tools": _ordered_tools(),
	}
	var seals := seal_patch()
	if not seals.is_empty():
		spec["seals"] = seals
	if billing != "":
		spec["billing"] = billing
	return spec


## What still stops the summoning, or "" when the form is valid.
func validation_problem() -> String:
	var age := Realm.current_age()
	var limit := Economy.data.agent_limit(age)
	if Realm.agent_count() >= limit:
		return "The %s Age allows %d agents. Advance the age to summon more." % [Economy.data.age_name(age), limit]
	if provider == "":
		return "Choose a harness that is ready."
	if not _provider_ready(provider):
		return "%s is not ready." % AgentUi.harness_name(provider)
	if model == "":
		return "Waiting for the model list." if _loading.has(provider) else "Choose a model."
	if _name_edit.text.strip_edges() == "":
		return "Give the agent a name."
	if role == "" or _role_locked(role):
		return "Choose a role."
	if workspace_path == "":
		return "Choose a work folder."
	if approval_mode == "" or mode_block(approval_mode) != "":
		return "Choose an approval mode."
	if not _grace_frees("agent") and Economy.ledger != null:
		var short := Economy.ledger.missing(Economy.data.agent_cost(role, Realm.agent_count()))
		if not short.is_empty():
			return "Not enough to summon: %s short." % AgentUi.cost_text(short)
	return ""


func can_summon() -> bool:
	return not _busy and validation_problem() == ""


func _validate() -> void:
	if _summon_button == null:
		return
	var problem := validation_problem()
	_summon_button.disabled = _busy or problem != ""
	_summon_button.tooltip_text = problem if problem != "" else "Summon the agent (Enter)"
	if not _busy:
		set_status(problem if problem != "" else "Ready. The agent trains at the Keep, then asks you for a plot.", "" if problem != "" else "good")


func summon() -> void:
	if not can_summon():
		return
	_busy = true
	_validate()
	set_status("The Font stirs...", "busy")
	var req: NetRequest = the_link().summon(build_spec())
	if req == null:
		_busy = false
		_validate()
		return
	req.done.connect(_on_summoned)


func _on_summoned(req: NetRequest) -> void:
	_busy = false
	if req.ok:
		var id := J.gs(req.payload_dict(), "agent_id")
		summoned.emit(id)
		close()
		return
	_validate()
	set_status(_error_text(req), "error")
	match req.error_code():
		Protocol.ERR_WORKSPACE_DENIED:
			_path_edit.grab_focus()
		Protocol.ERR_PROVIDER_UNAVAILABLE:
			check_harnesses()


func _error_text(req: NetRequest) -> String:
	match req.error_code():
		Protocol.ERR_WORKSPACE_DENIED:
			return "The Town Hall refused that folder: %s" % req.error_message()
		Protocol.ERR_INSUFFICIENT_RESOURCES:
			return "Not enough resources: %s" % req.error_message()
		Protocol.ERR_LIMIT_REACHED:
			return "No room for another agent: %s" % req.error_message()
		Protocol.ERR_AGE_REQUIRED, Protocol.ERR_RANK_REQUIRED:
			return "Not yet: %s" % req.error_message()
		Protocol.ERR_PROVIDER_UNAVAILABLE:
			return "The harness is not available: %s" % req.error_message()
	return req.error_message()


## Asks the Town Hall to look for harnesses again (check_providers).
func check_harnesses() -> void:
	set_status("Looking for harnesses...", "busy")
	var req := request(Protocol.CMD_CHECK_PROVIDERS)
	req.done.connect(_on_checked)


func _on_checked(req: NetRequest) -> void:
	if not req.ok:
		set_status(req.error_message(), "error")
		return
	var list := J.a(req.payload_dict().get("providers"))
	if not list.is_empty():
		_providers = list
	_models.clear()
	_model_errors.clear()
	_refresh_all()
	_ensure_models(provider)


func _window_key(event: InputEventKey) -> bool:
	if (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER) and not event.ctrl_pressed and not event.shift_pressed:
		if typing_in_text_edit():
			return false
		if can_summon():
			summon()
		return true
	return false
