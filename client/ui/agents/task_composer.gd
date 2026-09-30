class_name TaskComposer
extends WindowFrame
## The quest scroll: writes a task for one agent and sends it by courier through
## Game.link.assign_task(agent_id, {title, prompt, size, acceptance?, rite?, express?}).
##
## The head shows the agent (portrait, name, role, harness, what it is doing) and its home's
## queue against the age's limit. The scroll holds the title (required, up to 200), the quest
## itself (required, up to 32,000), the size (Errand, Quest, Expedition, Campaign, each with its
## bounty and the agent's Mana seal), acceptance criteria (up to 20) and an optional Rite
## command. It previews who carries the scroll (a townsperson, a Font Wisp or Express) and warns
## when the free Mana pool holds less than a quarter of the seal. Ctrl+Enter sends. On success:
## sent(task_id), close. Live from Realm (the agent, its tasks, Mana, settings).

signal sent(task_id: String)

const Protocol = preload("res://net/protocol.gd")
const TITLE_MAX := 200
const PROMPT_MAX := 32000
const CRITERIA_MAX := 20
const CRITERION_MAX := 500
const RITE_MAX := 1000

var agent_id: String = ""
var task_size: String = "M"

var title_edit: LineEdit
var prompt_edit: TextEdit
var rite_edit: LineEdit
var express_check: CheckToggle

var _portrait: AgentPortrait
var _name_label: Label
var _role_label: Label
var _status_dot: Glyph
var _status_label: Label
var _queue_value: Label
var _queue_note: Label
var _title_section: HBoxContainer
var _prompt_section: HBoxContainer
var _size_cards: Dictionary = {}
var _criteria_section: HBoxContainer
var _criteria_list: VBoxContainer
var _add_criterion: Button
var _courier_box: PanelContainer
var _courier_glyph: Glyph
var _courier_label: Label
var _mana_warning: PanelContainer
var _send_button: Button
var _busy: bool = false
var _tick: float = 0.0


func _init() -> void:
	super()
	configure("Quest Scroll", "A task for an agent", AgentTheme.DOCUMENT, 900)
	set_title_icon(Glyph.new("scroll", UiTokens.BTN, 34))
	_build_head()
	_build_body()
	var cancel := add_button("Cancel", "ghost")
	cancel.pressed.connect(close)
	add_key_hint("CTRL+ENTER")
	_send_button = add_button("Send the scroll", "primary", "Send it by courier (Ctrl+Enter)")
	_send_button.custom_minimum_size.x = 190
	_send_button.pressed.connect(send)


## Writes a task for `id`. Returns the window, so the host can open it in one line.
func setup(id: String, link_override: Object = null) -> TaskComposer:
	agent_id = id
	if link_override != null:
		link = link_override
	var a := Realm.agent(id)
	set_title("Quest Scroll", "A task for %s" % J.gs(a, "name", "an agent"))
	_refresh()
	return self


func _window_opened() -> void:
	listen(Realm.changed, _on_realm_changed)
	listen(Realm.task_progress, _on_progress)
	_refresh()
	title_edit.grab_focus.call_deferred()


# --- building ---------------------------------------------------------------------------------------

func _build_head() -> void:
	var row := AgentUi.hbox(16, head)
	_portrait = AgentPortrait.new(72)
	row.add_child(_portrait)
	var col := AgentUi.vbox(3, row)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_name_label = AgentUi.label("", "Display", col)
	_name_label.add_theme_font_size_override("font_size", 26)
	_role_label = AgentUi.label("", "MonoSmall", col)
	var srow := AgentUi.hbox(7, col)
	_status_dot = Glyph.new("dot", AgentTheme.c(look, "good"), 10)
	srow.add_child(_status_dot)
	_status_label = AgentUi.label("", "BodyItalic", srow)
	_status_label.add_theme_font_size_override("font_size", 14)
	var qbox := PanelContainer.new()
	qbox.add_theme_stylebox_override("panel", AgentTheme.group_box(look))
	qbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(qbox)
	var qcol := AgentUi.vbox(0, qbox)
	var ql := AgentUi.label("HOME QUEUE", "MonoSmall", qcol)
	ql.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_queue_value = AgentUi.label("", "Value", qcol)
	_queue_value.add_theme_font_size_override("font_size", 22)
	_queue_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_queue_note = AgentUi.label("", "MonoSmall", qcol)
	_queue_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	show_head(true)


