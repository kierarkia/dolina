class_name SearchManager
extends Node

# --- SIGNALS ---
signal search_started
signal search_completed(results: Array)

# --- CONFIG ---
const DEBOUNCE_TIME: float = 0.3

# --- STATE ---
var _search_filters: Dictionary = {}
var _current_search_version: int = 0
var _debounce_timer: Timer

# We store the reference explicitly
var _project_manager: ProjectManager 

func _ready() -> void:
	_debounce_timer = Timer.new()
	_debounce_timer.one_shot = true
	_debounce_timer.wait_time = DEBOUNCE_TIME
	add_child(_debounce_timer)
	
	_debounce_timer.timeout.connect(_execute_search_now)

# Main calls this to give us the reference
func setup(pm: ProjectManager) -> void:
	_project_manager = pm

# --- PUBLIC API ---

func update_filter(col_identifier: String, text: String) -> void:
	if text.strip_edges() == "":
		_search_filters.erase(col_identifier)
	else:
		_search_filters[col_identifier] = text.to_lower()
	
	_debounce_timer.start()

func clear_filters() -> void:
	_search_filters.clear()
	_debounce_timer.stop()
	search_completed.emit([]) 

func get_active_filters() -> Dictionary:
	return _search_filters

func is_active() -> bool:
	return not _search_filters.is_empty()

# --- INTERNAL LOGIC ---

func _execute_search_now() -> void:
	if _search_filters.is_empty():
		search_completed.emit([])
		return

	# SAFETY CHECK: If we haven't been set up, stop.
	if not _project_manager: 
		return

	search_started.emit()
	
	_current_search_version += 1
	var this_version = _current_search_version
	
	# USE THE INJECTED VARIABLE INSTEAD OF %
	var dataset = _project_manager.current_dataset
	var stems_to_search = dataset.keys()
	var filters_snapshot = _search_filters.duplicate()
	
	WorkerThreadPool.add_task(
		_threaded_search_task.bind(this_version, stems_to_search, dataset, filters_snapshot)
	)

func _threaded_search_task(task_version: int, stems: Array, dataset: Dictionary, filters: Dictionary) -> void:
	var results: Array = []
	
	for i in range(stems.size()):
		# 1. Cancellation Check
		if i % 20 == 0:
			if task_version != _current_search_version:
				return 

		var stem = stems[i]
		var row_data = dataset.get(stem)
		if row_data == null: continue
		
		# 2. Matching Logic
		var match_all = true
		
		for col_key in filters:
			var query = filters[col_key]
			
			if col_key == "ID":
				if not stem.to_lower().contains(query):
					match_all = false
					break
			else:
				var files = row_data.get(col_key, [])
				var col_match = false
				
				# A. Filenames
				for f_path in files:
					if f_path.get_file().to_lower().contains(query):
						col_match = true
						break
				
				# B. Content (Disk I/O)
				if not col_match:
					for f_path in files:
						var ext = f_path.get_extension().to_lower()
						if ext in ["txt", "md", "json"]:
							var f = FileAccess.open(f_path, FileAccess.READ)
							if f and f.get_as_text().to_lower().contains(query):
								col_match = true
								break
				
				if not col_match:
					match_all = false
					break
		
		if match_all:
			results.append(stem)

	# 3. Return to Main Thread
	call_deferred("_on_thread_complete", results, task_version)

func _on_thread_complete(results: Array, task_version: int) -> void:
	if task_version != _current_search_version:
		return
	
	# Sort results for consistency
	results.sort()
	search_completed.emit(results)
