class_name SideBySideViewer
extends ColorRect

# --- SIGNALS ---
signal request_save_text(path: String, content: String)
signal closed

# --- NODES ---
@onready var close_btn: Button = $MarginContainer/VBoxContainer/TopBar/CloseBtn

# Left Side UI
@onready var col_select_left: OptionButton = %ColSelectLeft
@onready var img_left: TextureRect = $MarginContainer/VBoxContainer/SplitView/LeftPanel/ContentContainer/ImageRect
@onready var text_wrapper_left: VBoxContainer = $MarginContainer/VBoxContainer/SplitView/LeftPanel/ContentContainer/TextWrapper

# Right Side UI
@onready var col_select_right: OptionButton = %ColSelectRight
@onready var img_right: TextureRect = $MarginContainer/VBoxContainer/SplitView/RightPanel/ContentContainer/ImageRect
@onready var text_wrapper_right: VBoxContainer = $MarginContainer/VBoxContainer/SplitView/RightPanel/ContentContainer/TextWrapper

# Nav
@onready var btn_prev_row: Button = %BtnPrevRow
@onready var btn_next_row: Button = %BtnNextRow
@onready var position_label: Label = %PositionLabel

# Used for Click-Off detection (The actual visual UI box)
@onready var ui_box: VBoxContainer = $MarginContainer/VBoxContainer

# --- ASSETS ---
const CURSOR_MAGNIFIER = preload("res://assets/magnifying_glass.svg")
const CURSOR_HOTSPOT = Vector2(21, 21)
const ZOOM_LEVEL: float = 3.0
const DRAG_THRESHOLD: float = 5.0

# --- STATE ---
var _dataset: Dictionary = {}
var _stems: Array = [] 
var _current_index: int = 0
var _columns: Array[String] = []

# Helpers
var _left_controller: TextController
var _right_controller: TextController

# Zoom/Pan State
var _dragging_left: bool = false
var _dragging_right: bool = false
var _drag_start_mouse_pos: Vector2
var _drag_start_img_pos: Vector2
var _has_dragged_significantly: bool = false

