class_name Header
extends PanelContainer

# --- SIGNALS (Outputs to Main) ---
signal project_selected(index: int)
signal refresh_requested
signal settings_requested
signal page_change_requested(direction: int)
signal page_jump_requested(page_number: int)

# --- NODES ---
@onready var project_select: OptionButton = %ProjectSelect
@onready var refresh_btn: Button = %RefreshBtn
@onready var settings_btn: Button = %SettingsBtn
@onready var prev_btn: Button = %PrevBtn
@onready var next_btn: Button = %NextBtn
@onready var page_input: LineEdit = %PageInput
@onready var total_label: Label = %TotalLabel

func _ready() -> void:
	# Internal wiring
	refresh_btn.pressed.connect(func(): refresh_requested.emit())
	settings_btn.pressed.connect(func(): settings_requested.emit())
	prev_btn.pressed.connect(func(): page_change_requested.emit(-1))
	next_btn.pressed.connect(func(): page_change_requested.emit(1))
	
	project_select.item_selected.connect(func(idx): project_selected.emit(idx))
	
	page_input.text_submitted.connect(_on_page_input_submitted)
	
	# Optional: Release focus when page input is done
	page_input.focus_exited.connect(func(): page_input.release_focus())

# --- PUBLIC API (Inputs from Main) ---

func populate_projects(projects: Array[String], current_project: String) -> void:
	project_select.clear()
	if projects.is_empty():
		project_select.add_item("No Projects Found")
		project_select.disabled = true
		return
		
	project_select.disabled = false
	var target_index = 0
	
	for i in range(projects.size()):
		var proj = projects[i]
		project_select.add_item(proj)
		if proj == current_project:
			target_index = i
			
	project_select.selected = target_index

func update_pagination(current: int, total: int) -> void:
	page_input.text = str(current)
	total_label.text = "/ %d" % total
	prev_btn.disabled = (current <= 1)
	next_btn.disabled = (current >= total)

func get_selected_project_name() -> String:
	if project_select.selected == -1: return ""
	return project_select.get_item_text(project_select.selected)

# --- INTERNAL HELPERS ---

func _on_page_input_submitted(new_text: String) -> void:
	if new_text.is_valid_int():
		page_jump_requested.emit(int(new_text))
	else:
		# Reset to current visual state if invalid (we assume Main will call update_pagination)
		pass 
	page_input.release_focus()
