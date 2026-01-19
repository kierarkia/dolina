class_name WelcomeScreen
extends ColorRect

# --- SIGNALS ---
# Emitted when the user makes a choice. 
# passing "" (empty string) implies they chose to Skip.
signal setup_completed(selected_path: String)

# --- NODES ---
@onready var btn_portable: Button = %BtnPortable
@onready var btn_custom: Button = %BtnCustom
@onready var btn_skip: Button = %BtnSkip
@onready var dir_dialog: FileDialog = %DirDialog

func _ready() -> void:
	# Make sure we consume clicks so they don't hit the main app behind us
	mouse_filter = Control.MOUSE_FILTER_STOP
	
	_connect_signals()

func _connect_signals() -> void:
	btn_portable.pressed.connect(_on_portable_pressed)
	btn_custom.pressed.connect(_on_custom_pressed)
	btn_skip.pressed.connect(_on_skip_pressed)
	
	dir_dialog.dir_selected.connect(_on_custom_dir_selected)

# --- ACTION HANDLERS ---

func _on_portable_pressed() -> void:
	# Logic: Get the executable directory + "/data"
	var exe_dir = OS.get_executable_path().get_base_dir()
	
	# macOS Fix: If inside an .app bundle, step out to the actual folder
	if OS.get_name() == "macOS" and exe_dir.contains(".app"):
		exe_dir = exe_dir.get_base_dir().get_base_dir().get_base_dir().get_base_dir()
		
	var target_path = exe_dir.path_join("data")
	
	# Emit immediately
	setup_completed.emit(target_path)

func _on_custom_pressed() -> void:
	# Reusing the logic you already know: Open the dialog
	dir_dialog.popup_centered()

func _on_custom_dir_selected(path: String) -> void:
	# Pass the user's selection back
	setup_completed.emit(path)

func _on_skip_pressed() -> void:
	# Emit empty string to signify "Do nothing"
	setup_completed.emit("")