func _build_body() -> void:
	_title_section = AgentUi.section("Title", look, "0 / %d" % TITLE_MAX, body)
	title_edit = LineEdit.new()
	title_edit.max_length = TITLE_MAX
	title_edit.placeholder_text = "Fix the login redirect loop"
	title_edit.add_theme_font_override("font", UiFonts.spectral("SemiBold"))
	title_edit.add_theme_font_size_override("font_size", 18)
	title_edit.custom_minimum_size.y = 42
	title_edit.text_changed.connect(_on_title_changed)
	body.add_child(title_edit)

	_prompt_section = AgentUi.section("The quest", look, "0 / %s" % AgentUi.group(PROMPT_MAX), body)
	prompt_edit = QuestScrollEdit.new()
	prompt_edit.custom_minimum_size = Vector2(0, 200)
	prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	prompt_edit.placeholder_text = "What needs doing, where, and how you will know it is done. The more the agent knows, the less it guesses."
	prompt_edit.text_changed.connect(_on_prompt_changed)
	body.add_child(prompt_edit)

	AgentUi.section("Size", look, "Bounty and Mana seal", body)
	var sizes := AgentUi.hbox(10, body)
	var group := ButtonGroup.new()
	for sz in Economy.data.task_sizes():
		var card := ChoiceCard.new(look, 10)
		card.button_group = group
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.custom_minimum_size.x = 140
		card.content.add_theme_constant_override("separation", 3)
		var letter := AgentUi.label(sz, "")
		letter.add_theme_font_override("font", UiFonts.cinzel(800, 1))
		letter.add_theme_font_size_override("font_size", 26)
		letter.add_theme_color_override("font_color", AgentTheme.c(look, "accent"))
		letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.add(letter)
		var n := AgentUi.label(Economy.data.size_name(sz).to_upper(), "CardTitle")
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.add(n)
		var bounty := AgentUi.hbox(5)
		bounty.alignment = BoxContainer.ALIGNMENT_CENTER
		bounty.add_child(Glyph.new("coin", UiTokens.GOLD_DEEP, 13))
		var bl := AgentUi.label("BOUNTY %s" % AgentUi.group(Economy.data.bounty_base(sz)), "MonoSmall", bounty)
		bl.add_theme_color_override("font_color", AgentTheme.c(look, "soft"))
		card.add(bounty)
		var seal := AgentUi.hbox(5)
		seal.alignment = BoxContainer.ALIGNMENT_CENTER
		seal.add_child(Glyph.new("mana", Color("#3aa6b9"), 13))
		var sl := AgentUi.label("", "MonoSmall", seal)
		sl.name = "Seal"
		sl.add_theme_color_override("font_color", AgentTheme.c(look, "soft"))
		card.add(seal)
		var usd := AgentUi.label("", "MonoSmall")
		usd.name = "Usd"
		usd.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.add(usd)
		card.toggled.connect(_on_size_toggled.bind(sz))
		card.tooltip_text = "%s (%s)\nThe bounty is the base reward before quality, speed and practice bonuses.\nThe seal is the most Mana this task may spend before it pauses and asks you." % [Economy.data.size_name(sz), sz]
		sizes.add_child(card)
		_size_cards[sz] = card

	_criteria_section = AgentUi.section("Acceptance criteria", look, "Optional", body)
	_criteria_list = AgentUi.vbox(6, body)
	var arow := AgentUi.hbox(10, body)
	_add_criterion = Button.new()
	_add_criterion.theme_type_variation = "ChipButton"
	_add_criterion.text = "+  ADD A CRITERION"
	_add_criterion.focus_mode = Control.FOCUS_NONE
	_add_criterion.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_add_criterion.pressed.connect(_on_add_criterion)
	arow.add_child(_add_criterion)
	var ahint := AgentUi.label("What must be true when the work is done. The agent checks each one.", "Hint", arow)
	ahint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	var rs := AgentUi.section("Rite", look, "Optional", body)
	var info := Glyph.new("info", AgentTheme.c(look, "muted"), 14)
	info.mouse_filter = Control.MOUSE_FILTER_PASS
	info.tooltip_text = "The Rite\nA command the Town Hall runs in the agent's workspace when the work is done, for example npm test or cargo test. A passing Rite raises the reward, and its output appears in the review."
	rs.add_child(info)
	rs.move_child(info, 1)
	rite_edit = LineEdit.new()
	rite_edit.max_length = RITE_MAX
	rite_edit.placeholder_text = "npm test"
	rite_edit.add_theme_font_override("font", UiFonts.mono(500, 0))
	rite_edit.add_theme_font_size_override("font_size", 14)
	rite_edit.tooltip_text = info.tooltip_text
	rite_edit.text_changed.connect(func(_t: String) -> void: _validate())
	body.add_child(rite_edit)

	_courier_box = PanelContainer.new()
	_courier_box.add_theme_stylebox_override("panel", AgentTheme.callout_box(look, AgentTheme.c(look, "info")))
	body.add_child(_courier_box)
	var crow := AgentUi.hbox(12, _courier_box)
	_courier_glyph = Glyph.new("person", AgentTheme.c(look, "info"), 20)
	crow.add_child(_courier_glyph)
	var ccol := AgentUi.vbox(1, crow)
	ccol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	AgentUi.label("COURIER", "Section", ccol).add_theme_color_override("font_color", AgentTheme.c(look, "info"))
	_courier_label = AgentUi.para("", "Body", ccol)
	express_check = CheckToggle.new("Express", look)
	express_check.tooltip_text = "Skip the walk: the scroll appears at the agent's home at once."
	express_check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	express_check.toggled.connect(func(_on: bool) -> void: _refresh_courier())
	crow.add_child(express_check)

	_mana_warning = AgentUi.callout(look, AgentTheme.c(look, "warn"), "", "Low Mana", "warning", body)
	_mana_warning.visible = false


