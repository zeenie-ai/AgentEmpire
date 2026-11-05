class_name SelectionPanel
extends PanelContainer
## Middle of the bottom panel: portrait and stats for one selected unit, building or resource;
## a grid of portraits for several units; a few hints when nothing is selected. An agent (its
## figure or its home) shows its AgentPanel (res://ui/agents/agent_panel.gd) when available,
## else a compact summary; an add-on shows what it grants.
##
## On phones it is compact (set_look()), above the command card and COMPACT_HEIGHT tall: a
## portrait, a title, one status line and a bar, with an X at the top right that clears the
## selection. A group shows its count instead of portraits, and the Keep its training queue. On
## phones and tablets the hints say Tap.

const NAMES := ["Tobin", "Mira", "Aldric", "Wren", "Isolde", "Bram", "Elsa", "Corin", "Maren", "Pell",
	"Ysolde", "Hugo", "Ilse", "Rowan", "Tamsin", "Oswin", "Nell", "Gerrit", "Liesl", "Dunstan",
	"Hedda", "Anselm", "Brisa", "Cato", "Odile", "Fenn", "Greta", "Lorcan", "Runa", "Talia"]
const NODE_NAMES := {"tree": "Tree", "berry_bush": "Berry bush"}

## The AgentPanel asked for a review or for the agent's approvals (the HUD opens them).
signal agent_review_requested(task_id: String)
signal agent_approvals_requested(agent_id: String)
const REFRESH_S := 0.1
## The compact panel's height and portrait.
const COMPACT_HEIGHT := 96.0
const COMPACT_PORTRAIT := 64.0

var selection: Selection
var input: RtsInput
## Phones: the compact panel.
var compact: bool = false
## Phones and tablets: hints name taps instead of clicks and keys.
var touch: bool = false

var _margin: MarginContainer
var _content: VBoxContainer
var _updater: Callable
var _timer: float = 0.0


static func unit_name(id: int) -> String:
	return NAMES[id % NAMES.size()]


func _ready() -> void:
	theme_type_variation = "InsetPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_margin = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		_margin.add_theme_constant_override("margin_" + side, 8)
	add_child(_margin)
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 6)
	_margin.add_child(_content)


func bind(sel: Selection, rts_input: RtsInput) -> void:
	selection = sel
	input = rts_input
	selection.changed.connect(rebuild)
	rebuild()


## Compact (phones) or full, and whether the hints name taps (phones and tablets).
func set_look(is_compact: bool, is_touch: bool) -> void:
	compact = is_compact
	touch = is_touch
	theme_type_variation = "FloatPanel" if compact else "InsetPanel"
	custom_minimum_size.y = COMPACT_HEIGHT if compact else 0.0
	for side in ["left", "right", "top", "bottom"]:
		_margin.add_theme_constant_override("margin_" + side, 0 if compact else 8)
	rebuild()


func rebuild() -> void:
	# Out of the panel at once, so the old view and the new one never share a frame.
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	_updater = Callable()
	var w := Game.world
	if w == null or selection == null:
		return
	var ids := selection.ids
	if ids.is_empty():
		if not compact:
			_build_empty(w)
	elif ids.size() == 1:
		var id := ids[0]
		var u: SimUnit = w.units.get(id)
		var b: SimBuilding = w.buildings.get(id)
		if u != null and u.kind == "agent":
			_build_agent(w, u.agent_id)
		elif b != null and b.owner_agent_id != "" and b.tool_id != "":
			_build_tool(w, id)
		elif b != null and b.owner_agent_id != "":
			_build_agent(w, b.owner_agent_id)
		elif u != null:
			_build_unit(w, id)
		elif b != null:
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
	row.add_theme_constant_override("separation", 10 if compact else 16)
	if compact:
		row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(row)
	return row


func _column(parent: Control) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3 if compact else 4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if compact:
		col.alignment = BoxContainer.ALIGNMENT_CENTER
	parent.add_child(col)
	return col


func _portrait() -> Portrait:
	var p := Portrait.new(COMPACT_PORTRAIT if compact else 104.0)
	if compact:
		p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return p


## A portrait beside a column of lines, on phones with the X at the right; returns the column.
func _view(portrait: Portrait) -> VBoxContainer:
	var row := _row()
	row.add_child(portrait)
	var col := _column(row)
	if compact:
		row.add_child(_close_button())
	return col


