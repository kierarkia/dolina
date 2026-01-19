class_name Row
extends HBoxContainer

# --- SIGNALS ---
signal request_full_image(stem: String, path: String)
signal request_delete_file(path: String)
signal request_create_txt(stem: String, column: String)
signal request_save_text(path: String, new_content: String)
signal request_upload(stem: String, column: String)
# NEW: Signal for when a file is dropped directly
signal request_direct_upload(stem: String, column: String, path: String)

var stem: String
var data: Dictionary
var columns: Array

const ROW_HEIGHT = 240 

# --- INNER CLASS: Custom Button that accepts files ---
class DragDropButton extends Button:
	signal file_dropped(path: String)
	
	func _ready() -> void:
		# Listen to the WINDOW for file drops
		get_viewport().files_dropped.connect(_on_files_dropped)
		
	func _on_files_dropped(files: PackedStringArray) -> void:
		# 1. Check if the mouse is hovering over THIS button right now
		if get_global_rect().has_point(get_global_mouse_position()):
			# 2. Check if visible (safety check)
			if is_visible_in_tree() and files.size() > 0:
				file_dropped.emit(files[0])

# ---------------------------------------------------

func setup(_stem: String, _data: Dictionary, _columns: Array, _cell_width: float, _row_height: float, _autosave_enabled: bool) -> void:
	stem = _stem
	data = _data
	columns = _columns
	
	for child in get_children():
		child.queue_free()
	
	# Pass autosave setting down to build_ui
	_build_ui(_cell_width, _row_height, _autosave_enabled)

func _build_ui(cell_width: float, row_height: float, autosave_enabled: bool) -> void:
	# 1. Stem Label
	var stem_label = Label.new()
	stem_label.text = stem
	stem_label.custom_minimum_size.x = 150
	stem_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stem_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(stem_label)
	
	# Fix 1: First VSeparator
	var sep1 = VSeparator.new()
	sep1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(sep1)
	
	# 2. Dynamic Columns
	for col_name in columns:
		var cell_container = HBoxContainer.new()
		# Click-through
		cell_container.mouse_filter = Control.MOUSE_FILTER_IGNORE 
		
		cell_container.custom_minimum_size.x = cell_width
		
		cell_container.custom_minimum_size.y = row_height 
		
		cell_container.size_flags_horizontal = SIZE_EXPAND_FILL 
		cell_container.alignment = BoxContainer.ALIGNMENT_CENTER
		
		var files = data.get(col_name, [])
		
		if files.is_empty():
			_create_empty_state(cell_container, col_name)
		elif files.size() > 1:
			_create_conflict_state(cell_container, files)
		else:
			_create_file_view(cell_container, files[0], cell_width, row_height, autosave_enabled)
			
		add_child(cell_container)
		
		# Fix 2: VSeparator between columns
		var sep2 = VSeparator.new()
		sep2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(sep2)

# --- CELL STATES ---

func _create_empty_state(parent: Node, col_name: String) -> void:
	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	parent.add_child(vbox)
	
	var btn_create = Button.new()
	btn_create.text = "+ Create .txt"
	btn_create.pressed.connect(func(): emit_signal("request_create_txt", stem, col_name))
	vbox.add_child(btn_create)
	
	# CHANGE: Use our custom DragDropButton
	var btn_upload = DragDropButton.new()
	# Text with newline for height
	btn_upload.text = "⬆ Upload File\n(Drag & Drop)"
	btn_upload.alignment = HORIZONTAL_ALIGNMENT_CENTER
	
	# Force minimum height for easier dropping
	btn_upload.custom_minimum_size.y = 80
	
	# Normal click -> Open Dialog
	btn_upload.pressed.connect(func(): emit_signal("request_upload", stem, col_name))
	
	# Drag Drop -> Direct Upload
	btn_upload.file_dropped.connect(func(path): emit_signal("request_direct_upload", stem, col_name, path))
	
	vbox.add_child(btn_upload)

func _create_conflict_state(parent: Node, files: Array) -> void:
	if parent is BoxContainer: parent.alignment = BoxContainer.ALIGNMENT_BEGIN
	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	parent.add_child(scroll)
	var vbox = VBoxContainer.new()
	scroll.add_child(vbox)
	var label = Label.new()
	label.text = "⚠️ Conflict: %d" % files.size()
	label.modulate = Color.ORANGE
	vbox.add_child(label)
	for f_path in files:
		var row = HBoxContainer.new()
		vbox.add_child(row)
		var f_label = Label.new()
		f_label.text = f_path.get_file()
		f_label.clip_text = true
		f_label.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(f_label)
		var del_btn = Button.new()
		del_btn.text = "X"
		del_btn.modulate = Color.RED
		del_btn.pressed.connect(func(): emit_signal("request_delete_file", f_path))
		row.add_child(del_btn)
		
