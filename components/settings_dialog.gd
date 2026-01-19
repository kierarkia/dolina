class_name SettingsDialog
extends AcceptDialog

signal settings_changed(new_page_size: int, new_row_height: int)
signal library_path_changed # New signal for Main to catch

@onready var rows_input: SpinBox = %RowsInput
@onready var height_input: SpinBox = %HeightInput
@onready var path_label: Label = %CurrentPathLabel
@onready var change_path_btn: Button = %ChangePathBtn
@onready var dir_dialog: FileDialog = %DirDialog

var _temp_library_path: String = ""

func _ready() -> void:
	confirmed.connect(_on_apply)
	change_path_btn.pressed.connect(func(): dir_dialog.popup_centered())
	dir_dialog.dir_selected.connect(_on_dir_selected)
	
	# Access the internal LineEdit nodes
	var rows_le = rows_input.get_line_edit()
	var height_le = height_input.get_line_edit()
	
	var original_style = rows_le.get_theme_stylebox("normal")
	var red_style = original_style.duplicate()
	
	if red_style is StyleBoxFlat:
		red_style.bg_color = Color("#692c2c")
	
	rows_le.add_theme_stylebox_override("normal", red_style)
	height_le.add_theme_stylebox_override("normal", red_style)
	
	rows_le.add_theme_stylebox_override("focus", red_style)
	height_le.add_theme_stylebox_override("focus", red_style)
	
func open(current_page_size: int, current_row_height: int) -> void:
	rows_input.value = current_page_size
	height_input.value = current_row_height
	
	# Display current path from ProjectManager
	# We need a reference or we can just pass it in 'open'
	# For now, let's grab it via unique name if Main is parent, or just:
	var pm = get_tree().current_scene.find_child("ProjectManager")
	if pm:
		path_label.text = pm._base_data_path
		
	popup_centered()

func _on_dir_selected(path: String) -> void:
	_temp_library_path = path
	path_label.text = path + " (Pending Apply)"

func _on_apply() -> void:
	settings_changed.emit(int(rows_input.value), int(height_input.value))
	
	if _temp_library_path != "":
		library_path_changed.emit(_temp_library_path)
		_temp_library_path = ""
