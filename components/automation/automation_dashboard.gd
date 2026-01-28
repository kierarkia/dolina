class_name AutomationDashboard
extends Control

# --- SIGNALS ---
signal request_reload
signal batch_started
signal batch_ended
signal progress_changed(current: int, total: int)

# --- SCENES ---
const InputBlockScene = preload("res://components/automation/InputBlock.tscn")
const ApiBlockScene = preload("res://components/automation/ApiBlock.tscn")

# --- NODES ---
@onready var block_list: VBoxContainer = %BlockList
@onready var add_block_btn: Button = %AddBlockBtn
@onready var start_btn: Button = %StartBtn
@onready var stop_btn: Button = %StopBtn
@onready var logs: TextEdit = %Logs
@onready var progress_bar: ProgressBar = %ProgressBar
@onready var api_client: ApiClient = $ApiClient
@onready var close_btn: Button = %CloseBtn
@onready var preview_text: TextEdit = %PreviewText 
@onready var preview_timer: Timer = Timer.new()
@onready var temp_input: SpinBox = %TempInput
@onready var max_tokens_input: SpinBox = %MaxTokensInput
@onready var wait_input: SpinBox = %WaitInput
@onready var api_block_list: VBoxContainer = %ApiBlockList
@onready var add_api_btn: Button = %AddApiBtn
@onready var template_select: OptionButton = %TemplateSelect
@onready var save_template_btn: Button = %SaveTemplateBtn
@onready var delete_template_btn: Button = %DeleteTemplateBtn
@onready var save_template_dialog: ConfirmationDialog = %SaveTemplateDialog
@onready var template_name_input: LineEdit = %TemplateNameInput

# Settings Inputs
@onready var target_col_input: LineEdit = %TargetColInput
@onready var resume_check: CheckBox = %ResumeCheck

# --- STATE ---
var _project_manager: ProjectManager
var _is_running: bool = false
var _queue: Array = [] # Array of Stems to process
var _current_stem: String = ""
var _wrr_state: Array = [] # Weighted Round Robin counters
var _provider_configs: Array = [] # Cache of configs for the run

func setup(pm: ProjectManager) -> void:
	_project_manager = pm
	_refresh_columns()
	_refresh_template_list()
	
	# Force selection to "EMPTY TEMPLATE" on startup
	template_select.selected = 0
	
	# Only add default blocks if we are truly empty (failsafe)
	if block_list.get_child_count() == 0:
		_add_block()
	if api_block_list.get_child_count() == 0:
		_add_api_block()

func _ready() -> void:
	add_block_btn.pressed.connect(_add_block)
	start_btn.pressed.connect(_start_batch)
	stop_btn.pressed.connect(_stop_batch)
	
	if not api_client.request_completed.is_connected(_on_api_success):
		api_client.request_completed.connect(_on_api_success)
	if not api_client.request_failed.is_connected(_on_api_fail):
		api_client.request_failed.connect(_on_api_fail)
	if not api_client.log_message.is_connected(_log):
		api_client.log_message.connect(_log)
	
	if close_btn:
		close_btn.pressed.connect(func(): hide())
	
	# Setup Debounce Timer
	add_child(preview_timer)
	preview_timer.wait_time = 0.2
	preview_timer.one_shot = true
	preview_timer.timeout.connect(_update_live_preview)

	# DEBUG: Let's also print to see if adding blocks works
	add_block_btn.pressed.connect(func(): print("Add Block Clicked"))
	add_api_btn.pressed.connect(_add_api_block)
	if api_block_list.get_child_count() == 0:
		_add_api_block()
		
	# TEMPLATE CONNECTIONS
	template_select.item_selected.connect(_on_template_selected)
	save_template_btn.pressed.connect(func(): 
		template_name_input.text = ""
		# Pre-fill if editing an existing template
		if template_select.selected > 0:
			template_name_input.text = template_select.get_item_text(template_select.selected)
		save_template_dialog.popup_centered()
		template_name_input.grab_focus()
	)
	
	delete_template_btn.pressed.connect(_on_delete_template)
	
	save_template_dialog.confirmed.connect(func():
		var template_name = template_name_input.text.strip_edges()
		if template_name != "":
			_perform_save_template(template_name)
	)
	
