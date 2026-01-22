class_name Main
extends Control

# --- CONFIG ---
var page_size: int = 10
var row_height: int = 240
const RowScene = preload("res://components/Row.tscn")
const ToastScene = preload("res://components/Toast.tscn")
const WelcomeScene = preload("res://components/WelcomeScreen.tscn")

# --- UI NODES ---
@onready var header: Header = %Header
@onready var row_container: VBoxContainer = %RowContainer
@onready var column_headers: HBoxContainer = $MarginContainer/VBox/ColumnHeaders
@onready var upload_dialog: FileDialog = %UploadDialog
@onready var safety_dialog: SafetyDialog = %SafetyDialog
@onready var scroll_container: ScrollContainer = $MarginContainer/VBox/ScrollContainer
@onready var background: ColorRect = $Background
@onready var settings_dialog: SettingsDialog = %SettingsDialog
@onready var error_state: ErrorState = %ErrorState
@onready var empty_state: EmptyState = %EmptyState
@onready var text_editor: TextEditor = %TextEditor

# --- DATA CONTROLLER ---
@onready var project_manager: ProjectManager = %ProjectManager

# --- STATE ---
var current_page: int = 1
var total_pages: int = 1
var _upload_target_info: Dictionary = {}

# --- SEARCH STATE ---
var is_searching: bool = false
var filtered_stems: Array = []
var last_browsing_page: int = 1
var _is_restoring_view: bool = false

func _ready() -> void:
	%SearchManager.setup(project_manager)
	%SearchManager.search_completed.connect(_on_search_completed)
	_connect_signals()
	
	# Setup UI connections
	error_state.setup_requested.connect(func():
		_show_welcome_screen()
		error_state.hide()
	)
	
	empty_state.examples_imported.connect(func():
		empty_state.hide()
		_scan_and_populate_projects()
		_show_toast("Examples Loaded!")
	)
	
	# We listen to the Header's "events", not the individual buttons
	header.project_selected.connect(_on_project_selected)
	header.refresh_requested.connect(_scan_and_populate_projects)
	header.settings_requested.connect(_open_settings)
	
	# Pagination signals
	header.page_change_requested.connect(_change_page)
	header.page_jump_requested.connect(_on_page_jump_requested)
	
	var saved_settings = project_manager.load_config()
	if saved_settings.has("page_size"):
		page_size = int(saved_settings["page_size"])
	if saved_settings.has("row_height"):
		row_height = int(saved_settings["row_height"])
		
	if saved_settings.has("cache_limit_mb"):
		ThumbnailLoader.set_cache_limit_mb(int(saved_settings["cache_limit_mb"]))
	
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	background.gui_input.connect(_on_background_clicked)
	scroll_container.gui_input.connect(_on_background_clicked)
	
	# Wait for layout
	await get_tree().process_frame
	
	settings_dialog.settings_changed.connect(_on_settings_changed)
	settings_dialog.library_path_changed.connect(_on_library_path_changed)
	
	# --- TEXT EDITOR CONNECTIONS ---
	
	# 1. Connect Save
	text_editor.request_save.connect(_handle_save_text)
	
	# 2. Connect Smart Update (The Fix)
	# This lambda correctly accepts the two arguments sent by the signal
	text_editor.closed.connect(func(path, new_content):
		var stem = path.get_file().get_basename()
		
		for child in row_container.get_children():
			if child is Row and child.stem == stem:
				child.update_text_cell(path, new_content)
				break
	)
	
	# --- STARTUP LOGIC ---
	
	# 1. Critical Missing (No bootstrap, no default folder)
	if project_manager.current_path_status == project_manager.PathStatus.BROKEN_MISSING:
		_show_error_state()
		return
		
	# 2. Custom Path Missing
	if project_manager.current_path_status == project_manager.PathStatus.BROKEN_CUSTOM_FALLBACK:
		_show_toast("⚠️ Custom path missing! Using default.")
	
	# 3. Normal Startup
	_scan_and_populate_projects()
		
	# Listen for resize logic
	get_tree().root.size_changed.connect(_on_window_resized)
	%ResizeTimer.timeout.connect(_update_ui)
	get_tree().set_auto_accept_quit(false)
	
func _show_error_state() -> void:
	column_headers.hide()
	scroll_container.hide()
	
	# Update label text based on why we are here
	var label = error_state.find_child("Label") # Assuming the label is named "Label" inside ErrorState
	if label:
		if project_manager.is_fresh_install:
			label.text = "No Data Path Found!"
		else:
			label.text = "Data Path Not Found!\n(Did you move your folder?)"
			
	error_state.show()
	
