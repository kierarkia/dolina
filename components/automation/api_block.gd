class_name ApiBlock
extends PanelContainer

signal deleted_requested
signal config_changed

@onready var delete_btn: Button = %DeleteBtn # Make unique
@onready var url_input: LineEdit = %UrlInput
@onready var key_input: LineEdit = %KeyInput
@onready var model_input: LineEdit = %ModelInput
@onready var weight_input: SpinBox = %WeightInput
@onready var stats_label: Label = %StatsLabel

func _ready() -> void:
	delete_btn.pressed.connect(func(): deleted_requested.emit())
	
	var sb_line_edit = weight_input.get_line_edit()
	sb_line_edit.add_theme_font_size_override("font_size", 12)
	weight_input.value_changed.connect(func(_val): config_changed.emit())
	
	# Connect change signals to recalculate ratios
	weight_input.value_changed.connect(func(_val): config_changed.emit())
	
	# Optional: Emit change on text edit if you want to autosave later
	url_input.text_changed.connect(func(_t): config_changed.emit())
	key_input.text_changed.connect(func(_t): config_changed.emit())
	model_input.text_changed.connect(func(_t): config_changed.emit())

func get_config() -> Dictionary:
	return {
		"url": url_input.text.strip_edges(),
		"key": key_input.text.strip_edges(),
		"model": model_input.text.strip_edges(),
		"weight": int(weight_input.value)
	}

# Called by the dashboard to update the % display
func update_stats(total_weight: int, total_items_estimate: int) -> void:
	var my_weight = weight_input.value
	var percent = 0.0
	var count = 0
	
	if total_weight > 0:
		percent = (my_weight / float(total_weight)) * 100.0
		count = int(round((my_weight / float(total_weight)) * total_items_estimate))
	
	stats_label.text = "%.1f%% (~%d items)" % [percent, count]