# --- refresh --------------------------------------------------------------------------------------------

func _refresh() -> void:
	if agent_id == "":
		return
	var a := Realm.agent(agent_id)
	_portrait.set_agent(a, String(AgentUi.agent_status(a, the_link()).get("mood", "")))
	_name_label.text = J.gs(a, "name", "Unknown agent")
	_role_label.text = "%s  ·  %s  ·  %s" % [Economy.data.role_name(J.gs(a, "role")).to_upper(),
		AgentUi.harness_name(J.gs(a, "provider")).to_upper(), J.gs(a, "model").to_upper()]
	_refresh_status()
	_refresh_queue()
	_refresh_sizes()
	_refresh_courier()
	_refresh_mana()
	_validate()


func _refresh_status() -> void:
	var st := AgentUi.agent_status(Realm.agent(agent_id), the_link())
	_status_label.text = String(st.get("text", ""))
	var col := AgentUi.mood_color(String(st.get("mood", "")), look)
	_status_dot.color = col
	_status_label.add_theme_color_override("font_color", col.darkened(0.15) if look == AgentTheme.DOCUMENT else col)


func queue_limit() -> int:
	return Economy.data.home_task_queue(Realm.current_age())


func queue_full() -> bool:
	return AgentUi.waiting_count(agent_id) >= queue_limit()


func _refresh_queue() -> void:
	var n := AgentUi.waiting_count(agent_id)
	var limit := queue_limit()
	_queue_value.text = "%d / %d" % [n, limit]
	_queue_value.add_theme_color_override("font_color", AgentTheme.c(look, "bad") if n >= limit else AgentTheme.c(look, "text"))
	_queue_note.text = "FULL" if n >= limit else ("%d FREE" % (limit - n))


func _seal_of(sz: String) -> int:
	var seals := J.gd(Realm.agent(agent_id), "seals")
	return J.gi(seals, sz, Economy.data.seal_mana(sz))


func _refresh_sizes() -> void:
	for sz: String in _size_cards:
		var card: ChoiceCard = _size_cards[sz]
		var seal := _seal_of(sz)
		(card.find_child("Seal", true, false) as Label).text = "SEAL %s MANA" % AgentUi.group(seal)
		(card.find_child("Usd", true, false) as Label).text = "= %s" % AgentUi.mana_usd(float(seal))
		card.set_chosen(sz == task_size)


func _refresh_courier() -> void:
	var c := courier_preview()
	_courier_glyph.glyph = String(c["glyph"])
	_courier_label.text = String(c["text"])
	var forced := J.b(Realm.settings.get("express_dispatch"), false)
	express_check.disabled = forced
	if forced and not express_check.button_pressed:
		express_check.set_pressed_no_signal(true)
		express_check.queue_redraw()


