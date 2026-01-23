class_name TextEditor
extends ColorRect

signal request_save(path: String, content: String)
# NEW: Signal now carries data for smart updating
signal closed(path: String, content: String)

@onready var title_label: Label = %TitleLabel
@onready var editor: CodeEdit = %Editor
@onready var save_btn: Button = %SaveBtn
@onready var close_btn: Button = %CloseBtn
@onready var status_label: Label = %StatusLabel
@onready var sheet: PanelContainer = $Sheet

# Search UI
@onready var search_panel: PanelContainer = $Sheet/VBoxContainer/SearchPanel
@onready var find_bar: HBoxContainer = $Sheet/VBoxContainer/SearchPanel/VBoxContainer/FindBar
@onready var replace_bar: HBoxContainer = $Sheet/VBoxContainer/SearchPanel/VBoxContainer/ReplaceBar
@onready var find_input: LineEdit = %FindInput
@onready var replace_input: LineEdit = %ReplaceInput
@onready var match_label: Label = %MatchLabel
@onready var find_prev_btn: Button = %FindPrevBtn
@onready var find_next_btn: Button = %FindNextBtn
@onready var close_search_btn: Button = %CloseSearchBtn
@onready var replace_one_btn: Button = %ReplaceOneBtn
@onready var replace_all_btn: Button = %ReplaceAllBtn

# NEW: Toolbar Buttons
@onready var search_btn: Button = %SearchBtn
@onready var replace_btn: Button = %ReplaceBtn

var _current_path: String = ""
var _autosave_enabled: bool = false
var _autosave_timer: Timer

func _ready() -> void:
	hide()
	search_panel.hide()
	
	close_btn.pressed.connect(_close)
	save_btn.pressed.connect(_manual_save)
	
	# NEW: Connect Toolbar Buttons
	search_btn.pressed.connect(func(): _open_search(false))
	replace_btn.pressed.connect(func(): _open_search(true))
	
	_autosave_timer = Timer.new()
	_autosave_timer.wait_time = 2.0
	_autosave_timer.one_shot = true
	_autosave_timer.add_to_group("autosave_timers")
	add_child(_autosave_timer)
	
	_autosave_timer.timeout.connect(_on_autosave_trigger)
	
	editor.text_changed.connect(func():
		if _autosave_enabled:
			status_label.text = "Typing..."
			_autosave_timer.start()
	)
	
	gui_input.connect(_on_background_input)
	editor.gui_input.connect(_on_editor_input)

	# Search Connections
	close_search_btn.pressed.connect(_close_search)
	find_next_btn.pressed.connect(_find_next)
	find_prev_btn.pressed.connect(_find_prev)
	find_input.gui_input.connect(func(event):
		if event is InputEventKey and event.pressed and event.keycode == KEY_ENTER:
			_find_next()
			find_input.accept_event() # Stops the event so LineEdit doesn't "submit" and lose focus
	)
	replace_one_btn.pressed.connect(_replace_one)
	replace_all_btn.pressed.connect(_replace_all)

# FIX: Use _input instead of _unhandled_input to catch ESC even when LineEdit has focus
func _input(event: InputEvent) -> void:
	if not visible: return
	
	if event.is_action_pressed("ui_cancel"):
		# Check if we should just close the search panel
		if search_panel.visible:
			_close_search()
			get_viewport().set_input_as_handled() 
		else:
			# If search is already closed, close the editor
			_close()
			get_viewport().set_input_as_handled()

func open(path: String, content: String, autosave_on: bool) -> void:
	_current_path = path
	_autosave_enabled = autosave_on
	
	var folder = path.get_base_dir().get_file()
	var file = path.get_file()
	title_label.text = "%s / %s" % [folder, file]
	
	editor.text = content
	status_label.text = "Ready"
	
	_autosave_timer.stop()
	_close_search()
	
	show()
	editor.grab_focus()

func _manual_save() -> void:
	_perform_save("Saved!")
	_autosave_timer.stop()

func _on_autosave_trigger() -> void:
	if visible:
		_perform_save("Autosaved")

