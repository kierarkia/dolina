class_name Main
extends Control

# --- CONFIG ---
var page_size: int = 10
var row_height: int = 240 # Default height
const RowScene = preload("res://components/Row.tscn")
const ToastScene = preload("res://components/Toast.tscn")
const WelcomeScene = preload("res://components/WelcomeScreen.tscn")

# --- UI NODES ---
@onready var project_select: OptionButton = %ProjectSelect
@onready var row_container: VBoxContainer = %RowContainer
@onready var column_headers: HBoxContainer = $MarginContainer/VBox/ColumnHeaders
@onready var prev_btn: Button = %PrevBtn
@onready var page_input: LineEdit = %PageInput
@onready var total_label: Label = %TotalLabel
@onready var next_btn: Button = %NextBtn
@onready var refresh_btn: Button = $MarginContainer/VBox/Header/RefreshBtn
@onready var upload_dialog: FileDialog = %UploadDialog
@onready var safety_dialog: SafetyDialog = %SafetyDialog
@onready var scroll_container: ScrollContainer = $MarginContainer/VBox/ScrollContainer
@onready var background: ColorRect = $Background
@onready var settings_btn: Button = %SettingsBtn
@onready var settings_dialog: SettingsDialog = %SettingsDialog

# --- DATA CONTROLLER ---
@onready var project_manager: ProjectManager = %ProjectManager

# --- STATE ---
var current_page: int = 1
var total_pages: int = 1
var _upload_target_info: Dictionary = {}

# --- SEARCH STATE ---
var search_filters: Dictionary = {}
var is_searching: bool = false
var filtered_stems: Array = []
var last_browsing_page: int = 1
var _is_restoring_view: bool = false

func _ready() -> void:
	_connect_signals()
	
	var saved_settings = project_manager.load_config()
	if saved_settings.has("page_size"):
		page_size = int(saved_settings["page_size"])
	if saved_settings.has("row_height"):
		row_height = int(saved_settings["row_height"])
	
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	background.gui_input.connect(_on_background_clicked)
	scroll_container.gui_input.connect(_on_background_clicked)
	
	# Wait for layout
	await get_tree().process_frame
	
	settings_btn.pressed.connect(_open_settings)
	settings_dialog.settings_changed.connect(_on_settings_changed)
	settings_dialog.library_path_changed.connect(_on_library_path_changed)
	
	if project_manager.is_fresh_install:
		_show_welcome_screen()
	else:
		_scan_and_populate_projects()
		
	# Listen for resize logic
	get_tree().root.size_changed.connect(_on_window_resized)
	%ResizeTimer.timeout.connect(_update_ui)
	%SearchTimer.timeout.connect(_perform_search)
	
func _open_settings() -> void:
	settings_dialog.open(page_size, row_height)

func _on_settings_changed(new_size: int, new_height: int) -> void:
	page_size = new_size
	row_height = new_height
	
	var data = {
		"page_size": page_size,
		"row_height": row_height
	}
	project_manager.save_config(data)
	
	# Refresh the grid to apply changes
	_calculate_pagination()
	_render_grid()
	_update_pagination_labels()
	
func _on_library_path_changed(new_path: String) -> void:
	project_manager.update_library_path(new_path)
	
	# Refresh the project list because we are looking at a new folder now
	_scan_and_populate_projects()
	
func _connect_signals() -> void:
	# UI Signals
	project_select.item_selected.connect(_on_project_selected)
	refresh_btn.pressed.connect(_scan_and_populate_projects)
	prev_btn.pressed.connect(_change_page.bind(-1))
	next_btn.pressed.connect(_change_page.bind(1))
	page_input.text_submitted.connect(_on_page_jump_submitted)
	page_input.focus_exited.connect(_update_pagination_labels)
	upload_dialog.file_selected.connect(_on_file_uploaded)
	
	# Project Manager Signals
	project_manager.project_loaded.connect(_on_project_data_loaded)
	project_manager.toast_requested.connect(_show_toast)
	project_manager.error_occurred.connect(_show_toast) # reuse toast for errors

# --- PROJECT LOGIC ---

