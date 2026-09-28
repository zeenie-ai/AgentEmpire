class_name BottomPanel
extends PanelContainer
## The bottom panel: minimap, selection details and the command card.

var minimap: Minimap
var selection_panel: SelectionPanel
var command_card: CommandCard


func _ready() -> void:
	theme_type_variation = "HudPanel"
	custom_minimum_size = Vector2(0, UiTokens.BOTTOM_PANEL_HEIGHT)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	add_child(row)
	var map_frame := PanelContainer.new()
	map_frame.theme_type_variation = "InsetPanel"
	minimap = Minimap.new()
	map_frame.add_child(minimap)
	row.add_child(map_frame)
	selection_panel = SelectionPanel.new()
	row.add_child(selection_panel)
	var card_frame := PanelContainer.new()
	card_frame.theme_type_variation = "InsetPanel"
	command_card = CommandCard.new()
	card_frame.add_child(command_card)
	command_card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(card_frame)
