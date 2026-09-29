class_name ApprovalTray
extends VBoxContainer
## The stack of petitions (pending approvals), oldest first: up to MAX_VISIBLE ApprovalCards,
## then a plate saying how many more wait. One card is open (the oldest, or the one the player
## clicked); the others fold to a single line, so the stack stays short. The HUD anchors it
## top-right under the top bar; it grows down and to the left and lets the mouse through where
## it is empty. Live from Realm: new petitions pop in, answered ones fade out.

signal focus_requested(agent_id: String)
## The number of pending approvals changed.
signal count_changed(count: int)

const MAX_VISIBLE := 4
const WIDTH := 420.0

var link: Object = null
## The petition shown open; the others are folded to one line.
var open_id: String = ""

var _cards: Dictionary = {}
var _header: PanelContainer
var _header_label: Label
var _more: PanelContainer
var _more_label: Label
var _count: int = -1


func _init() -> void:
	theme = AgentTheme.theme(AgentTheme.STATUS)
	custom_minimum_size = Vector2(WIDTH, 0)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 10)
	_header = _plate()
	var hrow := AgentUi.hbox(10, _header)
	hrow.add_child(Glyph.new("scroll", UiTokens.GOLD_BRIGHT, 16))
	_header_label = AgentUi.label("", "Section", hrow)
	_header_label.add_theme_color_override("font_color", UiTokens.GOLD_BRIGHT)
	_header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var hint := AgentUi.label("OLDEST FIRST", "MonoSmall", hrow)
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_header)
	_more = _plate()
	var mrow := AgentUi.hbox(8, _more)
	mrow.alignment = BoxContainer.ALIGNMENT_CENTER
	mrow.add_child(Glyph.new("plus", UiTokens.MINT, 12))
	_more_label = AgentUi.label("", "Section", mrow)
	add_child(_more)
	_header.visible = false
	_more.visible = false


func _plate() -> PanelContainer:
	var p := PanelContainer.new()
	var box := ThemeBuilder.status_box(UiTokens.GOLD)
	box.content_margin_top = 6
	box.content_margin_bottom = 6
	box.shadow_size = 6.0
	p.add_theme_stylebox_override("panel", box)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	return p


func _enter_tree() -> void:
	for pair: Array in [[Realm.approval_requested, _on_requested], [Realm.approval_resolved, _on_resolved], [Realm.changed, _on_changed]]:
		var sig: Signal = pair[0]
		var fn: Callable = pair[1]
		if not sig.is_connected(fn):
			sig.connect(fn)
	sync()


func _exit_tree() -> void:
	for pair: Array in [[Realm.approval_requested, _on_requested], [Realm.approval_resolved, _on_resolved], [Realm.changed, _on_changed]]:
		var sig: Signal = pair[0]
		var fn: Callable = pair[1]
		if sig.is_connected(fn):
			sig.disconnect(fn)


func _on_requested(_a: Dictionary) -> void:
	sync()


func _on_resolved(_id: String, _info: Dictionary) -> void:
	sync()


func _on_changed(kind: String, _id: String) -> void:
	if kind == "all" or kind == "approval" or kind == "agent":
		sync()


## Brings the cards in line with Realm.pending_approvals().
func sync() -> void:
	var pending := Realm.pending_approvals()
	var shown: Array[String] = []
	for a in pending.slice(0, MAX_VISIBLE):
		shown.append(J.gs(a, "id"))
	for id: String in _cards.keys():
		if not id in shown:
			_dismiss(_cards[id])
			_cards.erase(id)
	if not open_id in shown:
		open_id = shown[0] if not shown.is_empty() else ""
	var index := 1
	for a in pending.slice(0, MAX_VISIBLE):
		var id := J.gs(a, "id")
		var card: ApprovalCard = _cards.get(id)
		if card == null:
			card = ApprovalCard.new().setup(a, link)
			card.focus_requested.connect(func(agent_id: String) -> void: focus_requested.emit(agent_id))
			card.expand_requested.connect(open)
			_cards[id] = card
			add_child(card)
			_pop_in(card)
		card.expanded = id == open_id
		move_child(card, index)
		index += 1
	move_child(_more, get_child_count() - 1)
	var extra := pending.size() - shown.size()
	_more.visible = extra > 0
	_more_label.text = "%d MORE PETITION%s WAITING" % [extra, "" if extra == 1 else "S"]
	_header.visible = not pending.is_empty()
	_header_label.text = "PETITIONS  %d" % pending.size()
	if pending.size() != _count:
		_count = pending.size()
		count_changed.emit(_count)


func card_for(approval_id: String) -> ApprovalCard:
	return _cards.get(approval_id)


## Opens one petition (the others fold to a line). The oldest is open by default.
func open(approval_id: String) -> void:
	open_id = approval_id
	sync()


func card_count() -> int:
	return _cards.size()


func _pop_in(c: Control) -> void:
	c.modulate.a = 0.0
	c.scale = Vector2(0.94, 0.94)
	var tw := c.create_tween().set_parallel(true).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(c, "modulate:a", 1.0, 0.18)
	tw.tween_property(c, "scale", Vector2.ONE, 0.26)


func _dismiss(c: Control) -> void:
	if not is_instance_valid(c):
		return
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tw := c.create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_property(c, "modulate:a", 0.0, 0.22)
	tw.tween_property(c, "scale", Vector2(0.96, 0.96), 0.22)
	tw.chain().tween_callback(c.queue_free)