func _scan_and_populate_projects() -> void:
	# 1. Capture current state before we wipe it
	var prev_project = project_manager.current_project_name
	
	# 2. Scan
	project_select.clear()
	var projects = project_manager.scan_projects()
	
	if projects.is_empty():
		project_select.add_item("No Projects Found")
		project_select.disabled = true
		return

	# 3. Populate & Search for previous project
	project_select.disabled = false
	var target_index = 0
	var found_prev = false
	
	for i in range(projects.size()):
		var proj = projects[i]
		project_select.add_item(proj)
		if proj == prev_project:
			target_index = i
			found_prev = true
	
	# 4. Select the correct item visually
	project_select.selected = target_index
	
	# 5. Load
	if found_prev:
		# We found our old project! Set the flag so we don't reset the page.
		_is_restoring_view = true
		project_manager.load_project(projects[target_index])
	else:
		# It's a new project (or the old one was deleted). Reset everything.
		_is_restoring_view = false
		project_manager.load_project(projects[target_index])

func _on_project_selected(index: int) -> void:
	var project_name = project_select.get_item_text(index)
	project_manager.load_project(project_name)

func _on_project_data_loaded() -> void:
	if _is_restoring_view:
		# REFRESH MODE: Keep current_page and filters
		# 1. Recalculate totals (in case files were added/removed externally)
		_calculate_pagination()
		
		# 2. If we were on page 10 but now there are only 5 pages, clamp it.
		if current_page > total_pages: current_page = total_pages
		if current_page < 1: current_page = 1
		
		# 3. Refresh UI (Re-run search if needed)
		if is_searching:
			_perform_search()
		else:
			_update_ui()
			
		# Reset the flag
		_is_restoring_view = false
		
	else:
		# SWITCH MODE: Reset everything (The old logic)
		search_filters.clear()
		is_searching = false
		last_browsing_page = 1
		current_page = 1
		
		_calculate_pagination()
		_update_ui()
		
func _show_welcome_screen() -> void:
	var welcome = WelcomeScene.instantiate()
	# Add it to the highest layer so it covers everything
	%ToastContainer.get_parent().add_child(welcome)
	welcome.setup_completed.connect(_on_welcome_completed.bind(welcome))

func _on_welcome_completed(selected_path: String, welcome_instance: Node) -> void:
	# 1. Remove the screen
	welcome_instance.queue_free()
	
	# 2. Handle the choice
	if selected_path != "":
		# User selected "Portable" or "Custom"
		# This function in ProjectManager saves the bootstrap AND creates the folders
		project_manager.update_library_path(selected_path)
		
		# Since we just created it, it's technically no longer a "fresh install" state
		# for the purpose of logic, though we don't strictly need to toggle the bool back.
	else:
		# User selected "Skip"
		# We do nothing. ProjectManager has a default path in memory, 
		# but the folders on disk (likely) don't exist. 
		# _scan_and_populate_projects will just find 0 projects.
		pass

	# 3. Finally, start the app
	_scan_and_populate_projects()

# --- FILE OPERATION HANDLERS ---

func _handle_create_txt(stem: String, col_name: String) -> void:
	project_manager.create_text_file(stem, col_name)

func _handle_delete_file(path: String) -> void:
	var is_image = path.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]
	var prompt = "Delete %s?" % path.get_file()
	var img_path = path if is_image else ""
	
	var action_recycle = func():
		project_manager.move_file_to_trash(path)

	var action_permanent = func():
		project_manager.delete_file_permanently(path)

	safety_dialog.open_delete(prompt, img_path, action_recycle, action_permanent)

func _handle_save_text(path: String, content: String) -> void:
	project_manager.save_text_file(path, content)

func _handle_bulk_populate(col_name: String) -> void:
	# Calculate count using the manager's data
	var count = 0
	var dataset = project_manager.current_dataset
	
	for stem in dataset:
		if dataset[stem].get(col_name, []).is_empty():
			count += 1
			
	if count == 0: return
	
	# Slightly updated prompt
	var prompt = "Create %d text files in '%s'?" % [count, col_name]
	
	var action = func():
		# Retrieve the text from the dialog at the moment the button is pressed
		var user_text = safety_dialog.get_input_text()
		project_manager.populate_empty_files(col_name, user_text)
		
	# Call the open_fill method
	safety_dialog.open_fill(prompt, action)

# --- UPLOAD LOGIC ---

func _handle_request_upload(stem: String, col_name: String) -> void:
	_upload_target_info = {"stem": stem, "col": col_name}
	upload_dialog.current_dir = project_manager.datasets_root_path
	upload_dialog.popup_centered()