# --- INNER CLASS: HANDLES TEXT LOGIC ---
class TextController:
	var wrapper: VBoxContainer
	var editor: CodeEdit
	var search_panel: PanelContainer
	var status_label: Label
	
	# Toolbar
	var btn_save: Button
	var btn_search: Button
	var btn_replace: Button
	
	# Search UI
	var input_find: LineEdit
	var input_replace: LineEdit
	var btn_next: Button
	var btn_prev: Button
	var btn_rep_one: Button
	var btn_rep_all: Button
	var btn_close_search: Button
	var replace_bar: Control
	
	var parent_viewer: SideBySideViewer
	var autosave_timer: Timer
	
	func _init(_wrapper: VBoxContainer, _viewer: SideBySideViewer):
		wrapper = _wrapper
		parent_viewer = _viewer
		
		# Locate Nodes
		editor = wrapper.get_node("TextEdit")
		search_panel = wrapper.get_node("SearchPanel")
		status_label = wrapper.get_node("Footer/StatusLabel")
		
		var toolbar = wrapper.get_node("Toolbar")
		btn_save = toolbar.get_node("SaveBtn")
		btn_search = toolbar.get_node("SearchBtn")
		btn_replace = toolbar.get_node("ReplaceBtn")
		
		var search_vbox = search_panel.get_node("VBoxContainer")
		var find_bar = search_vbox.get_node("FindBar")
		replace_bar = search_vbox.get_node("ReplaceBar")
		
		input_find = find_bar.get_node("FindInput")
		btn_prev = find_bar.get_node("FindPrev")
		btn_next = find_bar.get_node("FindNext")
		btn_close_search = find_bar.get_node("CloseSearch")
		
		input_replace = replace_bar.get_node("ReplaceInput")
		btn_rep_one = replace_bar.get_node("ReplaceOne")
		btn_rep_all = replace_bar.get_node("ReplaceAll")
		
		_connect_signals()
		
		autosave_timer = Timer.new()
		autosave_timer.wait_time = 2.0
		autosave_timer.one_shot = true
		wrapper.add_child(autosave_timer)
		autosave_timer.timeout.connect(save_if_needed.bind("Autosaved"))
		
		editor.text_changed.connect(func(): 
			status_label.text = "Typing..."
			autosave_timer.start()
		)
		
		# Focus Logic
		editor.focus_exited.connect(func(): save_if_needed("Saved"))

	func _connect_signals() -> void:
		btn_save.pressed.connect(func(): save_if_needed("Saved!", true))
		btn_search.pressed.connect(open_search.bind(false))
		btn_replace.pressed.connect(open_search.bind(true))
		
		btn_close_search.pressed.connect(close_search)
		btn_next.pressed.connect(find_next)
		btn_prev.pressed.connect(find_prev)
		btn_rep_one.pressed.connect(replace_one)
		btn_rep_all.pressed.connect(replace_all)
		
		# FIX: Use gui_input to catch Enter without losing focus
		input_find.gui_input.connect(func(event):
			if event is InputEventKey and event.pressed and event.keycode == KEY_ENTER:
				find_next()
				input_find.accept_event()
		)

	func load_file(path: String) -> void:
		editor.set_meta("file_path", path)
		wrapper.show()
		search_panel.hide()
		
		var f = FileAccess.open(path, FileAccess.READ)
		if f:
			var content = f.get_as_text()
			editor.text = content
			editor.set_meta("original_content", content)
			editor.clear_undo_history()
			status_label.text = "Ready"
			
	func save_if_needed(msg: String = "Saved", force: bool = false) -> void:
		if not wrapper.visible or not editor.has_meta("file_path"): return
		
		# DIRTY CHECK
		# We only skip if it's NOT a forced save AND content matches
		if not force:
			if editor.has_meta("original_content") and editor.text == editor.get_meta("original_content"):
				return
		
		parent_viewer.trigger_save_request(editor.get_meta("file_path"), editor.text)
		editor.set_meta("original_content", editor.text)
		
		# Visual Flash
		status_label.text = msg
		status_label.modulate = Color("41f095")
		var t = wrapper.create_tween()
		t.tween_property(status_label, "modulate", Color(1,1,1,0.7), 1.5)
		
		var orig_mod = Color(1,1,1,1)
		editor.modulate = Color(0.5, 1.0, 0.5)
		var t2 = wrapper.create_tween()
		t2.tween_property(editor, "modulate", orig_mod, 0.3)

	# --- SEARCH LOGIC ---
	func open_search(show_replace: bool) -> void:
		search_panel.show()
		replace_bar.visible = show_replace
		input_find.grab_focus()
		if editor.has_selection():
			input_find.text = editor.get_selected_text()
			input_find.select_all() # QoL: Select text so you can type immediately
			
	func close_search() -> void:
		search_panel.hide()
		editor.grab_focus()

	func find_next() -> void: _perform_search(false)
	func find_prev() -> void: _perform_search(true)

	func _perform_search(reverse: bool) -> void:
		var query = input_find.text
		if query.is_empty(): return
		
		var flags = 2 # Match Case off, Words off
		if reverse: flags += 1 # Add Backwards flag
		
		var res = editor.search(query, flags, editor.get_caret_line(), editor.get_caret_column())
		
		if res.x == -1: # Wrap around
			var start_line = 0 if not reverse else editor.get_line_count() - 1
			var start_col = 0 if not reverse else editor.get_line_width(start_line)
			res = editor.search(query, flags, start_line, start_col)
			status_label.text = "Wrapped"
		
		if res.x != -1:
			editor.select(res.y, res.x, res.y, res.x + query.length())
			editor.set_caret_line(res.y)
			editor.set_caret_column(res.x + query.length())
			editor.center_viewport_to_caret()
		else:
			status_label.text = "Not Found"

	func replace_one() -> void:
		var query = input_find.text
		if query.is_empty(): return
		# Only replace if currently selected matches query
		if editor.has_selection() and editor.get_selected_text() == query:
			editor.insert_text_at_caret(input_replace.text)
			find_next()
		else:
			find_next()

	func replace_all() -> void:
		var query = input_find.text
		if query.is_empty(): return
		var new_text = editor.text.replace(query, input_replace.text)
		if new_text != editor.text:
			editor.text = new_text
			save_if_needed("Replaced All")

# ---------------------------------------------------------

