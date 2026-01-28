class_name ProjectManager
extends Node

const BOOTSTRAP_FILE = "user://dolina_bootstrap.json"

# --- SIGNALS ---
signal project_loaded
signal error_occurred(message: String)
signal toast_requested(message: String)

# --- DATA STATE ---
var current_project_name: String = ""
var current_dataset: Dictionary = {} 
var current_columns: Array[String] = []
var is_fresh_install: bool = false
var autosave_enabled: bool = true
var column_conflicts: Dictionary = {}
var templates_root_path: String = ""

# --- PATHS ---
var _column_path_map: Dictionary = {}
var datasets_root_path: String = ""
var deleted_root_path: String = ""
var _base_data_path: String = ""
enum PathStatus { OK, BROKEN_MISSING, BROKEN_CUSTOM_FALLBACK }
var current_path_status: PathStatus = PathStatus.OK

const CONFIG_FILENAME = "dolina_dataset_config.json"

func _ready() -> void:
	_setup_paths()
	if not is_fresh_install:
		_initialize_library_structure()

# --- INITIALIZATION ---

func _setup_paths() -> void:
	current_path_status = PathStatus.OK
	
	# 1. Calculate the "Default" (Portable) location relative to executable
	var default_path = ""
	if OS.has_feature("editor"):
		default_path = ProjectSettings.globalize_path("res://examples/data")
	else:
		default_path = OS.get_executable_path().get_base_dir() + "/data"
		if OS.get_name() == "macOS" and default_path.contains(".app"):
			default_path = OS.get_executable_path().get_base_dir().get_base_dir().get_base_dir().get_base_dir() + "/data"

# 2. Check for Bootstrap
	if not FileAccess.file_exists(BOOTSTRAP_FILE):
		# --- SCENARIO C: NO BOOTSTRAP (User Skipped or Fresh) ---
		is_fresh_install = true
		
		if DirAccess.dir_exists_absolute(default_path):
			# CASE 1: Default folder exists (e.g. Dev environment or unconfigured portable)
			_base_data_path = default_path
			# FIX: Explicitly say status is OK so Main knows to load it
			current_path_status = PathStatus.OK 
		else:
			# CASE 2: No folder anywhere
			_base_data_path = ""
			current_path_status = PathStatus.BROKEN_MISSING
	else:
		# --- SCENARIO A & B: BOOTSTRAP EXISTS ---
		var bootstrap_data = _read_bootstrap()
		var stored_path = bootstrap_data.get("library_path", "")
		var is_portable = bootstrap_data.get("is_portable", false)
		
		var stored_exists = DirAccess.dir_exists_absolute(stored_path)
		var default_exists = DirAccess.dir_exists_absolute(default_path)
		
		if stored_exists:
			# Case: All good
			_base_data_path = stored_path
		
		else:
			# Case: Stored path is missing!
			
			if is_portable:
				# SCENARIO A: Portable Mode Self-Healing
				if default_exists:
					# We moved the folder! Self-heal.
					_base_data_path = default_path
					print("Portable folder moved. Self-healing bootstrap...")
					update_library_path(default_path, true) # Auto-update bootstrap
				else:
					# Both gone -> Critical Error
					_base_data_path = ""
					current_path_status = PathStatus.BROKEN_MISSING
			
			else:
				# SCENARIO B: Custom Mode Failure
				if default_exists:
					# Fallback to default, but warn user
					_base_data_path = default_path
					current_path_status = PathStatus.BROKEN_CUSTOM_FALLBACK
				else:
					# Both gone -> Critical Error
					_base_data_path = ""
					current_path_status = PathStatus.BROKEN_MISSING

	# 3. Finalize
	if _base_data_path != "":
		datasets_root_path = _base_data_path + "/datasets"
		deleted_root_path = _base_data_path + "/deleted_files"
		templates_root_path = _base_data_path + "/automation_templates"
		print("Data Library Loaded at: ", _base_data_path)
	else:
		print("CRITICAL: No valid data path found.")

func _read_bootstrap() -> Dictionary:
	var f = FileAccess.open(BOOTSTRAP_FILE, FileAccess.READ)
	if f:
		var json = JSON.new()
		if json.parse(f.get_as_text()) == OK:
			return json.data
	return {}