func _update_live_preview() -> void:
	if _project_manager.current_dataset.is_empty():
		preview_text.text = "// No dataset loaded"
		return

	# Use the first available stem for the preview
	var stem = _project_manager.current_dataset.keys()[0]
	
	# 1. Get the real payload
	var msgs = _construct_messages(stem)
	
	# --- FIX: Handle Null/Invalid State ---
	if msgs == null:
		preview_text.text = "// Payload is empty or invalid.\n// (Check if your static prompts are empty or if the source column has data of the correct type.)"
		return
	# --------------------------------------
	
	# 2. Create a DEEP COPY for the UI so we don't accidentally modify the real data
	var display_msgs = msgs.duplicate(true)
	
	# 3. Iterate through the copy and truncate Base64 strings
	for msg in display_msgs:
		if msg.has("content") and msg["content"] is Array:
			for block in msg["content"]:
				if block.get("type") == "image_url":
					var url_data = block.get("image_url", {})
					if url_data.has("url") and url_data["url"].begins_with("data:"):
						# Keep the MIME type prefix (e.g. "data:image/jpeg;base64,") for clarity
						var full_string = url_data["url"]
						var comma_index = full_string.find(",")
						
						if comma_index != -1:
							var prefix = full_string.substr(0, comma_index + 1)
							url_data["url"] = prefix + " ... <BASE64_IMAGE_DATA_TRUNCATED> ..."
						else:
							url_data["url"] = "<BASE64_IMAGE_DATA_TRUNCATED>"

	preview_text.text = JSON.stringify(display_msgs, "\t")
	
func _construct_messages(stem: String) -> Variant: 
	var messages_content = []
	var dataset = _project_manager.current_dataset
	
	# Temporary buffer for merging text
	var current_text_buffer = ""
	
	for child in block_list.get_children():
		if not child is InputBlock: continue
		var cfg = child.get_config()
		
		match cfg.type:
			InputBlock.Type.STATIC_TEXT:
				if cfg.value != "":
					current_text_buffer += cfg.value + "\n\n"
					
			InputBlock.Type.DATA_TEXT:
				var col = cfg.column
				var files = dataset.get(stem, {}).get(col, [])
				
				# FILTER LOGIC: Find the first text file
				var found_text = false
				for path in files:
					var ext = path.get_extension().to_lower()
					if ext in ["png", "jpg", "jpeg", "webp", "gif", "bin"]: continue
					
					var f = FileAccess.open(path, FileAccess.READ)
					if f:
						current_text_buffer += f.get_as_text() + "\n\n"
						found_text = true
						break 
				
				# STRICT CHECK: If block requested text but none found, FAIL the row.
				if not found_text:
					return null 
			
			InputBlock.Type.DATA_IMAGE:
				var col = cfg.column
				var files = dataset.get(stem, {}).get(col, [])
				
				# FILTER LOGIC: Find the first image file
				var found_img = false
				
				for path in files:
					var ext = path.get_extension().to_lower()
					if ext in ["png", "jpg", "jpeg", "webp"]:
						# 1. Flush text buffer first
						if current_text_buffer.strip_edges() != "":
							messages_content.append(ApiClient.create_text_content(current_text_buffer.strip_edges()))
							current_text_buffer = ""
						
						# 2. Add Image
						var img_block = ApiClient.create_image_content(path)
						if not img_block.is_empty():
							messages_content.append(img_block)
							found_img = true
						break 
				
				# STRICT CHECK: If block requested image but none found, FAIL the row.
				if not found_img:
					return null

	# Flush any remaining text at the end
	if current_text_buffer.strip_edges() != "":
		messages_content.append(ApiClient.create_text_content(current_text_buffer.strip_edges()))
	
	# If we ended up with absolutely nothing (e.g. empty static prompts and no data), fail.
	if messages_content.is_empty():
		return null
	
	return [{ "role": "user", "content": messages_content }]

func _refresh_columns() -> void:
	var cols = _project_manager.current_columns
	for child in block_list.get_children():
		if child is InputBlock:
			child.setup_columns(cols)

func _add_block() -> void:
	if _project_manager == null: return

	var block = InputBlockScene.instantiate()
	block_list.add_child(block)
	
	block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	block.setup_columns(_project_manager.current_columns)
	
	block.deleted_requested.connect(func(): 
		block.queue_free()
		# Trigger update after frame so node is gone
		await get_tree().process_frame
		preview_timer.start()
	)
	
	block.content_changed.connect(func(): preview_timer.start())
	
	preview_timer.start()