func _on_file_uploaded(source_path: String) -> void:
	if _upload_target_info.is_empty(): return
	var stem = _upload_target_info["stem"]
	var col_name = _upload_target_info["col"]
	
	# Use the manager function
	project_manager.import_file(stem, col_name, source_path)
	
	_upload_target_info.clear()

func _handle_direct_upload(stem: String, col_name: String, source_path: String) -> void:
	# Use the manager function
	project_manager.import_file(stem, col_name, source_path)

# --- UI & PAGINATION ---

func _calculate_column_width() -> float:
	var cols = project_manager.current_columns
	if cols.is_empty(): return 100.0
	var window_width = size.x
	var available_width = window_width - 40 - 150 - 40
	var w = available_width / float(cols.size())
	return max(w, 100.0)

func _calculate_pagination() -> void:
	var total_rows = 0
	if is_searching: 
		total_rows = filtered_stems.size()
	else: 
		total_rows = project_manager.current_dataset.keys().size()
		
	if total_rows == 0: total_pages = 1
	else: total_pages = ceil(float(total_rows) / float(page_size))
	
	if current_page > total_pages: current_page = total_pages
	if current_page < 1: current_page = 1

func _update_ui() -> void:
	var col_width = _calculate_column_width()
	for child in column_headers.get_children(): child.queue_free()
	
	# ID Column
	var id_search = LineEdit.new()
	id_search.placeholder_text = "Search..."
	id_search.custom_minimum_size.x = 150 
	id_search.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if search_filters.has("ID"): id_search.text = search_filters["ID"]
	id_search.text_changed.connect(_on_search_text_changed.bind("ID"))
	column_headers.add_child(id_search)
	
	var sep1 = VSeparator.new()
	sep1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column_headers.add_child(sep1)

	# Content Columns
	for col in project_manager.current_columns:
		var header_hbox = HBoxContainer.new()
		header_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		header_hbox.custom_minimum_size.x = col_width
		header_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
		
		# Column Name
		var label = Label.new()
		label.text = col.to_upper()
		label.label_settings = LabelSettings.new()
		label.label_settings.font_color = Color("41f095")
		header_hbox.add_child(label)
		
		# Open Folder Button
		var folder_btn = Button.new()
		folder_btn.text = "📂" # Simple unicode folder icon
		folder_btn.tooltip_text = "Open in File Explorer"
		folder_btn.focus_mode = Control.FOCUS_NONE
		folder_btn.flat = true
		folder_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		# Connect to OS.shell_open
		folder_btn.pressed.connect(func(): 
			var path = project_manager.get_column_path(col)
			if path: 
				# Globalize path ensures it works for "res://" paths in editor mode too
				OS.shell_open(ProjectSettings.globalize_path(path))
		)
		header_hbox.add_child(folder_btn)
		
		# 3. Fill Button (Existing)
		var flash_btn = Button.new()
		flash_btn.text = "FILL" 
		flash_btn.tooltip_text = "Bulk populate empty rows in this column with .txt files" 
		flash_btn.focus_mode = Control.FOCUS_NONE
		flash_btn.flat = true
		flash_btn.modulate = Color("41f095") 
		flash_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		flash_btn.pressed.connect(_handle_bulk_populate.bind(col))
		header_hbox.add_child(flash_btn)
		
		# 4. Search (Existing)
		var col_search = LineEdit.new()
		col_search.placeholder_text = "Search..."
		col_search.size_flags_horizontal = SIZE_EXPAND_FILL
		if search_filters.has(col): col_search.text = search_filters[col]
		col_search.text_changed.connect(_on_search_text_changed.bind(col))
		
		header_hbox.add_child(col_search)
		column_headers.add_child(header_hbox)
		
		var sep2 = VSeparator.new()
		sep2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column_headers.add_child(sep2)
		
	_update_pagination_labels()
	_render_grid(col_width)

func _render_grid(col_width: float = -1.0) -> void:
	if col_width < 0: col_width = _calculate_column_width()
	for child in row_container.get_children(): child.queue_free()
	
	var dataset = project_manager.current_dataset
	var source_list = []
	if is_searching: 
		source_list = filtered_stems
	else: 
		source_list = dataset.keys()
		source_list.sort()
	
	var start_index = (current_page - 1) * page_size
	var end_index = min(start_index + page_size, source_list.size())
	
	for i in range(start_index, end_index):
		var stem = source_list[i]
		var row_data = dataset[stem]
		
		var row_instance = RowScene.instantiate()
		row_container.add_child(row_instance)
		row_instance.setup(stem, row_data, project_manager.current_columns, col_width, row_height)
		
		row_instance.request_full_image.connect(_on_row_request_image)
		row_instance.request_create_txt.connect(_handle_create_txt)
		row_instance.request_delete_file.connect(_handle_delete_file)
		row_instance.request_save_text.connect(_handle_save_text)
		row_instance.request_upload.connect(_handle_request_upload)
		row_instance.request_direct_upload.connect(_handle_direct_upload)
		
		var h_sep = HSeparator.new()
		h_sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row_container.add_child(h_sep)