# UPDATED: Now accepts is_portable flag
func update_library_path(new_path: String, is_portable: bool = false) -> void:
	# 1. Save the pointer AND the mode
	var data = {
		"library_path": new_path,
		"is_portable": is_portable
	}
	var f = FileAccess.open(BOOTSTRAP_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))
		f.close()
	
	_base_data_path = new_path
	datasets_root_path = _base_data_path + "/datasets"
	deleted_root_path = _base_data_path + "/deleted_files"
	templates_root_path = _base_data_path + "/automation_templates"
	
	# If we are creating a new path, ensure folders exist
	_initialize_library_structure()
	
	toast_requested.emit("Library Path Updated!")
	
	# Reset state
	current_project_name = ""
	current_dataset.clear()
	current_columns.clear()
	current_path_status = PathStatus.OK # Reset error status if we just fixed it

func _initialize_library_structure() -> void:
	# DirAccess.make_dir_recursive_absolute is a static method. 
	# It's much cleaner than opening a directory instance first.
	
	# 1. Create Datasets folder
	if not DirAccess.dir_exists_absolute(datasets_root_path):
		var err = DirAccess.make_dir_recursive_absolute(datasets_root_path)
		if err != OK:
			error_occurred.emit("Failed to create folder: " + datasets_root_path)

	# 2. Create Trash folder
	if not DirAccess.dir_exists_absolute(deleted_root_path):
		var err = DirAccess.make_dir_recursive_absolute(deleted_root_path)
		if err != OK:
			error_occurred.emit("Failed to create folder: " + deleted_root_path)
			
	if not DirAccess.dir_exists_absolute(templates_root_path):
		DirAccess.make_dir_recursive_absolute(templates_root_path)

# --- CORE ACTIONS ---

func scan_projects() -> Array[String]:
	# Check if the directory exists before trying to open it
	if not DirAccess.dir_exists_absolute(datasets_root_path):
		# If it doesn't exist, just return empty. 
		# This handles the "Skip" case gracefully.
		return []

	var dir = DirAccess.open(datasets_root_path)
	if not dir:
		# If it exists but we can't open it (permissions?), THEN error.
		error_occurred.emit("Cannot access Data Folder!")
		return []

	dir.list_dir_begin()
	var file_name = dir.get_next()
	var found_projects: Array[String] = []
	while file_name != "":
		if dir.current_is_dir() and not file_name.begins_with("."):
			found_projects.append(file_name)
		file_name = dir.get_next()
	found_projects.sort()
	
	return found_projects

func load_project(project_name: String) -> void:
	current_project_name = project_name
	current_dataset.clear()
	current_columns.clear()
	
	var proj_path = datasets_root_path + "/" + project_name
	var config_path = proj_path + "/" + CONFIG_FILENAME
	
	# BRANCH: Check if config exists
	if FileAccess.file_exists(config_path):
		_load_project_from_config(proj_path, config_path)
	else:
		_load_project_from_scan(proj_path)

	project_loaded.emit()

# --- LOADING STRATEGIES ---

# Strategy 1: The original behavior (Scanning subfolders)
func _load_project_from_scan(proj_path: String) -> void:
	_column_path_map.clear() # Reset map
	
	var dir = DirAccess.open(proj_path)
	if not dir: 
		error_occurred.emit("Could not open project folder.")
		return

	dir.list_dir_begin()
	var item = dir.get_next()
	while item != "":
		if dir.current_is_dir() and not item.begins_with("."):
			current_columns.append(item)
			
			# In scan mode, the path is just the project folder + column name
			_column_path_map[item] = proj_path + "/" + item
			
		item = dir.get_next()
	current_columns.sort()
	
	for col_name in current_columns:
		_scan_folder_into_dataset(col_name, _column_path_map[col_name])

func _load_project_from_config(proj_path: String, config_file_path: String) -> void:
	_column_path_map.clear() # Reset map
	
	var f = FileAccess.open(config_file_path, FileAccess.READ)
	if not f:
		error_occurred.emit("Failed to read config file.")
		_load_project_from_scan(proj_path)
		return
		
	var json = JSON.new()
	var error = json.parse(f.get_as_text())
	if error != OK:
		error_occurred.emit("Config JSON Error: " + json.get_error_message())
		return
		
	var data = json.data
	if not data.has("columns") or not data["columns"] is Array:
		error_occurred.emit("Config missing 'columns' array.")
		return
		
	for col_def in data["columns"]:
		var col_name = col_def.get("name", "Unnamed")
		var raw_path = col_def.get("path", "")
		var final_path = _resolve_path(proj_path, raw_path)
		
		current_columns.append(col_name)
		
		# Store the resolved path in our map!
		_column_path_map[col_name] = final_path
		
		if DirAccess.dir_exists_absolute(final_path):
			_scan_folder_into_dataset(col_name, final_path)
		else:
			print("Warning: Configured path not found: ", final_path)