func _open_settings() -> void:
	# Convert bytes to MB for the UI
	var current_limit_mb = ThumbnailLoader._cache_limit_bytes / (1024.0 * 1024.0)
	
	settings_dialog.open(
		page_size, 
		row_height, 
		project_manager.autosave_enabled, 
		current_limit_mb
	)
	
func _on_settings_changed(new_size: int, new_height: int, new_autosave: bool, new_cache_limit_mb: int) -> void:
	page_size = new_size
	row_height = new_height
	
	ThumbnailLoader.set_cache_limit_mb(new_cache_limit_mb)
	
	# Update ProjectManager
	project_manager.autosave_enabled = new_autosave
	
	# Save config
	var data = {
		"page_size": page_size,
		"row_height": row_height,
		"autosave_enabled": project_manager.autosave_enabled,
		"cache_limit_mb": new_cache_limit_mb 
	}
	project_manager.save_config(data)
	
	_calculate_pagination()
	_render_grid()
	_update_pagination_labels()
	
func _on_library_path_changed(new_path: String) -> void:
	project_manager.update_library_path(new_path)
	
	# Refresh the project list because we are looking at a new folder now
	_scan_and_populate_projects()
	
func _connect_signals() -> void:
	upload_dialog.file_selected.connect(_on_file_uploaded)
	
	# Project Manager Signals
	project_manager.project_loaded.connect(_on_project_data_loaded)
	project_manager.toast_requested.connect(_show_toast)
	project_manager.error_occurred.connect(_show_toast) # reuse toast for errors

# --- PROJECT LOGIC ---

func _scan_and_populate_projects() -> void:
	var prev_project = project_manager.current_project_name
	var projects = project_manager.scan_projects()
	
	# 1. Let the header update its own UI
	header.populate_projects(projects, prev_project)
	
	# 2. Handle Logic (Empty State vs Grid)
	if projects.is_empty():
		column_headers.hide()
		scroll_container.hide()
		empty_state.setup(project_manager.datasets_root_path)
		empty_state.show()
		return
	else:
		empty_state.hide()
		column_headers.show()
		scroll_container.show()

	# 3. Determine which project to load (Logic remains mostly the same)
	# We ask the header "What name is currently selected?" to verify
	var selected_name = header.get_selected_project_name()
	
	if selected_name == prev_project:
		_is_restoring_view = true
		project_manager.load_project(selected_name)
	else:
		_is_restoring_view = false
		project_manager.load_project(selected_name)

func _on_project_selected(_index: int) -> void:
	var project_name = header.get_selected_project_name()
	if project_name != "":
		project_manager.load_project(project_name)

func _on_project_data_loaded() -> void:
	if _is_restoring_view:
		# REFRESH MODE
		_calculate_pagination()
		
		if current_page > total_pages: current_page = total_pages
		if current_page < 1: current_page = 1
		
		# If we are searching, we need to re-trigger the manager
		if is_searching:
			# We essentially "jiggle" the filters to force a re-run on the new data
			var active = %SearchManager.get_active_filters()
			for k in active:
				%SearchManager.update_filter(k, active[k])
		else:
			_update_ui()
			
		_is_restoring_view = false
		
	else:
		# SWITCH MODE
		# Use Manager to clear
		%SearchManager.clear_filters()
		
		is_searching = false
		last_browsing_page = 1
		current_page = 1
		
		_calculate_pagination()
		_update_ui()
		scroll_container.scroll_vertical = 0
		
func _show_welcome_screen() -> void:
	var welcome = WelcomeScene.instantiate()
	# Add it to the highest layer so it covers everything
	%ToastContainer.get_parent().add_child(welcome)
	welcome.setup_completed.connect(_on_welcome_completed.bind(welcome))

func _on_welcome_completed(selected_path: String, is_portable: bool, welcome_instance: Node) -> void:
	welcome_instance.queue_free()
	
	if selected_path != "":
		# User chose a path
		project_manager.update_library_path(selected_path, is_portable)
		
		# If we fixed the error, show the UI
		if project_manager._base_data_path != "":
			error_state.hide()
			column_headers.show()
			scroll_container.show()
			_scan_and_populate_projects()
	else:
		# User clicked SKIP
		
		# 1. Check if we actually have a fallback path (e.g. Dev folder)
		if project_manager._base_data_path != "" and project_manager.current_path_status == project_manager.PathStatus.OK:
			# We have a path! Just load it.
			_scan_and_populate_projects()
		else:
			# We have nothing. Show the "Setup" button (Error State).
			# Do NOT relaunch welcome screen immediately.
			_show_error_state()

# --- FILE OPERATION HANDLERS ---

func _handle_create_txt(stem: String, col_name: String) -> void:
	_is_restoring_view = true
	project_manager.create_text_file(stem, col_name)