func _perform_save(success_msg: String) -> void:
	request_save.emit(_current_path, editor.text)
	
	# 1. Flash the Status Label (Existing logic, slower fade)
	status_label.text = success_msg
	status_label.modulate = Color("41f095")
	var label_tween = create_tween()
	label_tween.tween_property(status_label, "modulate", Color(1,1,1,0.7), 1.5)
	
	# 2. Flash the Editor (Matches row.gd logic)
	# This flashes the entire text area and text green instantly
	var original_modulate = Color(1, 1, 1, 1)
	editor.modulate = Color(0.5, 1.0, 0.5)
	
	var editor_tween = create_tween()
	# Snap back to white over 0.3 seconds
	editor_tween.tween_property(editor, "modulate", original_modulate, 0.3)

func _close() -> void:
	if not _autosave_timer.is_stopped():
		_perform_save("Saved on close")
	hide()
	# UPDATED: Emit path and content so Main can smart-update the grid
	closed.emit(_current_path, editor.text)

func _on_background_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not sheet.get_global_rect().has_point(get_global_mouse_position()):
			_close()

func _on_editor_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_S:
		if event.is_command_or_control_pressed():
			get_viewport().set_input_as_handled()
			_manual_save()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_F:
		if event.is_command_or_control_pressed():
			get_viewport().set_input_as_handled()
			_open_search(false)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_R:
		if event.is_command_or_control_pressed():
			get_viewport().set_input_as_handled()
			_open_search(true)

# ... (Search logic remains the same as previous) ...
func _open_search(show_replace: bool) -> void:
	search_panel.show()
	replace_bar.visible = show_replace
	if editor.has_selection():
		find_input.text = editor.get_selected_text()
	find_input.grab_focus()
	find_input.select_all()

func _close_search() -> void:
	search_panel.hide()
	editor.grab_focus()
	match_label.text = ""

func _find_next() -> void:
	_perform_search(false)

func _find_prev() -> void:
	_perform_search(true)

func _perform_search(reverse: bool) -> void:
	var query = find_input.text
	if query.is_empty(): 
		match_label.text = ""
		return
	
	var flags: int = 0
	if reverse: 
		flags += CodeEdit.SEARCH_BACKWARDS
	
	var line = editor.get_caret_line()
	var col = editor.get_caret_column()
	
	# Handle backward search logic
	if reverse and editor.has_selection():
		# Start from the beginning of the selection
		line = editor.get_selection_from_line()
		col = editor.get_selection_from_column()
		
		# Step back 1 character to avoid finding the current match again
		col -= 1
		
		# Handle moving to the previous line if we stepped back past the start
		if col < 0:
			line -= 1
			if line >= 0:
				col = editor.get_line(line).length()
			else:
				# We are at the very start of the file (0,0)
				# Ensure we force a "Not Found" state so the wrap logic takes over
				col = -1 

	# If col is -1 (start of file reached), search returns (-1, -1) automatically
	var result = editor.search(query, flags, line, col)
	
	if result.x != -1:
		editor.select(result.y, result.x, result.y, result.x + query.length())
		editor.set_caret_line(result.y)
		editor.set_caret_column(result.x + query.length())
		editor.center_viewport_to_caret()
		match_label.text = "Found"
		match_label.modulate = Color.WHITE
	else:
		# WRAP LOGIC
		var start_line = 0 if not reverse else editor.get_line_count() - 1
		var start_col = 0
		if reverse:
			start_col = editor.get_line(start_line).length()
		
		var retry = editor.search(query, flags, start_line, start_col)
		if retry.x != -1:
			editor.select(retry.y, retry.x, retry.y, retry.x + query.length())
			editor.set_caret_line(retry.y)
			editor.set_caret_column(retry.x + query.length())
			editor.center_viewport_to_caret()
			match_label.text = "Wrapped"
			match_label.modulate = Color.YELLOW
		else:
			match_label.text = "No Match"
			match_label.modulate = Color.RED

func _replace_one() -> void:
	var query = find_input.text
	var replacement = replace_input.text
	if query.is_empty(): return
	if editor.has_selection() and editor.get_selected_text() == query:
		editor.insert_text_at_caret(replacement)
		_find_next()
	else:
		_find_next()

func _replace_all() -> void:
	var query = find_input.text
	var replacement = replace_input.text
	if query.is_empty(): return
	
	var text_content = editor.text
	var new_text = text_content.replace(query, replacement)
	
	if text_content != new_text:
		editor.text = new_text
		status_label.text = "Replaced All"
		
		if _autosave_enabled:
			_autosave_timer.start()
			status_label.text = "Replaced (Autosave Pending)"
		else:
			status_label.text = "Replaced (Unsaved)"
			
	else:
		match_label.text = "Nothing to replace"
