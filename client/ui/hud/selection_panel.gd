class_name SelectionPanel
extends PanelContainer
## Middle of the bottom panel: portrait and stats for one selected unit, building or resource;
## a grid of portraits for several units; a few hints when nothing is selected.

const NAMES := ["Tobin", "Mira", "Aldric", "Wren", "Isolde", "Bram", "Elsa", "Corin", "Maren", "Pell",
	"Ysolde", "Hugo", "Ilse", "Rowan", "Tamsin", "Oswin", "Nell", "Gerrit", "Liesl", "Dunstan",
	"Hedda", "Anselm", "Brisa", "Cato", "Odile", "Fenn", "Greta", "Lorcan", "Runa", "Talia"]
const NODE_NAMES := {"tree": "Tree", "berry_bush": "Berry bush"}
const REFRESH_S := 0.1

var selection: Selection
var input: RtsInput

var _content: VBoxContainer
var _updater: Callable
var _timer: float = 0.0


static func unit_name(id: int) -> String:
	return NAMES[id % NAMES.size()]


func _ready() -> void:
	theme_type_variation = "InsetPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 6)
	margin.add_child(_content)


func bind(sel: Selection, rts_input: RtsInput) -> void:
	selection = sel
	input = rts_input
	selection.changed.connect(rebuild)
	rebuild()


func rebuild() -> void:
	for c in _content.get_children():
		c.queue_free()
	_updater = Callable()
	var w := Game.world
	if w == null or selection == null:
		return
	var ids := selection.ids
	if ids.is_empty():
		_build_empty(w)
	elif ids.size() == 1:
		var id := ids[0]
		if w.units.has(id):
			_build_unit(w, id)
		elif w.buildings.has(id):
			_build_building(w, id)
		elif w.nodes.has(id):
			_build_node(w, id)
	else:
		_build_group(w, ids)
	if _updater.is_valid():
		_updater.call()


func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = REFRESH_S
	if _updater.is_valid():
		_updater.call()


# --- layouts ----------------------------------------------------------------------------------

func _row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	_content.add_child(row)
	return row


func _column(parent: Control) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(col)
	return col