func _add_api_block() -> void:
	var block = ApiBlockScene.instantiate()
	api_block_list.add_child(block)
	
	block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	block.deleted_requested.connect(func():
		block.queue_free()
		await get_tree().process_frame
		_recalculate_ratios()
	)
	
	block.config_changed.connect(_recalculate_ratios)
	
	_recalculate_ratios()

func _recalculate_ratios() -> void:
	# 1. Sum total weight
	var total_weight = 0
	
	for child in api_block_list.get_children():
		# Ignore nodes that are about to be deleted
		if child.is_queued_for_deletion(): 
			continue
			
		if child is ApiBlock:
			total_weight += child.get_config().weight
	
	# 2. Get dataset size estimate (for UI feedback only)
	var est_size = 0
	if _project_manager and not _project_manager.current_dataset.is_empty():
		est_size = _project_manager.current_dataset.keys().size()
	
	# 3. Update labels
	for child in api_block_list.get_children():
		if child.is_queued_for_deletion(): 
			continue

		if child is ApiBlock:
			child.update_stats(total_weight, est_size)

func _log(msg: String) -> void:
	logs.text += msg + "\n"
	logs.scroll_vertical = logs.get_line_count()

# --- BATCH EXECUTION LOGIC ---

func _validate_batch_setup() -> bool:
	var dataset = _project_manager.current_dataset
	
	# Check each data block
	for child in block_list.get_children():
		if not child is InputBlock: continue
		var cfg = child.get_config()
		
		# We only care about DATA blocks
		if cfg.type == InputBlock.Type.STATIC_TEXT: continue
		
		var col = cfg.column
		var valid_items_found = 0
		
		# Scan the ENTIRE queue to see if *any* valid file exists for this block
		# (We iterate the _queue so we only check files we intend to process)
		for stem in _queue:
			var files = dataset.get(stem, {}).get(col, [])
			for path in files:
				var ext = path.get_extension().to_lower()
				var is_img = ext in ["png", "jpg", "jpeg", "webp"]
				
				if cfg.type == InputBlock.Type.DATA_IMAGE and is_img:
					valid_items_found += 1
					break
				elif cfg.type == InputBlock.Type.DATA_TEXT and not is_img:
					valid_items_found += 1
					break
			
			# Optimization: We only need to find ONE valid item to prove the column isn't "dead"
			if valid_items_found > 0:
				break
		
		if valid_items_found == 0:
			var type_str = "Image" if cfg.type == InputBlock.Type.DATA_IMAGE else "Text"
			_log("Error: Column '%s' contains NO valid %s files for the queued items." % [col, type_str])
			return false
			
	return true

func _start_batch() -> void:
	if _is_running: return
	
	# 1. Validation & Column Registration
	var target_col = target_col_input.text.strip_edges()
	if target_col == "":
		_log("Error: Please specify a target column name.")
		return

	# Register the column ONCE before starting (Updates dolina_dataset_config.json)
	_project_manager.register_new_column(target_col)
	
	# 2. Gather API Providers from the UI List
	_provider_configs.clear()
	
	for child in api_block_list.get_children():
		if child is ApiBlock:
			var cfg = child.get_config()
			# Only add if URL and Model are filled in (Key might be empty for local LLMs)
			if cfg.url != "" and cfg.model != "":
				_provider_configs.append(cfg)
	
	if _provider_configs.is_empty():
		_log("Error: No valid API Endpoints configured. Please add at least one.")
		return
		
	# 3. Initialize Weighted Round-Robin (WRR) State
	# We create a counter for each provider, starting at 0.
	_wrr_state.clear()
	for i in range(_provider_configs.size()):
		_wrr_state.append(0)
	
	# 4. Build the Processing Queue
	_queue.clear()
	var dataset = _project_manager.current_dataset
	var keys = dataset.keys()
	keys.sort()
	
	for stem in keys:
		# Resume Logic: Skip if file exists in target column
		if resume_check.button_pressed:
			var existing = dataset[stem].get(target_col, [])
			if not existing.is_empty():
				continue
		_queue.append(stem)
		
	if not _validate_batch_setup():
		_log("Batch aborted due to configuration errors.")
		return

	# 6. UI Updates
	_is_running = true
	start_btn.disabled = true
	stop_btn.disabled = false
	
	progress_bar.max_value = _queue.size()
	progress_bar.value = 0
	
	batch_started.emit()
	progress_changed.emit(0, _queue.size())
	
	_log("Batch started. Items in queue: %d" % _queue.size())
	_log("Load balancing across %d endpoint(s)." % _provider_configs.size())
	
	# 7. Kick off the loop
	_process_next()