## Who will carry the scroll now: {"mode": "human"|"wisp"|"express"|"hall", "glyph", "text"}.
func courier_preview() -> Dictionary:
	var a := Realm.agent(agent_id)
	var who := J.gs(a, "name", "the agent")
	var home_name := Economy.data.building_name(Economy.data.role_home(J.gs(a, "role")))
	if J.b(Realm.settings.get("express_dispatch"), false):
		return {"mode": "express", "glyph": "express", "text": "Express dispatch is on for the town: the scroll reaches %s's %s at once." % [who, home_name]}
	if express_check != null and express_check.button_pressed:
		return {"mode": "express", "glyph": "express", "text": "Express: the scroll appears at %s's %s at once, with no walk." % [who, home_name]}
	if typeof(a.get("home")) != TYPE_DICTIONARY:
		return {"mode": "hall", "glyph": "clock", "text": "%s has no home yet, so the Town Hall delivers the scroll itself within %d s." % [who, int(Economy.data.force_deliver_after_s())]}
	var l := the_link()
	var carrier: Variant = l.call("pick_courier") if l != null and l.has_method("pick_courier") else null
	if carrier is Object and carrier != null:
		var cid := J.i((carrier as Object).get("id"))
		return {"mode": "human", "glyph": "person", "text": "%s will carry the scroll from the Keep to %s's %s." % [SelectionPanel.unit_name(cid), who, home_name]}
	return {"mode": "wisp", "glyph": "wisp", "text": "Every townsperson is busy: a Font Wisp will carry the scroll in about %d s." % int(Economy.data.wisp_after_s())}


func _refresh_mana() -> void:
	var m := Realm.mana
	if m.is_empty():
		_mana_warning.visible = false
		return
	var seal := _seal_of(task_size)
	var fraction := float(Economy.data.section("mana").get("start_min_fraction_of_seal", 0.25))
	var need := int(ceil(float(seal) * fraction))
	var left := int(floor(AgentUi.mana_of(J.gi(m, "remaining_micros"))))
	_mana_warning.visible = left < need
	if _mana_warning.visible:
		AgentUi.callout_text(_mana_warning).text = "The Mana pool holds %s; a %s needs at least %s to start (a quarter of its %s Mana seal). It will wait in the queue until the pool refills or you raise it." % [
			AgentUi.group(left), Economy.data.size_name(task_size), AgentUi.group(need), AgentUi.group(seal)]


# --- fields -----------------------------------------------------------------------------------------------

func _on_title_changed(t: String) -> void:
	AgentUi.section_note(_title_section).text = "%d / %d" % [t.length(), TITLE_MAX]
	_validate()


func _on_prompt_changed() -> void:
	if prompt_edit.text.length() > PROMPT_MAX:
		var line := prompt_edit.get_caret_line()
		var column := prompt_edit.get_caret_column()
		prompt_edit.text = prompt_edit.text.substr(0, PROMPT_MAX)
		prompt_edit.set_caret_line(mini(line, prompt_edit.get_line_count() - 1))
		prompt_edit.set_caret_column(column)
	AgentUi.section_note(_prompt_section).text = "%s / %s" % [AgentUi.group(prompt_edit.text.length()), AgentUi.group(PROMPT_MAX)]
	_validate()


func _on_size_toggled(on: bool, sz: String) -> void:
	if on:
		select_size(sz)


func select_size(sz: String) -> void:
	task_size = sz
	_refresh_sizes()
	_refresh_mana()
	_validate()


## Adds an acceptance criterion row (up to 20).
func add_criterion(text: String = "") -> LineEdit:
	if _criteria_list.get_child_count() >= CRITERIA_MAX:
		return null
	var row := AgentUi.hbox(8, _criteria_list)
	var gem := Glyph.new("diamond", AgentTheme.c(look, "accent"), 10)
	row.add_child(gem)
	var edit := LineEdit.new()
	edit.max_length = CRITERION_MAX
	edit.text = text
	edit.placeholder_text = "For example: the tests pass and no new warnings appear"
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text_changed.connect(func(_t: String) -> void: _validate())
	row.add_child(edit)
	var remove := Button.new()
	remove.theme_type_variation = "IconButton"
	remove.focus_mode = Control.FOCUS_NONE
	remove.custom_minimum_size = Vector2(32, 32)
	remove.tooltip_text = "Remove this criterion"
	remove.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	Glyph.inside(remove, "close", AgentTheme.c(look, "muted"), 10)
	remove.pressed.connect(_remove_criterion.bind(row))
	row.add_child(remove)
	_refresh_criteria()
	return edit


func _on_add_criterion() -> void:
	var e := add_criterion()
	if e != null:
		e.grab_focus()


func _remove_criterion(row: Control) -> void:
	_criteria_list.remove_child(row)
	row.queue_free()
	_refresh_criteria()