func _handle_delete_file(path: String) -> void:
	var is_image = path.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]
	var prompt = "Delete %s?" % path.get_file()
	var img_path = path if is_image else ""
	
	var action_recycle = func():
		_is_restoring_view = true
		project_manager.move_file_to_trash(path)

	var action_permanent = func():
		_is_restoring_view = true
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
		_is_restoring_view = true
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
	_is_restoring_view = true
	project_manager.import_file(stem, col_name, source_path)
	
	_upload_target_info.clear()

func _handle_direct_upload(stem: String, col_name: String, source_path: String) -> void:
	# Use the manager function
	_is_restoring_view = true
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
	
	# GET FILTERS FROM MANAGER
	var active_filters = %SearchManager.get_active_filters()
	
	# Clear existing headers
	for child in column_headers.get_children():
		child.queue_free()
	
	# --- 1. ID COLUMN ---
	var id_vbox = VBoxContainer.new()
	id_vbox.custom_minimum_size.x = 150
	id_vbox.alignment = BoxContainer.ALIGNMENT_END 
	
	var id_label = Label.new()
	id_label.text = "ID"
	id_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	id_label.label_settings = LabelSettings.new()
	id_label.label_settings.font_color = Color("41f095")
	id_vbox.add_child(id_label)
	
	var id_search = LineEdit.new()
	id_search.placeholder_text = "Search ID..."
	id_search.alignment = HORIZONTAL_ALIGNMENT_CENTER
	
	# USE LOCAL VARIABLE
	if active_filters.has("ID"): 
		id_search.text = active_filters["ID"]
	
	id_search.text_changed.connect(_on_search_text_changed.bind("ID"))
	id_vbox.add_child(id_search)
	column_headers.add_child(id_vbox)
	
	var sep1 = VSeparator.new()
	sep1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column_headers.add_child(sep1)

	# --- 2. CONTENT COLUMNS ---
	for col in project_manager.current_columns:
		var col_container = VBoxContainer.new()
		col_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col_container.custom_minimum_size.x = col_width
		col_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
		
		var label = Label.new()
		label.text = col.to_upper()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.label_settings = LabelSettings.new()
		label.label_settings.font_color = Color("41f095")
		col_container.add_child(label)
		
		var controls_hbox = HBoxContainer.new()
		controls_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		controls_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
		
		var folder_btn = Button.new()
		folder_btn.text = "📂"
		folder_btn.focus_mode = Control.FOCUS_NONE
		folder_btn.flat = true
		folder_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		folder_btn.pressed.connect(func(): 
			var path = project_manager.get_column_path(col)
			if path: 
				OS.shell_open(ProjectSettings.globalize_path(path))
		)
		controls_hbox.add_child(folder_btn)
		
		var flash_btn = Button.new()
		flash_btn.text = "📄"
		flash_btn.focus_mode = Control.FOCUS_NONE
		flash_btn.flat = true
		flash_btn.modulate = Color("41f095") 
		flash_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		flash_btn.pressed.connect(_handle_bulk_populate.bind(col))
		controls_hbox.add_child(flash_btn)
		
		var col_search = LineEdit.new()
		col_search.placeholder_text = "Search..."
		col_search.size_flags_horizontal = SIZE_EXPAND_FILL
		
		# USE LOCAL VARIABLE
		if active_filters.has(col): 
			col_search.text = active_filters[col]
			
		col_search.text_changed.connect(_on_search_text_changed.bind(col))
		controls_hbox.add_child(col_search)
		
		col_container.add_child(controls_hbox)
		column_headers.add_child(col_container)
		
		var sep2 = VSeparator.new()
		sep2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column_headers.add_child(sep2)
		
	_update_pagination_labels()
	_render_grid(col_width)

func _trigger_preload() -> void:
	# Only preload if we aren't on the last page
	if current_page >= total_pages: return
	
	var dataset = project_manager.current_dataset
	
	# Determine source list (Search vs Normal)
	var source_list = []
	if %SearchManager.is_active():
		source_list = filtered_stems
	else:
		source_list = dataset.keys()
		source_list.sort()
		
	# Calculate range for NEXT page
	var start_index = current_page * page_size # (current_page is 1-based, so this jumps to next page start)
	
	# Let's limit preload to the first 4 rows of the next page to be gentle
	var rows_to_preload = 4 
	var end_index = min(start_index + rows_to_preload, source_list.size())
	
	for i in range(start_index, end_index):
		var stem = source_list[i]
		var row_data = dataset.get(stem, {})
		
		# Find images in this row
		for col in project_manager.current_columns:
			var files = row_data.get(col, [])
			for f_path in files:
				if f_path.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
					# Request with a dummy callback (we just want it in cache)
					# We use the same row_height * 2 logic as the Row component
					ThumbnailLoader.request_thumbnail(f_path, int(row_height * 2), func(_tex): pass)