func _on_row_request_image(stem: String, clicked_path: String) -> void:
	var row_images: Array[String] = []
	var dataset = project_manager.current_dataset
	var row_data = dataset.get(stem, {})
	
	for col in project_manager.current_columns:
		var files = row_data.get(col, [])
		for f in files:
			if f.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
				row_images.append(f)
	%ImageViewer.show_gallery(row_images, clicked_path)

# --- SEARCH LOGIC ---

func _on_search_text_changed(new_text: String, col_identifier: String) -> void:
	if not is_searching and search_filters.is_empty():
		last_browsing_page = current_page
	if new_text.strip_edges() == "":
		search_filters.erase(col_identifier)
	else:
		search_filters[col_identifier] = new_text.to_lower()
	%SearchTimer.start()

func _perform_search() -> void:
	if search_filters.is_empty():
		is_searching = false
		current_page = last_browsing_page
		_calculate_pagination()
		_update_ui()
		return
	
	is_searching = true
	filtered_stems.clear()
	var dataset = project_manager.current_dataset
	
	# Filter Logic (AND)
	for stem in dataset:
		var match_all = true
		for col_key in search_filters:
			var query = search_filters[col_key]
			if col_key == "ID":
				if not stem.to_lower().contains(query):
					match_all = false; break
			else:
				var files = dataset[stem].get(col_key, [])
				var col_match = false
				for f_path in files:
					if f_path.get_file().to_lower().contains(query):
						col_match = true; break
				if not col_match:
					for f_path in files:
						var ext = f_path.get_extension().to_lower()
						if ext in ["txt", "md", "json"]:
							var f = FileAccess.open(f_path, FileAccess.READ)
							if f and f.get_as_text().to_lower().contains(query):
								col_match = true; break
				if not col_match:
					match_all = false; break
		
		if match_all: filtered_stems.append(stem)
	
	filtered_stems.sort()
	current_page = 1
	_calculate_pagination()
	_render_grid()
	_update_pagination_labels()

# --- INPUT & HELPERS ---

func _on_background_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var focus_owner = get_viewport().gui_get_focus_owner()
		if focus_owner: focus_owner.release_focus()

func _on_window_resized() -> void:
	%ResizeTimer.start()

func _show_toast(message: String) -> void:
	var toast = ToastScene.instantiate()
	%ToastContainer.add_child(toast)
	toast.show_message(message)

func _change_page(direction: int) -> void:
	var new_page = current_page + direction
	if new_page >= 1 and new_page <= total_pages:
		current_page = new_page
		_update_pagination_labels()
		_render_grid()

func _on_page_jump_submitted(new_text: String) -> void:
	if not new_text.is_valid_int():
		_update_pagination_labels()
		return
	var target_page = int(new_text)
	if target_page < 1: target_page = 1
	elif target_page > total_pages: target_page = total_pages
	if target_page != current_page:
		current_page = target_page
		_render_grid()
		_update_pagination_labels()
	page_input.release_focus()

func _update_pagination_labels() -> void:
	page_input.text = str(current_page)
	total_label.text = "/ %d" % total_pages
	prev_btn.disabled = (current_page == 1)
	next_btn.disabled = (current_page == total_pages)

func _unhandled_input(event: InputEvent) -> void:
	if %ImageViewer.visible: return
	if event.is_action_pressed("ui_right"): 
		_change_page(1)
	elif event.is_action_pressed("ui_left"): 
		_change_page(-1)
	elif event.is_action_pressed("ui_page_up", true):
		scroll_container.scroll_vertical -= int(scroll_container.size.y - 120)
	elif event.is_action_pressed("ui_page_down", true):
		scroll_container.scroll_vertical += int(scroll_container.size.y - 120)
	elif event.is_action_pressed("ui_up", true):
		scroll_container.scroll_vertical -= 150
	elif event.is_action_pressed("ui_down", true):
		scroll_container.scroll_vertical += 150