func _create_file_view(parent: Node, file_path: String, max_width: float = 2000.0, row_height: float = 240.0, autosave_enabled: bool = false) -> void:
	var ext = file_path.get_extension().to_lower()
	
	var sidebar = VBoxContainer.new()
	sidebar.alignment = BoxContainer.ALIGNMENT_CENTER
	sidebar.custom_minimum_size.x = 40 
	var del_btn = Button.new()
	del_btn.text = "🗑️"
	del_btn.tooltip_text = "Delete"
	del_btn.modulate = Color(1, 0.4, 0.4)
	del_btn.pressed.connect(func(): emit_signal("request_delete_file", file_path))
	
	# A. IMAGES
	if ext in ["png", "jpg", "jpeg", "webp"]:
		var img_btn = Button.new()
		img_btn.flat = true
		img_btn.clip_contents = true
		img_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
		img_btn.size_flags_vertical = SIZE_SHRINK_CENTER
		img_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		
		var init_size = min(row_height, max_width - 50)
		img_btn.custom_minimum_size = Vector2(init_size, row_height)
		
		var placeholder_lbl = Label.new()
		placeholder_lbl.text = "Loading..."
		placeholder_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		placeholder_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		placeholder_lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
		placeholder_lbl.modulate = Color(1, 1, 1, 0.5)
		img_btn.add_child(placeholder_lbl)
		
		var tex_rect = TextureRect.new()
		tex_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE 
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE 
		img_btn.add_child(tex_rect)
		
		ThumbnailLoader.request_thumbnail(file_path, int(row_height * 2), func(texture):
			if is_instance_valid(img_btn) and texture:
				tex_rect.texture = texture
				
				var t_size = texture.get_size()
				var aspect = t_size.x / t_size.y
				
				# --- USE VARIABLE HERE ---
				var display_h = row_height
				var display_w = int(display_h * aspect)
				
				var safe_max_w = max_width - 40 - 10 
				
				if display_w > safe_max_w:
					display_w = safe_max_w
					display_h = display_w / aspect
				
				display_w = min(display_w, safe_max_w)
				
				img_btn.custom_minimum_size = Vector2(display_w, display_h)
				placeholder_lbl.queue_free()
		)
		
		img_btn.pressed.connect(func(): _on_image_clicked(file_path))
		
		parent.add_child(img_btn)
		sidebar.add_child(del_btn)
		parent.add_child(sidebar)

	# B. TEXT FILES
	elif ext in ["txt", "md", "json"]:
		if parent is BoxContainer: parent.alignment = BoxContainer.ALIGNMENT_BEGIN
		
		var text_edit = TextEdit.new()
		text_edit.size_flags_horizontal = SIZE_EXPAND_FILL
		text_edit.size_flags_vertical = SIZE_EXPAND_FILL
		text_edit.editable = true
		text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		
		# Define the flash effect
		var flash_success = func():
			var original_modulate = Color(1, 1, 1, 1)
			text_edit.modulate = Color(0.5, 1.0, 0.5) # Green flash
			var tween = create_tween()
			tween.tween_property(text_edit, "modulate", original_modulate, 0.3)
		
		if autosave_enabled:
			var timer = Timer.new()
			timer.wait_time = 2.0 # Wait 2 seconds after typing stops
			timer.one_shot = true
			text_edit.add_child(timer) # Add timer as child of the text box
			
			# When text changes, (re)start the timer
			text_edit.text_changed.connect(func():
				timer.start()
			)
			
			# When timer finishes, save!
			timer.timeout.connect(func():
				# Only save if visible (safety check)
				if not text_edit.is_visible_in_tree(): return
				
				emit_signal("request_save_text", file_path, text_edit.text)
				flash_success.call()
				# Note: Toast is handled by Main connecting to the signal, 
				# but maybe we want to suppress the toast for autosaves? 
				# For now, let's keep it to reassure the user.
			)
		
		text_edit.gui_input.connect(func(event):
			if event is InputEventKey and event.pressed and event.keycode == KEY_S:
				if event.is_command_or_control_pressed():
					get_viewport().set_input_as_handled()
					emit_signal("request_save_text", file_path, text_edit.text)
					flash_success.call() 
		)
		
		var f = FileAccess.open(file_path, FileAccess.READ)
		if f: text_edit.text = f.get_as_text()
		parent.add_child(text_edit)
		
		var save_btn = Button.new()
		save_btn.text = "💾"
		save_btn.tooltip_text = "Save Changes (Ctrl+S)"
		save_btn.pressed.connect(func(): 
			emit_signal("request_save_text", file_path, text_edit.text)
			flash_success.call() 
		)
		
		sidebar.add_child(save_btn)
		sidebar.add_child(HSeparator.new())
		sidebar.add_child(del_btn)
		parent.add_child(sidebar)

func _on_image_clicked(path: String) -> void:
	emit_signal("request_full_image", stem, path)