func _render_grid(col_width: float = -1.0) -> void:
	if col_width < 0: col_width = _calculate_column_width()
	
	# --- DATA PREP ---
	var dataset = project_manager.current_dataset
	var source_list = []
	if %SearchManager.is_active():
		source_list = filtered_stems
	else:
		source_list = dataset.keys()
		source_list.sort()
	
	var start_index = (current_page - 1) * page_size
	var end_index = min(start_index + page_size, source_list.size())
	
	# --- POOLING LOGIC ---
	var existing_children = row_container.get_children()
	var child_idx = 0
	
	for i in range(start_index, end_index):
		var stem = source_list[i]
		var row_data = dataset[stem]
		
		var row_instance: Row
		var sep_instance: HSeparator
		
		# 1. Check if we have a recyclable pair (Row + Separator)
		# We look ahead 2 indices (current + next) because we store [Row, Sep, Row, Sep...]
		if child_idx + 1 < existing_children.size():
			# RECYCLE: Grab existing nodes
			row_instance = existing_children[child_idx] as Row
			sep_instance = existing_children[child_idx + 1] as HSeparator
			
			row_instance.show()
			sep_instance.show()
			
			# Note: We don't need to re-connect signals because they stick around!
		else:
			# CREATE: Instantiate new nodes
			row_instance = RowScene.instantiate()
			sep_instance = HSeparator.new()
			sep_instance.mouse_filter = Control.MOUSE_FILTER_IGNORE
			
			row_container.add_child(row_instance)
			row_container.add_child(sep_instance)
			
			# CONNECT SIGNALS (Only done once per instance)
			row_instance.request_full_image.connect(_on_row_request_image)
			row_instance.request_create_txt.connect(_handle_create_txt)
			row_instance.request_delete_file.connect(_handle_delete_file)
			row_instance.request_save_text.connect(_handle_save_text)
			row_instance.request_expanded_text.connect(func(path, content):
				text_editor.open(path, content, project_manager.autosave_enabled)
			)
			row_instance.request_upload.connect(_handle_request_upload)
			row_instance.request_direct_upload.connect(_handle_direct_upload)
		
		# 2. Setup the Row (This is the "Renovation" part)
		row_instance.setup(
			stem, 
			row_data, 
			project_manager.current_columns, 
			col_width, 
			row_height,
			project_manager.autosave_enabled
		)
		
		# Advance our index by 2 (Row + Separator)
		child_idx += 2

	# 3. Hide Unused Nodes (Don't delete them, keep them for next time)
	while child_idx < existing_children.size():
		existing_children[child_idx].hide()
		child_idx += 1
		
	# --- PRELOAD NEXT PAGE ---
	_trigger_preload()

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
	# 1. Capture the page ONLY if we are transitioning from "Not Searching" to "Searching".
	# We check if the manager is inactive (filters are empty) AND we are typing actual text.
	if not %SearchManager.is_active() and new_text.strip_edges() != "":
		last_browsing_page = current_page
		
	# 2. Just tell the manager. It handles state, filters, and timers automatically.
	%SearchManager.update_filter(col_identifier, new_text)

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
		scroll_container.scroll_vertical = 0

func _on_page_jump_requested(target_page: int) -> void:
	if target_page < 1: target_page = 1
	elif target_page > total_pages: target_page = total_pages
	
	if target_page != current_page:
		current_page = target_page
		_render_grid()
		_update_pagination_labels()
		scroll_container.scroll_vertical = 0

func _update_pagination_labels() -> void:
	header.update_pagination(current_page, total_pages)

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

func _notification(what: int) -> void:
	# Detect if the user clicked the X button or Alt+F4
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_perform_shutdown_cleanup()
		get_tree().quit() # Now we manually quit

func _perform_shutdown_cleanup() -> void:
	# 1. Find all active autosave timers in the application
	var timers = get_tree().get_nodes_in_group("autosave_timers")
	var saved_count = 0
	
	for timer in timers:
		if timer is Timer and not timer.is_stopped():
			# 2. Force the timer to fire its signal NOW
			timer.timeout.emit()
			saved_count += 1
			
	if saved_count > 0:
		print("Graceful Shutdown: Forced save on %d files." % saved_count)

func _on_search_completed(results: Array) -> void:
	filtered_stems = results
	
	is_searching = %SearchManager.is_active()
	
	if not is_searching:
		current_page = last_browsing_page
	else:
		current_page = 1
		
	_calculate_pagination()
	_render_grid()
	_update_pagination_labels()
	scroll_container.scroll_vertical = 0
