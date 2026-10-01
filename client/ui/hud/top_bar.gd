class_name TopBar
extends PanelContainer
## Age of Empires-style resource bar (layout after the handoff's V6 Hex Realm): Food, Wood,
## Stone and Gold with income per minute in the tooltips, population x/y (flashing at the cap),
## the idle-townsfolk counter, the Town Hall chip, the age badge and the Mana orb.

## The Mana orb was clicked.
signal budget_requested()
## The player chose practice ("fake") or real agents in the Town Hall chip's menu.
signal town_hall_mode_requested(mode: String)
## The player chose to close the Town Hall in the chip's menu.
signal town_hall_close_requested()

const HALL_PRACTICE := 1
const HALL_REAL := 2
const HALL_CLOSE := 3

const REFRESH_S := 0.25

var input: RtsInput

var _values: Dictionary = {}
var _chips: Dictionary = {}
var _pop_label: Label
var _pop_chip: Control
var _idle_button: Button
var _idle_label: Label
var _age: AgeBadge
var _mana: ManaOrb
var _hall: Button
var _hall_label: Label
var _hall_menu: PopupMenu
var _timer: float = 0.0
var _time: float = 0.0
var _pop_capped: bool = false


func _ready() -> void:
	theme_type_variation = "HudBar"
	custom_minimum_size = Vector2(0, UiTokens.TOP_BAR_HEIGHT)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	add_child(row)
	var mark := Label.new()
	mark.text = "AURELHAVEN"
	mark.theme_type_variation = "TitleLabel"
	mark.add_theme_font_size_override("font_size", 18)
	mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(mark)
	row.add_child(_divider())
	for res in Economy.data.resource_names():
		var chip := _chip(res, res)
		row.add_child(chip)
		_chips[res] = chip
	row.add_child(_divider())
	_pop_chip = _chip("pop", "pop")
	_pop_label = _values["pop"]
	row.add_child(_pop_chip)
	_idle_button = Button.new()
	_idle_button.theme_type_variation = "FlatButton"
	_idle_button.focus_mode = Control.FOCUS_NONE
	_idle_button.tooltip_text = "Idle townsfolk. Click or press . to cycle through them."
	var idle_row := HBoxContainer.new()
	idle_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	idle_row.add_theme_constant_override("separation", 6)
	idle_row.add_child(IconView.new("idle", 22))
	_idle_label = Label.new()
	_idle_label.theme_type_variation = "MonoLabel"
	_idle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	idle_row.add_child(_idle_label)
	_idle_button.add_child(idle_row)
	idle_row.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE, 6)
	_idle_button.custom_minimum_size = Vector2(92, 34)
	_idle_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_idle_button.pressed.connect(func() -> void:
		if input != null:
			input.select_next_idle())
	row.add_child(_idle_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	_hall = Button.new()
	_hall.theme_type_variation = "FlatButton"
	_hall.focus_mode = Control.FOCUS_NONE
	_hall.custom_minimum_size = Vector2(150, 34)
	_hall.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hall_label = Label.new()
	_hall_label.theme_type_variation = "MutedLabel"
	_hall_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hall_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hall_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hall.add_child(_hall_label)
	_hall_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hall.pressed.connect(_on_hall_pressed)
	row.add_child(_hall)
	_age = AgeBadge.new()
	row.add_child(_age)
	_mana = ManaOrb.new()
	_mana.pressed.connect(func() -> void: budget_requested.emit())
	row.add_child(_mana)
	Economy.treasury_changed.connect(func(_t: Dictionary, _r: String, _d: Dictionary) -> void: _refresh())
	Realm.mana_changed.connect(func(_m: Dictionary) -> void: _refresh_mana())
	Net.connection_changed.connect(func(_on: bool) -> void: _refresh_mana())
	Net.status_changed.connect(func(_s: String) -> void: _refresh_hall())
	Game.link.online_changed.connect(func(_on: bool) -> void: _refresh_hall())
	Game.link.town_available.connect(_refresh_hall)
	Game.town_hall_mode_changed.connect(func(_mode: String) -> void: _refresh_hall())
	_refresh()
	_refresh_mana()
	_refresh_hall()


func _refresh_mana() -> void:
	_mana.set_mana(Realm.mana_level(), Realm.mana if Net.is_online() else {})


## The Town Hall chip: whether the town is the Town Hall's, and what a click does.
func _refresh_hall() -> void:
	var text := "TOWN HALL OFFLINE"
	var color := UiTokens.HUD_MUTED
	var tip := "No Town Hall is running. Agents need it: start it with `npm start` in townhall/.
The town plays offline meanwhile."
	if TownHallLauncher.find_dir() != "":
		tip = "No Town Hall is running. Click to start it; the town plays offline meanwhile."
	match Net.status:
		Net.STATUS_ONLINE:
			if Game.is_online_town():
				if Game.town_hall_mode() == TownHallLauncher.MODE_FAKE:
					text = "PRACTICE TOWN"
					color = UiTokens.GOLD_BRIGHT
					tip = "Practice agents: a stand-in plays the agents' part, so nothing real runs and nothing is spent.\nClick to switch to real agents or to close the Town Hall."
				else:
					text = "TOWN HALL"
					color = UiTokens.MINT
					tip = "Real agents: they work in your folders on your Claude Code, Codex or pi sign-in.\nClick to switch to practice agents or to close the Town Hall."
			else:
				text = "OPEN TOWN HALL TOWN"
				color = UiTokens.GOLD_BRIGHT
				tip = "The Town Hall is running. Click to leave this offline town and open the Town Hall's town."
		Net.STATUS_CONNECTING:
			text = "CONNECTING..."
			tip = Net.last_problem if Net.last_problem != "" else "Connecting to the Town Hall."
		Net.STATUS_BUSY:
			text = "TAKE OVER"
			color = UiTokens.WARN
			tip = "Another Aurelhaven window is connected to the Town Hall. Click to take over."
		Net.STATUS_REJECTED:
			text = "TOWN HALL REFUSED"
			color = UiTokens.BAD
			tip = Net.last_problem
	_hall_label.text = text
	_hall_label.add_theme_color_override("font_color", color)
	_hall.tooltip_text = tip


func _on_hall_pressed() -> void:
	if Game.town_hall_busy():
		return
	match Net.status:
		Net.STATUS_BUSY:
			Net.take_over()
		Net.STATUS_ONLINE:
			if Game.is_online_town():
				_open_hall_menu()
			else:
				Game.switch_to_town_hall(int(Settings.get_value("game/seed", 4127)))
		_:
			# Start the Town Hall when this game can (the mode last chosen); otherwise look again.
			if TownHallLauncher.find_dir() != "":
				Game.open_town_hall()
			else:
				Net.reconnect_now()


## The chip's menu while a Town Hall's town is open: practice or real agents, or close it.
func _open_hall_menu() -> void:
	if _hall_menu == null:
		_hall_menu = PopupMenu.new()
		_hall_menu.id_pressed.connect(_on_hall_menu)
		add_child(_hall_menu)
	_hall_menu.clear()
	var mode := Game.town_hall_mode()
	_hall_menu.add_radio_check_item("Practice agents: nothing real runs", HALL_PRACTICE)
	_hall_menu.set_item_checked(_hall_menu.get_item_index(HALL_PRACTICE), mode == TownHallLauncher.MODE_FAKE)
	_hall_menu.add_radio_check_item("Real agents: Claude Code, Codex, pi", HALL_REAL)
	_hall_menu.set_item_checked(_hall_menu.get_item_index(HALL_REAL), mode == TownHallLauncher.MODE_REAL)
	_hall_menu.add_separator()
	_hall_menu.add_item("Close the Town Hall", HALL_CLOSE)
	var at := _hall.global_position + Vector2(0.0, _hall.size.y + 4.0)
	if not get_viewport().gui_embed_subwindows:
		at += Vector2(get_window().position)
	_hall_menu.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


func _on_hall_menu(id: int) -> void:
	var mode := Game.town_hall_mode()
	match id:
		HALL_PRACTICE:
			if mode != TownHallLauncher.MODE_FAKE:
				town_hall_mode_requested.emit(TownHallLauncher.MODE_FAKE)
		HALL_REAL:
			if mode != TownHallLauncher.MODE_REAL:
				town_hall_mode_requested.emit(TownHallLauncher.MODE_REAL)
		HALL_CLOSE:
			town_hall_close_requested.emit()


func _chip(key: String, icon: String) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.mouse_filter = Control.MOUSE_FILTER_PASS
	box.custom_minimum_size = Vector2(96 if key != "pop" else 88, 0)
	box.add_child(IconView.new(icon, 22))
	var label := Label.new()
	label.theme_type_variation = "MonoLabel"
	label.add_theme_font_size_override("font_size", 15)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_child(label)
	_values[key] = label
	return box


func _divider() -> Control:
	var d := ColorRect.new()
	d.color = UiTokens.HUD_BORDER
	d.custom_minimum_size = Vector2(1, 26)
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return d


func _process(delta: float) -> void:
	_time += delta
	_timer -= delta
	if _timer <= 0.0:
		_timer = REFRESH_S
		_refresh()
	if _pop_capped:
		var k := absf(sin(_time * 4.0))
		_pop_label.add_theme_color_override("font_color", UiTokens.HUD_TEXT.lerp(UiTokens.BAD, k))


func _refresh() -> void:
	var w := Game.world
	var t := Economy.ledger.treasury() if Economy.ledger != null else {}
	var storehouses := w.storehouse_count() if w != null else 0
	for res: String in _chips:
		var label: Label = _values[res]
		var amount := int(t.get(res, 0))
		label.text = str(amount)
		var cap := Economy.ledger.storage_cap(res, storehouses) if Economy.ledger != null else -1
		var full := cap >= 0 and amount >= cap
		label.add_theme_color_override("font_color", UiTokens.WARN if full else UiTokens.HUD_TEXT)
		var tip := "%s: %d" % [res.capitalize(), amount]
		if cap >= 0:
			tip += " / %d stored%s" % [cap, " (full: build a Storehouse)" if full else ""]
		if res in Economy.data.gatherable_resources():
			var income := Game.income.per_minute(res, w.tick) if w != null else 0
			tip += "\nIncome: +%d per minute" % income
		else:
			tip += "\nEarned from agents' accepted work (with the Town Hall)."
		(_chips[res] as Control).tooltip_text = tip
	if w == null:
		return
	var used := w.pop_used()
	var cap := w.pop_cap()
	_pop_label.text = "%d/%d" % [used, cap]
	var keep := w.keep()
	_pop_capped = used >= cap and keep != null and not keep.queue.is_empty()
	if not _pop_capped:
		_pop_label.add_theme_color_override("font_color", UiTokens.WARN if used >= cap else UiTokens.HUD_TEXT)
	var limit := w.econ.pop_limit(w.age)
	_pop_chip.tooltip_text = "Population %d / %d\nThe Keep gives %d and each Cottage %d, up to %d in this age.%s" % [
		used, cap, w.econ.building_pop("keep"), w.econ.building_pop("cottage"), limit,
		"\nTraining is paused: build a Cottage." if _pop_capped else ""]
	var idle := w.idle_townsfolk().size()
	_idle_label.text = "Idle %d" % idle
	_idle_label.add_theme_color_override("font_color", UiTokens.GOLD_BRIGHT if idle > 0 else UiTokens.HUD_MUTED)
	_age.set_age(w.age, w.econ.age_name(w.age))
