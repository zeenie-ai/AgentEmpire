class_name BottomPanel
extends PanelContainer
## The bottom panel: minimap, selection details and the command card. The phone layout takes the
## frames out and places them itself (Hud); dock() puts them back.

var minimap: Minimap
var selection_panel: SelectionPanel
var command_card: CommandCard
## The insets around the minimap and the command card.
var map_frame: PanelContainer
var card_frame: PanelContainer

var _row: HBoxContainer


func _ready() -> void:
	theme_type_variation = "HudPanel"
	custom_minimum_size = Vector2(0, UiTokens.BOTTOM_PANEL_HEIGHT)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 14)
	add_child(_row)
	map_frame = PanelContainer.new()
	map_frame.theme_type_variation = "InsetPanel"
	minimap = Minimap.new()
	map_frame.add_child(minimap)
	_row.add_child(map_frame)
	selection_panel = SelectionPanel.new()
	_row.add_child(selection_panel)
	card_frame = PanelContainer.new()
	card_frame.theme_type_variation = "InsetPanel"
	command_card = CommandCard.new()
	card_frame.add_child(command_card)
	command_card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_row.add_child(card_frame)


## Puts the minimap, the selection details and the command card back in the panel, in that
## order.
func dock() -> void:
	var parts: Array[Control] = [map_frame, selection_panel, card_frame]
	for i in parts.size():
		if parts[i].get_parent() != _row:
			parts[i].reparent(_row, false)
		_row.move_child(parts[i], i)