func _ready() -> void:
	hide()
	close_btn.pressed.connect(_close)
	btn_prev_row.pressed.connect(_nav_row.bind(-1))
	btn_next_row.pressed.connect(_nav_row.bind(1))
	
	# Prevent buttons from stealing keyboard focus.
	# This ensures Arrow Keys always go to our script, not UI navigation.
	close_btn.focus_mode = Control.FOCUS_NONE
	btn_prev_row.focus_mode = Control.FOCUS_NONE
	btn_next_row.focus_mode = Control.FOCUS_NONE
	
	col_select_left.focus_mode = Control.FOCUS_NONE
	col_select_right.focus_mode = Control.FOCUS_NONE
	
	# Also ensure images don't grab focus on click
	img_left.focus_mode = Control.FOCUS_NONE
	img_right.focus_mode = Control.FOCUS_NONE
	
	col_select_left.item_selected.connect(func(_idx): _refresh_panel(true))
	col_select_right.item_selected.connect(func(_idx): _refresh_panel(false))
	
	# Initialize Text Controllers
	_left_controller = TextController.new(text_wrapper_left, self)
	_right_controller = TextController.new(text_wrapper_right, self)
	
	# Zoom Logic
	img_left.gui_input.connect(_handle_image_input.bind(img_left))
	img_right.gui_input.connect(_handle_image_input.bind(img_right))
	
	# Cursor Logic
	var c_left = img_left.get_parent() # ContentContainer
	var c_right = img_right.get_parent()
	c_left.mouse_entered.connect(_update_cursor.bind(img_left))
	c_right.mouse_entered.connect(_update_cursor.bind(img_right))
	c_left.mouse_exited.connect(_reset_cursor)
	c_right.mouse_exited.connect(_reset_cursor)
	c_left.gui_input.connect(_handle_image_input.bind(img_left))
	c_right.gui_input.connect(_handle_image_input.bind(img_right))

func _gui_input(event: InputEvent) -> void:
	# CLICK OFF FEATURE
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# If the click reaches here (The Root), it means NO child node handled it.
		# Therefore, it was a click on the background/void.
		_close()

# FIX: Public function to satisfy signal warning
func trigger_save_request(path: String, content: String) -> void:
	request_save_text.emit(path, content)

func _input(event: InputEvent) -> void:
	if not visible: return
	
	# 1. HANDLE CANCEL / ESCAPE
	if event.is_action_pressed("ui_cancel"):
		var handled = false
		if _left_controller.search_panel.visible:
			_left_controller.close_search()
			handled = true
		if _right_controller.search_panel.visible:
			_right_controller.close_search()
			handled = true
		if not handled:
			_close()
		get_viewport().set_input_as_handled()
		return

	# 2. HANDLE KEY INPUTS
	if event is InputEventKey and event.pressed:
		
		# --- GLOBAL NAVIGATION (Arrows) ---
		# We check this FIRST so it works anywhere (Image or Text)
		if event.keycode == KEY_UP:
			_handle_nav_input(-1, event)
			return # Stop processing
		elif event.keycode == KEY_DOWN:
			_handle_nav_input(1, event)
			return # Stop processing

		# --- TEXT EDITOR SHORTCUTS (Ctrl+S, F, R) ---
		# Now we check if we are actually working with text
		var active_ctrl = _get_active_controller()
		if not active_ctrl: return
		
		if event.keycode == KEY_S and event.is_command_or_control_pressed():
			active_ctrl.save_if_needed("Saved", true)
			get_viewport().set_input_as_handled()
			
		elif event.keycode == KEY_F and event.is_command_or_control_pressed():
			active_ctrl.open_search(false)
			get_viewport().set_input_as_handled()
			
		elif event.keycode == KEY_R and event.is_command_or_control_pressed():
			active_ctrl.open_search(true)
			get_viewport().set_input_as_handled()

# Helper function for "Hybrid Navigation"
func _handle_nav_input(dir: int, event: InputEventKey) -> void:
	var focus_owner = get_viewport().gui_get_focus_owner()
	var is_typing = (focus_owner is CodeEdit or focus_owner is LineEdit)
	var is_forcing = event.is_command_or_control_pressed() # Check for Ctrl/Cmd
	
	# CASE 1: Forced Navigation (Ctrl + Arrow)
	if is_forcing:
		_nav_row(dir)
		get_viewport().set_input_as_handled()
		return

	# CASE 2: Context Aware (Plain Arrow)
	if is_typing:
		# User is typing. Do NOTHING. Let the CodeEdit move the caret.
		return
	else:
		# User is not typing (focus on Image, Button, or None). Navigate Rows.
		_nav_row(dir)
		get_viewport().set_input_as_handled()

