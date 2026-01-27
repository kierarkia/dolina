class_name InputBlock
extends PanelContainer

signal deleted_requested
signal content_changed

@onready var type_select: OptionButton = %TypeSelect
@onready var value_input: TextEdit = %ValueInput
@onready var column_select: OptionButton = %ColumnSelect
@onready var btn_delete: Button = %BtnDelete

enum Type { STATIC_TEXT, DATA_TEXT, DATA_IMAGE }

var available_columns: Array[String] = []

func _ready() -> void:
	btn_delete.pressed.connect(func(): deleted_requested.emit())
	
	# Setup Type Options
	type_select.clear()
	type_select.add_item("Static Prompt", Type.STATIC_TEXT)
	type_select.add_item("Column (Text)", Type.DATA_TEXT)
	type_select.add_item("Column (Image)", Type.DATA_IMAGE)
	
	type_select.item_selected.connect(_on_type_changed)
	type_select.item_selected.connect(func(_idx): content_changed.emit())
	column_select.item_selected.connect(func(_idx): content_changed.emit())
	
	if value_input.has_signal("text_changed"):
		value_input.text_changed.connect(func(): content_changed.emit())
	elif value_input.has_signal("text_submitted"): # Fallback if you revert to LineEdit
		value_input.text_changed.connect(func(_txt): content_changed.emit())

	_on_type_changed(0)

func setup_columns(cols: Array[String]) -> void:
	available_columns = cols
	column_select.clear()
	for c in cols:
		column_select.add_item(c.to_upper())

func _on_type_changed(idx: int) -> void:
	var id = type_select.get_item_id(idx)
	
	match id:
		Type.STATIC_TEXT:
			value_input.show()
			column_select.hide()
			value_input.placeholder_text = "Enter instruction (e.g. 'Describe this image')"
		Type.DATA_TEXT:
			value_input.hide()
			column_select.show()
		Type.DATA_IMAGE:
			value_input.hide()
			column_select.show()
			
	content_changed.emit()

# Returns the configuration of this block for the runner
func get_config() -> Dictionary:
	var type_id = type_select.get_selected_id()
	var data = { "type": type_id }
	
	if type_id == Type.STATIC_TEXT:
		data["value"] = value_input.text
	else:
		# Return the actual column name string
		if column_select.selected != -1:
			data["column"] = available_columns[column_select.selected]
		else:
			data["column"] = ""
			
	return data

func _get_drag_data(at_position: Vector2) -> Variant:
	# 1. Restrict dragging to the Handle area (left side)
	# This assumes the DragHandle label is on the far left.
	# 40px is a generous hit area for the handle "::"
	if at_position.x > 40:
		return null
		
	# 2. Create the Visual Preview
	var preview_ctrl = Control.new()
	
	# Create a visual representation (Simple semi-transparent box)
	var visual = Panel.new()
	visual.size = size # Match current block size
	visual.modulate = Color(1, 1, 1, 0.8)
	
	# Center the preview on mouse
	visual.position = -0.5 * visual.size
	
	preview_ctrl.add_child(visual)
	set_drag_preview(preview_ctrl)
	
	# 3. Return the Data Payload
	return { "type": "reorder_input_block", "node": self }

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	# Accept the drop IF:
	# 1. It is our custom type
	# 2. It isn't dropping onto itself
	return typeof(data) == TYPE_DICTIONARY and \
		   data.get("type") == "reorder_input_block" and \
		   data.node != self

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var parent_list = get_parent()
	var dragging_node = data.node
	var my_index = get_index()
	
	# Move the dragged node to this node's position
	parent_list.move_child(dragging_node, my_index)
	
	# Trigger the preview update

	content_changed.emit()
	
	# Also emit from the dragged node, just in case
	if dragging_node.has_signal("content_changed"):
		dragging_node.content_changed.emit()