func _stop_batch() -> void:
	_is_running = false
	start_btn.disabled = false
	stop_btn.disabled = true
	_log("Batch stopped by user.")

func _process_next() -> void:
	if not _is_running: return
	if _queue.is_empty():
		_finish_batch()
		return
		
	_current_stem = _queue.pop_front()
	progress_bar.value += 1
	progress_changed.emit(int(progress_bar.value), int(progress_bar.max_value))
	
	# 1. Construct Payload
	var messages = _construct_messages(_current_stem)
	
	# --- SKIP LOGIC ---
	if messages == null:
		_log("Skipping '%s': Missing required source data." % _current_stem)
		await get_tree().process_frame 
		_process_next()
		return
	# ------------------
	
	# 2. WEIGHTED ROUND ROBIN
	var total_weight = 0
	var selected_idx = 0
	var max_val = -999999
	
	for i in range(_provider_configs.size()):
		var w = _provider_configs[i].weight
		total_weight += w
		
		# Step 1: Increase current counter by weight
		_wrr_state[i] += w
		
		# Step 2: Find the provider with the highest counter
		if _wrr_state[i] > max_val:
			max_val = _wrr_state[i]
			selected_idx = i
			
	# Step 3: Decrease the selected provider's counter by total weight
	_wrr_state[selected_idx] -= total_weight
	
	var active_config = _provider_configs[selected_idx]
	# -----------------------------------------------------

	_log("[%s] Processing: %s..." % [active_config.model, _current_stem])
	
	# 3. Send Request
	api_client.send_request(
		active_config.url,
		active_config.key,
		active_config.model,
		messages,
		temp_input.value,
		int(max_tokens_input.value)
	)

func _on_api_success(response: Dictionary) -> void:
	if not _is_running: return
	
	var content = ""
	if response.has("choices") and response["choices"].size() > 0:
		var choice = response["choices"][0]
		if choice.has("message") and choice["message"].has("content"):
			content = choice["message"]["content"]
	
	if content == "":
		_log("Warning: Empty response for %s" % _current_stem)
	else:
		_log("Success. Saving...")
		
		var target_col = target_col_input.text.strip_edges()
		var root = _project_manager.datasets_root_path + "/" + _project_manager.current_project_name
		var folder_path = root + "/" + target_col
		
		# Ensure folder exists (Redundant check but safe)
		if not DirAccess.dir_exists_absolute(folder_path):
			DirAccess.make_dir_recursive_absolute(folder_path)
			
		var file_path = folder_path + "/" + _current_stem + ".txt"
		var f = FileAccess.open(file_path, FileAccess.WRITE)
		if f:
			f.store_string(content)
			f.close()
			
			if not _project_manager.current_dataset[_current_stem].has(target_col):
				_project_manager.current_dataset[_current_stem][target_col] = []
			_project_manager.current_dataset[_current_stem][target_col].append(file_path)

	var wait_time = 0.1 # Default small buffer
	
	# If we have the wait input (from the UI update), use it
	if self.get("wait_input"): 
		wait_time = max(0.05, wait_input.value)
		if wait_time > 0.5:
			_log("Waiting %.1fs..." % wait_time)
	
	await get_tree().create_timer(wait_time).timeout
	_process_next()

func _on_api_fail(msg: String, code: int) -> void:
	_log("FAILED on %s: %s (Code: %d)" % [_current_stem, msg, code])
	_is_running = false
	start_btn.disabled = false
	stop_btn.disabled = true

func _finish_batch() -> void:
	_is_running = false
	start_btn.disabled = false
	stop_btn.disabled = true
	progress_bar.value = progress_bar.max_value
	_log("Batch Completed! Reloading project...")
	batch_ended.emit()
	
	# Trigger the toast
	_project_manager.toast_requested.emit("Batch Processing Complete!")
	
	# Ask Main to do it gracefully
	request_reload.emit()