func _get_active_controller() -> TextController:
	# Returns the controller that owns the focused element
	var focus = get_viewport().gui_get_focus_owner()
	if focus:
		if _left_controller.wrapper.is_ancestor_of(focus): return _left_controller
		if _right_controller.wrapper.is_ancestor_of(focus): return _right_controller
	
	# Fallback: Mouse position
	var m_pos = get_global_mouse_position()
	if _left_controller.wrapper.get_global_rect().has_point(m_pos) and _left_controller.wrapper.visible:
		return _left_controller
	if _right_controller.wrapper.get_global_rect().has_point(m_pos) and _right_controller.wrapper.visible:
		return _right_controller
	return null

func open(dataset: Dictionary, stems_list: Array, start_stem: String, cols: Array, start_col_name: String = "") -> void:
	_dataset = dataset
	_stems = stems_list
	_columns = cols
	
	_current_index = _stems.find(start_stem)
	if _current_index == -1: _current_index = 0
	
	col_select_left.clear()
	col_select_right.clear()
	for c in _columns:
		col_select_left.add_item(c.to_upper())
		col_select_right.add_item(c.to_upper())
	
	var start_col_idx = 0
	if start_col_name != "":
		start_col_idx = _columns.find(start_col_name)
		if start_col_idx == -1: start_col_idx = 0
	
	if not _columns.is_empty():
		col_select_left.selected = start_col_idx
		if _columns.size() > 1:
			if start_col_idx < _columns.size() - 1:
				col_select_right.selected = start_col_idx + 1
			else:
				col_select_right.selected = start_col_idx - 1
		else:
			col_select_right.selected = start_col_idx

	$MarginContainer/VBoxContainer/SplitView.split_offset = 0
	_update_view()
	show()
	mouse_filter = Control.MOUSE_FILTER_STOP

func _nav_row(direction: int) -> void:
	_left_controller.save_if_needed()
	_right_controller.save_if_needed()
	var new_index = _current_index + direction
	if new_index >= 0 and new_index < _stems.size():
		_current_index = new_index
		_update_view()

func _update_view() -> void:
	btn_prev_row.disabled = (_current_index <= 0)
	btn_next_row.disabled = (_current_index >= _stems.size() - 1)
	position_label.text = "%d / %d" % [_current_index + 1, _stems.size()]
	
	var current_stem = _stems[_current_index]
	$MarginContainer/VBoxContainer/TopBar/TitleLabel.text = "Comparing: " + current_stem
	
	_refresh_panel(true)
	_refresh_panel(false)

func _refresh_panel(is_left: bool) -> void:
	var stem = _stems[_current_index]
	var col_idx = col_select_left.selected if is_left else col_select_right.selected
	if col_idx == -1: return
	
	var col_name = _columns[col_idx]
	var img_node = img_left if is_left else img_right
	var txt_ctrl = _left_controller if is_left else _right_controller
	
	# Reset State
	img_node.texture = null
	img_node.hide()
	txt_ctrl.wrapper.hide()
	_reset_zoom(img_node)
	
	var files = _dataset.get(stem, {}).get(col_name, [])
	if files.is_empty(): return 
		
	var file_path = files[0]
	var ext = file_path.get_extension().to_lower()
	
	if ext in ["png", "jpg", "jpeg", "webp"]:
		_load_image(img_node, file_path)
	elif ext in ["txt", "md", "json"]:
		txt_ctrl.load_file(file_path)

func _load_image(node: TextureRect, path: String) -> void:
	node.show()
	var img = Image.load_from_file(path)
	if img:
		node.texture = ImageTexture.create_from_image(img)
	_reset_zoom(node)

func _close() -> void:
	_left_controller.save_if_needed()
	_right_controller.save_if_needed()
	closed.emit()
	hide()

# --- ZOOM & PAN LOGIC (MATCHING IMAGEVIEWER) ---

