class_name CommandCard
extends GridContainer
## The 5x3 command card. Slots come from CommandCardModel; clicks and hotkeys (card_0..card_14,
## Q W E R T / A S D F G / Z X C V B) both end in RtsInput.activate().

const REFRESH_S := 0.2

var input: RtsInput
var selection: Selection

var _buttons: Array[CardButton] = []
var _slots: Array[Dictionary] = []
var _timer: float = 0.0


func _ready() -> void:
	columns = 5
	add_theme_constant_override("h_separation", 6)
	add_theme_constant_override("v_separation", 6)
	for i in CommandCardModel.SLOTS:
		var b := CardButton.new(i)
		b.pressed.connect(_on_pressed.bind(i))
		add_child(b)
		_buttons.append(b)


func bind(sel: Selection, rts_input: RtsInput) -> void:
	selection = sel
	input = rts_input
	selection.changed.connect(refresh)
	Economy.treasury_changed.connect(func(_t: Dictionary, _r: String, _d: Dictionary) -> void: refresh())
	refresh()


func refresh() -> void:
	if selection == null:
		return
	_slots = CommandCardModel.slots(Game.world, selection.ids)
	for i in _buttons.size():
		_buttons[i].set_slot(_slots[i] if i < _slots.size() else {})


func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_timer = REFRESH_S
		refresh()


func _on_pressed(i: int) -> void:
	if input != null and i < _slots.size() and not _slots[i].is_empty():
		input.activate(_slots[i])