func _label(parent: Control, text: String, variation: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l


func _bar(parent: Control) -> ProgressBar:
	var p := ProgressBar.new()
	p.show_percentage = false
	p.custom_minimum_size = Vector2(220, 12)
	p.max_value = 1.0
	p.step = 0.0
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	parent.add_child(p)
	return p


func _build_empty(w: SimWorld) -> void:
	var row := _row()
	var p := Portrait.new(104)
	p.show_icon("keep")
	row.add_child(p)
	var col := _column(row)
	_label(col, "THE TOWN OF AURELHAVEN", "TitleLabel")
	_label(col, "%s Age  -  %d townsfolk  -  %d buildings" % [w.econ.age_name(w.age), w.unit_count("townsfolk"), w.buildings.size()], "MutedLabel")
	_label(col, "Left-click to select, drag to box-select, right-click to give orders. Select townsfolk and press Q, W or E to build. H selects the Keep and . finds idle townsfolk.", "BodyLabel")


func _build_unit(w: SimWorld, id: int) -> void:
	var u: SimUnit = w.units[id]
	var row := _row()
	var p := Portrait.new(104)
	p.show_unit(id)
	row.add_child(p)
	var col := _column(row)
	_label(col, unit_name(id).to_upper(), "TitleLabel")
	_label(col, "TOWNSPERSON" if u.kind == "townsfolk" else u.kind.to_upper(), "MutedLabel")
	var state := _label(col, "", "BodyLabel")
	var carry_row := HBoxContainer.new()
	carry_row.add_theme_constant_override("separation", 8)
	col.add_child(carry_row)
	var carry_icon := IconView.new("", 18)
	carry_row.add_child(carry_icon)
	var carry_bar := _bar(carry_row)
	carry_bar.custom_minimum_size = Vector2(160, 10)
	carry_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var carry_text := _label(carry_row, "", "MonoLabel")
	_label(col, "SPEED %.1f TILES/S   CARRIES %d" % [w.econ.walk_speed(u.kind), w.econ.carry_capacity(w.age)], "MutedLabel")
	_updater = func() -> void:
		var uu: SimUnit = w.units.get(id)
		if uu == null:
			return
		state.text = describe_unit(w, uu)
		var cap := w.econ.carry_capacity(w.age)
		carry_icon.icon = uu.carry_res if uu.is_carrying() else ""
		carry_bar.value = clampf(uu.carry_m / 1000.0 / float(cap), 0.0, 1.0)
		carry_text.text = "%d/%d %s" % [uu.carry_amount(), cap, uu.carry_res.capitalize() if uu.is_carrying() else "carried"]


static func describe_unit(w: SimWorld, u: SimUnit) -> String:
	match u.job:
		SimConst.JOB_IDLE:
			return "Idle: waiting for orders." if u.hold else "Idle: looking for work."
		SimConst.JOB_MOVE:
			return "Walking."
		SimConst.JOB_GATHER:
			var what := _gather_label(w, u)
			match u.phase:
				GatherJob.GATHERING:
					return "Farming." if u.gather_kind == "farm" else "Gathering %s." % what
				GatherJob.TO_DROP:
					var d: SimBuilding = w.buildings.get(u.drop_id)
					return "Carrying %d %s to the %s." % [u.carry_amount(), u.carry_res.capitalize(),
						w.econ.building_name(d.type) if d != null else "drop-off"]
				_:
					return "Heading to the %s." % what
		SimConst.JOB_BUILD:
			var b: SimBuilding = w.buildings.get(u.target_id)
			var bname := w.econ.building_name(b.type) if b != null else "site"
			if u.phase == BuildJob.BUILDING and b != null:
				return "Building the %s (%d%%)." % [bname, int(b.progress() * 100.0)]
			return "Walking to the %s site." % bname
		SimConst.JOB_DEPOSIT:
			return "Returning goods."
		SimConst.JOB_COURIER:
			return "Carrying a scroll."
	return ""


static func _gather_label(w: SimWorld, u: SimUnit) -> String:
	match u.gather_kind:
		"tree":
			return "wood"
		"berry_bush":
			return "berries"
		"farm":
			return "farm"
	return w.econ.node_resource(u.gather_kind)


func _build_building(w: SimWorld, id: int) -> void:
	var b: SimBuilding = w.buildings[id]
	var row := _row()
	var p := Portrait.new(104)
	p.show_icon(b.type)
	row.add_child(p)
	var col := _column(row)
	_label(col, w.econ.building_name(b.type).to_upper(), "TitleLabel")
	var plain := w.econ.building_plain(b.type)
	_label(col, plain.to_upper() if plain != "" else "", "MutedLabel")
	if not b.complete:
		var status := _label(col, "", "BodyLabel")
		var bar := _bar(col)
		_label(col, "Cancelling refunds everything.", "MutedLabel")
		_updater = func() -> void:
			var bb: SimBuilding = w.buildings.get(id)
			if bb == null:
				return
			var builders := 0
			for u: SimUnit in w.units.values():
				if u.job == SimConst.JOB_BUILD and u.target_id == id and u.phase == BuildJob.BUILDING:
					builders += 1
			bar.value = bb.progress()
			status.text = "Under construction: %d%%, %d builder%s." % [int(bb.progress() * 100.0), builders, "" if builders == 1 else "s"]
		return
	if SimWorld.TRAINERS.has(b.type):
		_build_trainer(w, b, col)
		return
	var info := _label(col, "", "BodyLabel")
	_updater = func() -> void:
		var bb: SimBuilding = w.buildings.get(id)
		if bb == null:
			return
		if w.econ.building_is_field(bb.type):
			var f: SimUnit = w.units.get(bb.farmer_id)
			var worked := f != null and not w.farm_is_free(bb, 0)
			info.text = "Endless food at %.2f per second for one farmer. %s" % [w.econ.node_rate(bb.type),
				("Worked by %s." % unit_name(f.id)) if worked else "Free: right-click it with a townsperson."]
		elif bb.type == SimWorld.STOREHOUSE_TYPE:
			info.text = "Drop-off for %s. Adds %d storage to each." % [" and ".join(w.econ.building_dropoffs(bb.type)).capitalize(),
				int(w.econ.raw["storage"]["storehouse_bonus"])]
		elif w.econ.building_pop(bb.type) > 0:
			info.text = "Raises the population cap by %d." % w.econ.building_pop(bb.type)
		else:
			info.text = ""


func _build_trainer(w: SimWorld, b: SimBuilding, col: VBoxContainer) -> void:
	var id := b.id
	var queue_row := HBoxContainer.new()
	queue_row.add_theme_constant_override("separation", 6)
	col.add_child(queue_row)
	var slots: Array[Button] = []
	for i in w.econ.training_queue_max():
		var s := Button.new()
		s.theme_type_variation = "CardButton"
		s.custom_minimum_size = Vector2(40, 40)
		s.focus_mode = Control.FOCUS_NONE
		var icon := IconView.new("", 26)
		s.add_child(icon)
		icon.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		s.pressed.connect(func() -> void: Game.issue(GameCommands.cancel_train(id, i)))
		queue_row.add_child(s)
		slots.append(s)
	var head := _bar(col)
	var status := _label(col, "", "BodyLabel")
	var extra := _label(col, "", "MutedLabel")
	_updater = func() -> void:
		var bb: SimBuilding = w.buildings.get(id)
		if bb == null:
			return
		for i in slots.size():
			var has_item := i < bb.queue.size()
			var ic: IconView = slots[i].get_child(0)
			ic.icon = "townsfolk" if has_item else ""
			slots[i].disabled = not has_item
			slots[i].tooltip_text = "Townsperson in training. Click to cancel (full refund)." if has_item else ""
		head.value = bb.head_progress()
		if bb.queue.is_empty():
			status.text = "Nothing in training. Q trains a townsperson."
			status.add_theme_color_override("font_color", UiTokens.HUD_SUBTLE)
		elif bb.training_blocked:
			status.text = "Paused: need houses. Build a Cottage."
			status.add_theme_color_override("font_color", UiTokens.BAD)
		else:
			status.text = "Training a townsperson: %d%%" % int(bb.head_progress() * 100.0)
			status.add_theme_color_override("font_color", UiTokens.HUD_SUBTLE)
		var rally := "none" if bb.rally.is_empty() else ("on a resource" if int(bb.rally.get("target", 0)) != 0 else "set")
		extra.text = "RALLY %s   FOCUS %s   POPULATION %d/%d" % [rally.to_upper(), bb.gather_focus.to_upper(), w.pop_used(), w.pop_cap()]


func _build_node(w: SimWorld, id: int) -> void:
	var n: SimResourceNode = w.nodes[id]
	var row := _row()
	var p := Portrait.new(104)
	p.show_icon(n.kind)
	row.add_child(p)
	var col := _column(row)
	_label(col, String(NODE_NAMES.get(n.kind, n.kind.capitalize())).to_upper(), "TitleLabel")
	var res := w.econ.node_resource(n.kind)
	_label(col, "%s SOURCE, %.2f PER SECOND" % [res.to_upper(), w.econ.node_rate(n.kind)], "MutedLabel")
	var status := _label(col, "", "BodyLabel")
	var bar := _bar(col)
	_updater = func() -> void:
		var nn: SimResourceNode = w.nodes.get(id)
		if nn == null:
			status.text = "Gone."
			return
		if nn.depleted:
			var secs := int(ceil(float(nn.regrow_ticks) / float(w.tick_rate)))
			status.text = "Used up. Regrows in %d:%02d." % [secs / 60, secs % 60]
			bar.value = 0.0
		else:
			status.text = "%d of %d %s left." % [nn.amount(), nn.max_m / 1000, res.capitalize()]
			bar.value = float(nn.amount_m) / float(maxi(nn.max_m, 1))


func _build_group(w: SimWorld, ids: Array[int]) -> void:
	var header := _label(_content, "", "TitleLabel")
	var summary := _label(_content, "", "MutedLabel")
	var grid := GridContainer.new()
	grid.columns = 14
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	_content.add_child(grid)
	for id in ids.slice(0, 42):
		var b := Button.new()
		b.theme_type_variation = "FlatButton"
		b.custom_minimum_size = Vector2(38, 38)
		b.focus_mode = Control.FOCUS_NONE
		var portrait := Portrait.new(34)
		if w.units.has(id):
			portrait.show_unit(id)
			b.tooltip_text = unit_name(id)
		elif w.buildings.has(id):
			portrait.show_icon((w.buildings[id] as SimBuilding).type)
		b.add_child(portrait)
		portrait.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		b.pressed.connect(func() -> void:
			if Input.is_key_pressed(KEY_SHIFT):
				selection.toggle(id)
			else:
				selection.set_ids([id]))
		grid.add_child(b)
	_updater = func() -> void:
		var counts := {}
		var n := 0
		for id in selection.ids:
			var u: SimUnit = w.units.get(id)
			if u == null:
				continue
			n += 1
			var key := "idle" if u.is_idle() else ("gathering" if u.job == SimConst.JOB_GATHER else ("building" if u.job == SimConst.JOB_BUILD else "walking"))
			counts[key] = int(counts.get(key, 0)) + 1
		header.text = "%d TOWNSFOLK" % n if n > 0 else "%d BUILDINGS" % selection.ids.size()
		var parts: PackedStringArray = []
		for key in ["gathering", "building", "walking", "idle"]:
			if counts.has(key):
				parts.append("%s %d" % [String(key).to_upper(), int(counts[key])])
		summary.text = "   ".join(parts)