func _handle_image_input(event: InputEvent, node: TextureRect) -> void:
	if not node.texture: return
	if not node.visible: return

	var is_left = (node == img_left)
	var is_zoomed = (node.stretch_mode == TextureRect.STRETCH_SCALE)
	
	if event is InputEventMouseMotion:
		_update_cursor(node)
		
		# Handle Panning
		var is_active_drag = _dragging_left if is_left else _dragging_right
		
		if is_active_drag and is_zoomed:
			var diff = event.global_position - _drag_start_mouse_pos
			if diff.length() > DRAG_THRESHOLD:
				_has_dragged_significantly = true
			
			node.position = _clamp_position(node, _drag_start_img_pos + diff)
			# Consuming motion events isn't strictly necessary, but good practice when dragging
			get_viewport().set_input_as_handled()

	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# --- MOUSE DOWN ---
			if is_zoomed:
				# Already zoomed -> Start Drag logic
				if is_left: _dragging_left = true
				else: _dragging_right = true
				
				_drag_start_mouse_pos = event.global_position
				_drag_start_img_pos = node.position
				_has_dragged_significantly = false
				
				get_viewport().set_input_as_handled() # STOP BUBBLING
			else:
				# Not zoomed -> Zoom In
				var container = node.get_parent()
				var mouse_pos = container.get_local_mouse_position()
				
				# Only zoom if clicking actual image content
				if _get_draw_rect(node).has_point(mouse_pos):
					_zoom_in(node, mouse_pos)
					get_viewport().set_input_as_handled() # STOP BUBBLING
		
		else:
			# --- MOUSE UP ---
			var was_dragging = _dragging_left if is_left else _dragging_right
			
			# Reset drag flags
			if is_left: _dragging_left = false
			else: _dragging_right = false
			
			if was_dragging and is_zoomed and not _has_dragged_significantly:
				_zoom_out(node)
				get_viewport().set_input_as_handled() # STOP BUBBLING

func _zoom_in(node: TextureRect, pivot: Vector2) -> void:
	# Calculate relative position before resizing
	var visual_rect = _get_draw_rect(node)
	var relative_x = (pivot.x - visual_rect.position.x) / visual_rect.size.x
	var relative_y = (pivot.y - visual_rect.position.y) / visual_rect.size.y
	
	node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	node.stretch_mode = TextureRect.STRETCH_SCALE
	node.size = visual_rect.size * ZOOM_LEVEL
	
	# Position based on mouse pivot
	var target_x = pivot.x - (node.size.x * relative_x)
	var target_y = pivot.y - (node.size.y * relative_y)
	
	node.position = _clamp_position(node, Vector2(target_x, target_y))
	_update_cursor(node)

func _zoom_out(node: TextureRect) -> void:
	_reset_zoom(node)
	_update_cursor(node)

func _reset_zoom(node: TextureRect) -> void:
	if is_instance_valid(node) and is_instance_valid(node.get_parent()):
		node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		node.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		node.size = node.get_parent().size
		node.position = Vector2.ZERO

# --- HELPERS ---

func _clamp_position(node: TextureRect, target_pos: Vector2) -> Vector2:
	var container_size = node.get_parent().size
	var min_x = container_size.x - node.size.x
	var min_y = container_size.y - node.size.y
	
	if node.size.x < container_size.x:
		target_pos.x = (container_size.x - node.size.x) / 2.0
	else:
		target_pos.x = clampf(target_pos.x, min_x, 0.0)
		
	if node.size.y < container_size.y:
		target_pos.y = (container_size.y - node.size.y) / 2.0
	else:
		target_pos.y = clampf(target_pos.y, min_y, 0.0)
	return target_pos

func _get_draw_rect(node: TextureRect) -> Rect2:
	if not node.texture: return Rect2()
	var container_size = node.get_parent().size
	var tex_size = node.texture.get_size()
	var tex_aspect = tex_size.x / tex_size.y
	var cont_aspect = container_size.x / container_size.y
	
	var final_size = Vector2()
	if cont_aspect > tex_aspect:
		final_size.y = container_size.y
		final_size.x = final_size.y * tex_aspect
	else:
		final_size.x = container_size.x
		final_size.y = final_size.x / tex_aspect
		
	var pos = (container_size - final_size) / 2.0
	return Rect2(pos, final_size)

func _update_cursor(node: TextureRect) -> void:
	if not node.visible: 
		Input.set_custom_mouse_cursor(null)
		return

	var is_zoomed = (node.stretch_mode == TextureRect.STRETCH_SCALE)
	var container = node.get_parent()
	var mouse_pos = container.get_local_mouse_position()
	
	var is_over_image = false
	if is_zoomed:
		# If zoomed, the TextureRect covers the image area
		is_over_image = node.get_rect().has_point(mouse_pos)
	else:
		# If not zoomed, check against the visual draw rect
		is_over_image = _get_draw_rect(node).has_point(mouse_pos)
	
	if is_over_image:
		Input.set_custom_mouse_cursor(CURSOR_MAGNIFIER, Input.CURSOR_ARROW, CURSOR_HOTSPOT)
	else:
		Input.set_custom_mouse_cursor(null)

func _reset_cursor() -> void:
	Input.set_custom_mouse_cursor(null)