func _refresh_criteria() -> void:
	var n := _criteria_list.get_child_count()
	AgentUi.section_note(_criteria_section).text = ("%d / %d" % [n, CRITERIA_MAX]) if n > 0 else "Optional"
	_add_criterion.disabled = n >= CRITERIA_MAX
	_validate()


## The non-empty acceptance criteria.
func criteria() -> Array:
	var out: Array = []
	for row in _criteria_list.get_children():
		for c in row.get_children():
			if c is LineEdit:
				var t := (c as LineEdit).text.strip_edges()
				if t != "":
					out.append(t)
	return out


# --- sending -----------------------------------------------------------------------------------------------

## The assign_task spec the scroll describes (TownLink adds the courier).
func build_spec() -> Dictionary:
	var spec := {"title": title_edit.text.strip_edges(), "prompt": prompt_edit.text.strip_edges(), "size": task_size}
	var acc := criteria()
	if not acc.is_empty():
		spec["acceptance"] = acc
	var rite := rite_edit.text.strip_edges()
	if rite != "":
		spec["rite"] = rite
	if express_check.button_pressed:
		spec["express"] = true
	return spec


func validation_problem() -> String:
	var a := Realm.agent(agent_id)
	if a.is_empty():
		return "This agent is not in town."
	if J.gs(a, "lifecycle") == Protocol.AgentLifecycle.RETIRED:
		return "%s has retired." % J.gs(a, "name")
	if title_edit.text.strip_edges() == "":
		return "Give the quest a title."
	if prompt_edit.text.strip_edges() == "":
		return "Describe the quest."
	if queue_full():
		return "%s's home holds %d waiting scroll%s in the %s Age; wait for one to start." % [J.gs(a, "name"), queue_limit(),
			"" if queue_limit() == 1 else "s", Economy.data.age_name(Realm.current_age())]
	return ""


func can_send() -> bool:
	return not _busy and validation_problem() == ""


func _validate() -> void:
	if _send_button == null:
		return
	var problem := validation_problem()
	_send_button.disabled = _busy or problem != ""
	if not _busy:
		set_status(problem if problem != "" else "Ready to send.", "" if problem != "" else "good")


func send() -> void:
	if not can_send():
		return
	_busy = true
	_validate()
	set_status("Sealing the scroll...", "busy")
	var req: NetRequest = the_link().assign_task(agent_id, build_spec())
	if req == null:
		_busy = false
		_validate()
		return
	req.done.connect(_on_sent)


func _on_sent(req: NetRequest) -> void:
	_busy = false
	if req.ok:
		sent.emit(J.gs(req.payload_dict(), "task_id"))
		close()
		return
	_validate()
	var msg := req.error_message()
	if req.error_code() == Protocol.ERR_LIMIT_REACHED:
		msg = "The home's queue is full: %s" % msg
	set_status(msg, "error")


# --- events ------------------------------------------------------------------------------------------------

func _on_realm_changed(kind: String, id: String) -> void:
	match kind:
		"agent":
			if id == agent_id:
				_refresh()
		"task", "tool", "approval":
			_refresh_status()
			_refresh_queue()
			_validate()
		"mana":
			_refresh_mana()
		"all", "age", "settings":
			_refresh()


func _on_progress(task_id: String, _p: Dictionary) -> void:
	if task_id == J.gs(Realm.current_task(agent_id), "id"):
		_refresh_status()


func _process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = 1.0
	_refresh_courier()
	if J.gs(Realm.agent(agent_id), "lifecycle") == Protocol.AgentLifecycle.TRAINING:
		_refresh_status()


func _window_key(event: InputEventKey) -> bool:
	if (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER) and event.ctrl_pressed:
		send()
		return true
	return false


## The quest's text on ruled parchment: faint rules under each line and a red margin.
class QuestScrollEdit:
	extends TextEdit

	func _draw() -> void:
		var sb := get_theme_stylebox("normal")
		var top := sb.get_margin(SIDE_TOP)
		var left := sb.get_margin(SIDE_LEFT)
		var lh := float(get_line_height())
		if lh <= 1.0:
			return
		var frac := fmod(float(scroll_vertical), 1.0)
		var y := top + lh * (1.0 - frac) - 2.0
		var rule := Color(0.54, 0.35, 0.23, 0.16)
		while y < size.y - 4.0:
			draw_line(Vector2(left - 4.0, y), Vector2(size.x - 8.0, y), rule, 1.0)
			y += lh
		draw_line(Vector2(left - 6.0, 3.0), Vector2(left - 6.0, size.y - 3.0), Color(0.64, 0.2, 0.12, 0.28), 1.0)