## The phone's X: clears the selection. A whole touch target in the panel's top-right corner, its
## glyph in the corner of the target, level with the title.
func _close_button() -> Button:
	var b := Button.new()
	b.theme_type_variation = "FlatButton"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(Platform.TOUCH_TARGET_DP, Platform.TOUCH_TARGET_DP)
	b.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	b.tooltip_text = "Clear the selection"
	var x := IconView.new("close", 16)
	b.add_child(x)
	x.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_KEEP_SIZE, 6)
	x.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	b.pressed.connect(func() -> void:
		if selection != null:
			selection.clear())
	return b


func _label(parent: Control, text: String, variation: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l


## One line at `font_size`, ending in an ellipsis when it does not fit (the compact panel).
func _line(parent: Control, text: String, variation: String, font_size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.add_theme_font_size_override("font_size", font_size)
	parent.add_child(l)
	return l


func _title(parent: Control, text: String) -> Label:
	return _line(parent, text, "TitleLabel", 15) if compact else _label(parent, text, "TitleLabel")


## The status line the updater fills in.
func _status(parent: Control) -> Label:
	return _line(parent, "", "BodyLabel", 14) if compact else _label(parent, "", "BodyLabel")


## A line of figures; the compact panel leaves it out.
func _stat(parent: Control, text: String) -> Label:
	var l := _label(parent, text, "MutedLabel")
	l.visible = not compact
	return l


func _bar(parent: Control) -> ProgressBar:
	var p := ProgressBar.new()
	p.show_percentage = false
	p.custom_minimum_size = Vector2(0, 8) if compact else Vector2(220, 12)
	p.max_value = 1.0
	p.step = 0.0
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL if compact else Control.SIZE_SHRINK_BEGIN
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
	if touch:
		_label(col, "Tap to select, then tap a tree, a bush or the ground to give orders. Drag to look around, pinch to zoom and twist to turn. Tap Select, then drag, to box a group.", "BodyLabel")
	else:
		_label(col, "Left-click to select, drag to box-select, right-click to give orders. Select townsfolk and press Q, W or E to build. H selects the Keep and . finds idle townsfolk.", "BodyLabel")


func _build_unit(w: SimWorld, id: int) -> void:
	var u: SimUnit = w.units[id]
	var p := _portrait()
	p.show_unit(id)
	var col := _view(p)
	_title(col, unit_name(id).to_upper())
	_stat(col, "TOWNSPERSON" if u.kind == "townsfolk" else u.kind.to_upper())
	var state := _status(col)
	var carry_row := HBoxContainer.new()
	carry_row.add_theme_constant_override("separation", 8)
	col.add_child(carry_row)
	var carry_icon := IconView.new("", 16 if compact else 18)
	carry_row.add_child(carry_icon)
	var carry_bar := _bar(carry_row)
	if not compact:
		carry_bar.custom_minimum_size = Vector2(160, 10)
	carry_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var carry_text := _label(carry_row, "", "MonoLabel")
	carry_text.autowrap_mode = TextServer.AUTOWRAP_OFF
	_stat(col, "SPEED %.1f TILES/S   CARRIES %d" % [w.econ.walk_speed(u.kind), w.econ.carry_capacity(w.age)])
	_updater = func() -> void:
		var uu: SimUnit = w.units.get(id)
		if uu == null:
			return
		state.text = describe_unit(w, uu)
		var cap := w.econ.carry_capacity(w.age)
		carry_icon.icon = uu.carry_res if uu.is_carrying() else ""
		carry_bar.value = clampf(uu.carry_m / 1000.0 / float(cap), 0.0, 1.0)
		if compact:
			carry_text.text = "%d/%d" % [uu.carry_amount(), cap]
		else:
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
	if compact and b.complete and SimWorld.TRAINERS.has(b.type):
		_build_trainer_compact(w, b)
		return
	var p := _portrait()
	p.show_icon(b.type)
	var col := _view(p)
	_title(col, w.econ.building_name(b.type).to_upper())
	var plain := w.econ.building_plain(b.type)
	_stat(col, plain.to_upper() if plain != "" else "")
	if not b.complete:
		var status := _status(col)
		var bar := _bar(col)
		_stat(col, "Cancelling refunds everything.")
		var form := "Building: %d%%, %d builder%s." if compact else "Under construction: %d%%, %d builder%s."
		_updater = func() -> void:
			var bb: SimBuilding = w.buildings.get(id)
			if bb == null:
				return
			var builders := 0
			for u: SimUnit in w.units.values():
				if u.job == SimConst.JOB_BUILD and u.target_id == id and u.phase == BuildJob.BUILDING:
					builders += 1
			bar.value = bb.progress()
			status.text = form % [int(bb.progress() * 100.0), builders, "" if builders == 1 else "s"]
		return
	if SimWorld.TRAINERS.has(b.type):
		_build_trainer(w, b, col)
		return
	var info := _status(col)
	_updater = func() -> void:
		var bb: SimBuilding = w.buildings.get(id)
		if bb == null:
			return
		info.text = _building_info(w, bb)


## What a finished building does; shorter on phones.
func _building_info(w: SimWorld, bb: SimBuilding) -> String:
	if w.econ.building_is_field(bb.type):
		var f: SimUnit = w.units.get(bb.farmer_id)
		var worked := f != null and not w.farm_is_free(bb, 0)
		if compact:
			return ("Worked by %s." % unit_name(f.id)) if worked else "No farmer yet."
		var free := "Free: tap it with a townsperson selected." if touch else "Free: right-click it with a townsperson."
		return "Endless food at %.2f per second for one farmer. %s" % [w.econ.node_rate(bb.type),
			("Worked by %s." % unit_name(f.id)) if worked else free]
	if bb.type == SimWorld.STOREHOUSE_TYPE:
		var dropoffs := " and ".join(w.econ.building_dropoffs(bb.type)).capitalize()
		if compact:
			return "Drop-off for %s." % dropoffs
		return "Drop-off for %s. Adds %d storage to each." % [dropoffs, int(w.econ.raw["storage"]["storehouse_bonus"])]
	if w.econ.building_pop(bb.type) > 0:
		return ("Population cap +%d." if compact else "Raises the population cap by %d.") % w.econ.building_pop(bb.type)
	return ""


func _build_trainer(w: SimWorld, b: SimBuilding, col: VBoxContainer) -> void:
	var id := b.id
	var queue_row := HBoxContainer.new()
	queue_row.add_theme_constant_override("separation", 6)
	col.add_child(queue_row)
	# On a tablet's touch screen the slots are whole touch targets; the panel has the room.
	var slots := _queue_slots(w, id, queue_row, Platform.TOUCH_TARGET_DP if touch else 40.0)
	var head := _bar(col)
	var status := _label(col, "", "BodyLabel")
	var extra := _label(col, "", "MutedLabel")
	var nothing := "Nothing in training. Tap Townsperson to train one." if touch else "Nothing in training. Q trains a townsperson."
	_updater = func() -> void:
		var bb: SimBuilding = w.buildings.get(id)
		if bb == null:
			return
		_show_queue(slots, bb)
		head.value = bb.head_progress()
		if bb.queue.is_empty():
			status.text = nothing
			status.add_theme_color_override("font_color", UiTokens.HUD_SUBTLE)
		elif bb.training_blocked:
			status.text = "Paused: need houses. Build a Cottage."
			status.add_theme_color_override("font_color", UiTokens.BAD)
		else:
			status.text = "Training a townsperson: %d%%" % int(bb.head_progress() * 100.0)
			status.add_theme_color_override("font_color", UiTokens.HUD_SUBTLE)
		var rally := "none" if bb.rally.is_empty() else ("on a resource" if int(bb.rally.get("target", 0)) != 0 else "set")
		extra.text = "RALLY %s   FOCUS %s   POPULATION %d/%d" % [rally.to_upper(), bb.gather_focus.to_upper(), w.pop_used(), w.pop_cap()]


## Phones: the training queue under the name and status, with the X at the right. The slot of the
## townsperson in training shows its progress.
func _build_trainer_compact(w: SimWorld, b: SimBuilding) -> void:
	var id := b.id
	var row := _row()
	var col := _column(row)
	col.add_theme_constant_override("separation", 6)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	col.add_child(top)
	var title := Label.new()
	title.text = w.econ.building_name(b.type).to_upper()
	title.theme_type_variation = "TitleLabel"
	title.add_theme_font_size_override("font_size", 15)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(title)
	var status := _line(top, "", "BodyLabel", 14)
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var queue_row := HBoxContainer.new()
	queue_row.add_theme_constant_override("separation", 4)
	col.add_child(queue_row)
	var slots := _queue_slots(w, id, queue_row, Platform.TOUCH_TARGET_DP)
	var head := ProgressBar.new()
	head.show_percentage = false
	head.max_value = 1.0
	head.step = 0.0
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slots[0].add_child(head)
	head.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	head.offset_left = 6
	head.offset_right = -6
	head.offset_top = -11
	head.offset_bottom = -6
	row.add_child(_close_button())
	_updater = func() -> void:
		var bb: SimBuilding = w.buildings.get(id)
		if bb == null:
			return
		_show_queue(slots, bb)
		head.visible = not bb.queue.is_empty()
		head.value = bb.head_progress()
		if bb.queue.is_empty():
			status.text = "Nothing in training."
			status.add_theme_color_override("font_color", UiTokens.HUD_SUBTLE)
		elif bb.training_blocked:
			status.text = "Paused: build a Cottage."
			status.add_theme_color_override("font_color", UiTokens.BAD)
		else:
			status.text = "Training: %d%%" % int(bb.head_progress() * 100.0)
			status.add_theme_color_override("font_color", UiTokens.HUD_SUBTLE)


## The training queue's slots, `side` square, in `parent`; a slot cancels its townsperson.
func _queue_slots(w: SimWorld, id: int, parent: Control, side: float) -> Array[Button]:
	var slots: Array[Button] = []
	for i in w.econ.training_queue_max():
		var s := Button.new()
		s.theme_type_variation = "CardButton"
		s.custom_minimum_size = Vector2(side, side)
		s.focus_mode = Control.FOCUS_NONE
		var icon := IconView.new("", 26)
		s.add_child(icon)
		icon.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		icon.grow_horizontal = Control.GROW_DIRECTION_BOTH
		icon.grow_vertical = Control.GROW_DIRECTION_BOTH
		s.pressed.connect(func() -> void: Game.issue(GameCommands.cancel_train(id, i)))
		parent.add_child(s)
		slots.append(s)
	return slots


func _show_queue(slots: Array[Button], bb: SimBuilding) -> void:
	for i in slots.size():
		var has_item := i < bb.queue.size()
		var ic: IconView = slots[i].get_child(0)
		ic.icon = "townsfolk" if has_item else ""
		slots[i].disabled = not has_item
		slots[i].tooltip_text = ("Townsperson in training. %s to cancel (full refund)." % ("Tap" if touch else "Click")) if has_item else ""


func _build_node(w: SimWorld, id: int) -> void:
	var n: SimResourceNode = w.nodes[id]
	var p := _portrait()
	p.show_icon(n.kind)
	var col := _view(p)
	_title(col, String(NODE_NAMES.get(n.kind, n.kind.capitalize())).to_upper())
	var res := w.econ.node_resource(n.kind)
	_stat(col, "%s SOURCE, %.2f PER SECOND" % [res.to_upper(), w.econ.node_rate(n.kind)])
	var status := _status(col)
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


func _build_agent(w: SimWorld, agent_id: String) -> void:
	if not Realm.agent(agent_id).is_empty() and not compact:
		var panel := AgentPanel.new()
		_content.add_child(panel)
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.setup(agent_id)
		panel.review_requested.connect(func(task_id: String) -> void: agent_review_requested.emit(task_id))
		panel.approvals_requested.connect(func(id: String) -> void: agent_approvals_requested.emit(id))
		return
	# Not known to the Town Hall (yet), or on a phone: a compact summary.
	var a := Realm.agent(agent_id)
	var p := _portrait()
	p.show_icon("agent_" + J.gs(a, "role", "artificer"))
	var col := _view(p)
	var title := _title(col, "")
	var sub := _stat(col, "")
	var state := _status(col)
	var bar := _bar(col)
	var extra := _stat(col, "")
	_updater = func() -> void:
		var ag := Realm.agent(agent_id)
		if ag.is_empty():
			title.text = "AGENT"
			state.text = "Waiting for the Town Hall."
			return
		title.text = J.gs(ag, "name").to_upper()
		sub.text = "%s  -  %s  -  %s  -  RANK %s  LEVEL %d" % [w.econ.role_name(J.gs(ag, "role")).to_upper(),
			J.gs(ag, "provider").to_upper(), J.gs(ag, "model"), J.gs(ag, "rank", "F"), J.gi(ag, "level", 1)]
		state.text = describe_agent(w, agent_id)
		var cur := Realm.headline_task(agent_id)
		if cur.is_empty():
			bar.value = 0.0
			extra.text = "%d ADD-ONS  -  NO TASK" % Realm.tools_of(agent_id).size()
		else:
			var seal := maxf(J.f(cur.get("seal_micros")), 1.0)
			bar.value = clampf(J.f(cur.get("spent_micros")) / seal, 0.0, 1.0)
			extra.text = "%s  -  MANA %d / %d" % [J.gs(cur, "title").to_upper(), int(J.f(cur.get("spent_micros")) / 10000.0), int(seal / 10000.0)]


## One line about what an agent is doing, for the panel and tooltips.
static func describe_agent(w: SimWorld, agent_id: String) -> String:
	var a := Realm.agent(agent_id)
	var home := w.agent_home(agent_id) if w != null else null
	# An agent on a harness the Town Hall no longer runs: what it finished, else that it can only be retired.
	if TownLink.unsupported(a):
		var done := AgentUi.review_task(agent_id)
		if not done.is_empty():
			return "Finished \"%s\": ready for review." % J.gs(done, "title")
		return AgentUi.blocked_text(J.gs(a, "blocked_reason"), a) + "."
	match J.gs(a, "lifecycle"):
		"training":
			return "Training at the Keep: %d s left." % int(ceil(Game.link.training_left_s(agent_id)))
		"settling":
			if home == null:
				return "Waiting for you to choose a plot (T)."
			var site := w.agent_next_site(agent_id)
			if site != null:
				return "Building the %s (%d%%)." % [w.econ.building_name(site.type), int(site.progress() * 100.0)]
			var wait: Dictionary = Game.link.waiting_tools.get(agent_id, {})
			if not wait.is_empty():
				return "Waiting for resources to build the %s." % w.econ.building_name(String(wait.get("tool", "")))
			return "Setting up the work folder."
		"retired":
			return "Retired."
	if not Realm.approvals_for(agent_id).is_empty():
		return "Waiting for your approval (Space)."
	for t in Realm.tasks_awaiting_review():
		if J.gs(t, "agent_id") == agent_id:
			return "Finished \"%s\": ready for review." % J.gs(t, "title")
	match J.gs(a, "activity"):
		"working":
			var cur := Realm.current_task(agent_id)
			var p: Dictionary = Realm.progress.get(J.gs(cur, "id"), {})
			var tool := J.gs(p, "current_tool")
			return "Working on \"%s\"%s." % [J.gs(cur, "title"), (": " + tool) if tool != "" else ""]
		"blocked":
			var reason := J.gs(a, "blocked_reason").replace("_", " ")
			return "Blocked: %s." % reason
	return "Idle. Send a task (Q)."


func _build_tool(w: SimWorld, id: int) -> void:
	var b: SimBuilding = w.buildings[id]
	var p := _portrait()
	p.show_icon(b.type)
	var col := _view(p)
	_title(col, w.econ.building_name(b.type).to_upper())
	var def := w.econ.tool_def(b.type)
	_stat(col, String(def.get("plain", "")).to_upper())
	var status := _status(col)
	var bar := _bar(col)
	_updater = func() -> void:
		var bb: SimBuilding = w.buildings.get(id)
		if bb == null:
			return
		var owner := J.gs(Realm.agent(bb.owner_agent_id), "name", "its agent")
		bar.visible = not bb.complete
		bar.value = bb.progress()
		if not bb.complete:
			status.text = "%s is building it: %d%%." % [owner, int(bb.progress() * 100.0)]
		else:
			status.text = "%s's add-on. %s" % [owner, _grants(def)]


static func _grants(def: Dictionary) -> String:
	var claude: Dictionary = def.get("claude", {})
	var tools: Array = claude.get("tools", [])
	if not tools.is_empty():
		return "Claude Code tools: %s." % ", ".join(PackedStringArray(tools))
	return String(def.get("plain", ""))


func _build_group(w: SimWorld, ids: Array[int]) -> void:
	var header: Label
	var summary: Label
	if compact:
		var p := _portrait()
		if w.units.has(ids[0]):
			p.show_unit(ids[0])
		elif w.buildings.has(ids[0]):
			p.show_icon((w.buildings[ids[0]] as SimBuilding).type)
		var col := _view(p)
		header = _title(col, "")
		summary = _line(col, "", "MutedLabel", 12)
	else:
		header = _label(_content, "", "TitleLabel")
		summary = _label(_content, "", "MutedLabel")
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
			portrait.grow_horizontal = Control.GROW_DIRECTION_BOTH
			portrait.grow_vertical = Control.GROW_DIRECTION_BOTH
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