# --- HELPERS ---

# Shared helper to populate current_dataset
func _scan_folder_into_dataset(col_name: String, folder_path: String) -> void:
	var dir = DirAccess.open(folder_path)
	if not dir: return
	
	dir.list_dir_begin()
	var file = dir.get_next()
	while file != "":
		if not dir.current_is_dir() and not file.begins_with(".") and not file.ends_with(".import") and file != CONFIG_FILENAME:
			var stem = file.get_basename() 
			
			if not current_dataset.has(stem):
				current_dataset[stem] = {}
			
			if not current_dataset[stem].has(col_name):
				current_dataset[stem][col_name] = []
			
			current_dataset[stem][col_name].append(folder_path + "/" + file)
			
			# If we just added a second file, mark this column as conflicted
			if current_dataset[stem][col_name].size() > 1:
				if not column_conflicts.has(col_name):
					column_conflicts[col_name] = []
				
				# We don't know the page number yet because search/sorting 
				# happens in Main, so we'll just store the fact that it exists.
		file = dir.get_next()

func _resolve_path(proj_root: String, raw_path: String) -> String:
	# If it's an absolute path (e.g. C:/Images), use it directly
	if raw_path.is_absolute_path():
		return raw_path
	
	# Otherwise, treat it as relative to the project folder
	# simplify_path cleans up things like "folder/../folder"
	return (proj_root + "/" + raw_path).simplify_path()

# --- FILE OPERATIONS ---

func create_text_file(stem: String, col_name: String) -> void:
	if not _column_path_map.has(col_name):
		error_occurred.emit("Unknown column: " + col_name)
		return

	var folder_path = _column_path_map[col_name]
	var file_path = folder_path + "/" + stem + ".txt"
	
	var f = FileAccess.open(file_path, FileAccess.WRITE)
	if f:
		f.store_string("")
		f.close()
		# Partial reload is hard, simpler to full reload for now
		load_project(current_project_name)

func save_text_file(path: String, content: String) -> void:
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(content)
		f.close()
		toast_requested.emit("SAVED!")

func delete_file_permanently(path: String) -> void:
	var dir = DirAccess.open(path.get_base_dir())
	if dir and dir.remove(path.get_file()) == OK:
		toast_requested.emit("Permanently Deleted")
		load_project(current_project_name)
	else:
		error_occurred.emit("Failed to delete file.")

func move_file_to_trash(source_path: String) -> void:
	# 1. Determine the destination in the internal deleted_files folder.
	# We want to preserve hierarchy if possible, but for external files, 
	# we might just flat-map them or put them in an "External" folder.
	
	var target_subpath = ""
	
	if source_path.begins_with(datasets_root_path):
		# It's an internal file, preserve relative structure
		target_subpath = source_path.replace(datasets_root_path + "/", "")
	else:
		# It's external. To avoid path chaos, let's put it in a folder named after the project
		# and just use the filename.
		target_subpath = current_project_name + "/External_Deleted/" + source_path.get_file()

	var target_full_path = deleted_root_path + "/" + target_subpath
	var target_dir = target_full_path.get_base_dir()
	
	if not DirAccess.dir_exists_absolute(target_dir):
		DirAccess.make_dir_recursive_absolute(target_dir)
	
	# 2. Handle File Name Conflicts (Same as before)
	var final_path = target_full_path
	var extension = final_path.get_extension()
	
	# To properly increment, we need the filename base, not full path base
	var file_basename = final_path.get_file().get_basename()
	var folder = target_full_path.get_base_dir()
	
	var counter = 1
	while FileAccess.file_exists(final_path):
		final_path = folder + "/" + file_basename + " (%d)." % counter + extension
		counter += 1
		
	# 3. Move
	# We must use DirAccess.rename_absolute because source might be on a different drive
	var err = DirAccess.rename_absolute(source_path, final_path)
	if err == OK:
		toast_requested.emit("Moved to Trash")
		load_project(current_project_name)
	else:
		error_occurred.emit("Error moving file: " + error_string(err))

func populate_empty_files(col_name: String, content: String = "") -> void:
	if not _column_path_map.has(col_name):
		return
		
	var folder_path = _column_path_map[col_name]
	var stems_to_fill = []
	
	for stem in current_dataset:
		if current_dataset[stem].get(col_name, []).is_empty():
			stems_to_fill.append(stem)
			
	for stem in stems_to_fill:
		var file_path = folder_path + "/" + stem + ".txt"
		var f = FileAccess.open(file_path, FileAccess.WRITE)
		if f: 
			f.store_string(content)
			f.close()
			
	load_project(current_project_name)