func _refresh_template_list() -> void:
	var current_selection = ""
	if template_select.selected >= 0:
		current_selection = template_select.get_item_text(template_select.selected)
	
	template_select.clear()
	template_select.add_item("EMPTY TEMPLATE") # Index 0
	# We do NOT disable it anymore. We want it clickable.
	
	var list = _project_manager.list_templates()
	for t in list:
		template_select.add_item(t)
		
	# Restore selection if possible, otherwise default to 0
	var found = false
	for i in range(template_select.item_count):
		if template_select.get_item_text(i) == current_selection:
			template_select.selected = i
			found = true
			break
	
	if not found:
		template_select.selected = 0
		
func _reset_to_default_state() -> void:
	# 1. Clear Inputs
	for child in block_list.get_children():
		child.queue_free()
	
	# 2. Clear APIs
	for child in api_block_list.get_children():
		child.queue_free()
		
	await get_tree().process_frame
	
	# 3. Add Defaults
	_add_block()
	_add_api_block()
	
	# 4. Reset Settings
	target_col_input.text = ""
	resume_check.button_pressed = false
	temp_input.value = 0.7
	max_tokens_input.value = 4096
	wait_input.value = 0.1
	
	preview_timer.start()
		
func _perform_save_template(template_name: String) -> void: # Renamed arg
	var data = {
		"target_col": target_col_input.text,
		"resume": resume_check.button_pressed,
		"temp": temp_input.value,
		"max_tokens": max_tokens_input.value,
		"wait_time": wait_input.value,
		"inputs": [],
		"apis": []
	}
	
	for child in block_list.get_children():
		if child is InputBlock:
			data["inputs"].append(child.get_config())
			
	for child in api_block_list.get_children():
		if child is ApiBlock:
			var cfg = child.get_config()
			cfg["key"] = "" # Security
			data["apis"].append(cfg)
			
	_project_manager.save_template(template_name, data)
	_refresh_template_list()
	
	# Select the new item
	for i in range(template_select.item_count):
		if template_select.get_item_text(i) == template_name:
			template_select.selected = i
			break

func _on_template_selected(index: int) -> void:
	# CASE 1: Empty/Reset
	if index == 0:
		_reset_to_default_state()
		return
	
	# CASE 2: Load Actual Template
	var template_name = template_select.get_item_text(index)
	var data = _project_manager.load_template(template_name)
	if data.is_empty(): return
	
	# 1. Restore Global Settings
	if data.has("target_col"): target_col_input.text = data["target_col"]
	if data.has("resume"): resume_check.button_pressed = data["resume"]
	if data.has("temp"): temp_input.value = data["temp"]
	if data.has("max_tokens"): max_tokens_input.value = data["max_tokens"]
	if data.has("wait_time"): wait_input.value = data["wait_time"]
	
	# 2. Restore Inputs
	for child in block_list.get_children():
		child.queue_free()
	
	await get_tree().process_frame
	
	if data.has("inputs"):
		for cfg in data["inputs"]:
			var block = InputBlockScene.instantiate()
			block_list.add_child(block)
			block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			
			# Setup
			block.setup_columns(_project_manager.current_columns)
			block.deleted_requested.connect(func(): 
				block.queue_free()
				await get_tree().process_frame
				preview_timer.start()
			)
			block.content_changed.connect(func(): preview_timer.start())
			
			# CLEANER: Use the new helper
			block.set_config(cfg)

	# 3. Restore APIs
	for child in api_block_list.get_children():
		child.queue_free()
		
	await get_tree().process_frame
	
	if data.has("apis"):
		for cfg in data["apis"]:
			var block = ApiBlockScene.instantiate()
			api_block_list.add_child(block)
			block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			
			# Setup
			block.deleted_requested.connect(func():
				block.queue_free()
				await get_tree().process_frame
				_recalculate_ratios()
			)
			block.config_changed.connect(_recalculate_ratios)
			
			# CLEANER: Use the new helper
			block.set_config(cfg)
			
	# Trigger updates
	preview_timer.start()
	_recalculate_ratios()

func _on_delete_template() -> void:
	if template_select.selected <= 0: return
	var template_name = template_select.get_item_text(template_select.selected) # Renamed var
	
	_project_manager.delete_template(template_name)
	_refresh_template_list()
	template_select.selected = 0