# Handle Importing Files (Drag & Drop or Dialog)
# This centralizes the copy logic so Main doesn't need to know about paths.
func import_file(stem: String, col_name: String, source_path: String) -> void:
	if not _column_path_map.has(col_name):
		error_occurred.emit("Column path not found.")
		return
		
	var folder_path = _column_path_map[col_name]
	var ext = source_path.get_extension()
	var target_path = folder_path + "/" + stem + "." + ext
	
	# Use DirAccess.copy_absolute to support cross-drive copying
	var err = DirAccess.copy_absolute(source_path, target_path)
	if err == OK:
		load_project(current_project_name)
	else:
		error_occurred.emit("Import Failed: " + error_string(err))
	
func save_config(settings_data: Dictionary) -> void:
	var path = _base_data_path + "/dolina_settings.json"
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		var json_string = JSON.stringify(settings_data, "\t") # \t makes it pretty-printed
		file.store_string(json_string)
		file.close()

func load_config() -> Dictionary:
	var path = _base_data_path + "/dolina_settings.json"
	if not FileAccess.file_exists(path):
		return {} 
		
	var file = FileAccess.open(path, FileAccess.READ)
	if file:
		var content = file.get_as_text()
		var json = JSON.new()
		var error = json.parse(content)
		if error == OK:
			var data = json.data
			# NEW: Load autosave setting if it exists
			if data.has("autosave_enabled"):
				autosave_enabled = data["autosave_enabled"]
			return data
	return {}
	
func get_column_path(col_name: String) -> String:
	return _column_path_map.get(col_name, "")

func register_new_column(col_name: String) -> void:
	if current_project_name == "": return

	var proj_path = datasets_root_path + "/" + current_project_name
	var config_path = proj_path + "/" + CONFIG_FILENAME
	
	# 1. Update Memory & Folders
	var new_folder_path = proj_path + "/" + col_name
	if not DirAccess.dir_exists_absolute(new_folder_path):
		DirAccess.make_dir_recursive_absolute(new_folder_path)
		
	_column_path_map[col_name] = new_folder_path
	if not current_columns.has(col_name):
		current_columns.append(col_name)
		current_columns.sort()
	
	# 2. Update Config File
	var data = {}
	
	# Safe Read
	if FileAccess.file_exists(config_path):
		var f_read = FileAccess.open(config_path, FileAccess.READ)
		if f_read:
			var json = JSON.new()
			var err = json.parse(f_read.get_as_text())
			if err == OK:
				data = json.data
			f_read.close()
	
	# Initialize Structure
	if not data.has("columns") or not data["columns"] is Array:
		data["columns"] = []
	
	# Check for duplicates to prevent bloating the file
	var exists = false
	for col in data["columns"]:
		if col.get("name") == col_name:
			exists = true
			break
	
	if not exists:
		data["columns"].append({
			"name": col_name,
			"path": col_name
		})
		
		# Safe Write
		var f_write = FileAccess.open(config_path, FileAccess.WRITE)
		if f_write:
			f_write.store_string(JSON.stringify(data, "\t"))
			f_write.close()
			print("Config updated: Added ", col_name)

# --- TEMPLATE API ---

func list_templates() -> Array[String]:
	if not DirAccess.dir_exists_absolute(templates_root_path): return []
	
	var dir = DirAccess.open(templates_root_path)
	if not dir: return []
	
	var list: Array[String] = []
	dir.list_dir_begin()
	var file = dir.get_next()
	while file != "":
		if not dir.current_is_dir() and file.ends_with(".json"):
			list.append(file.get_basename())
		file = dir.get_next()
	list.sort()
	return list

func save_template(template_name: String, data: Dictionary) -> void:
	# Sanitize name
	var safe_name = template_name.validate_filename()
	var path = templates_root_path + "/" + safe_name + ".json"
	
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()
		toast_requested.emit("Template Saved!")

func load_template(template_name: String) -> Dictionary:
	var path = templates_root_path + "/" + template_name + ".json"
	if FileAccess.file_exists(path):
		var f = FileAccess.open(path, FileAccess.READ)
		if f:
			var json = JSON.new()
			if json.parse(f.get_as_text()) == OK:
				return json.data
	return {}

func delete_template(template_name: String) -> void:
	var path = templates_root_path + "/" + template_name + ".json"
	DirAccess.remove_absolute(path)
	toast_requested.emit("Template Deleted")
