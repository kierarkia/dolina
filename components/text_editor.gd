class_name TextEditor
extends ColorRect

signal request_save(path: String, content: String)
signal closed 

@onready var title_label: Label = %TitleLabel
@onready var editor: CodeEdit = %Editor
@onready var save_btn: Button = %SaveBtn
@onready var close_btn: Button = %CloseBtn
@onready var status_label: Label = %StatusLabel
@onready var sheet: PanelContainer = $Sheet

# --- SEARCH UI NODES ---
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

var _current_path: String = ""
var _autosave_enabled: bool = false
var _autosave_timer: Timer

func _ready() -> void:
	hide()
	search_panel.hide()
	
	close_btn.pressed.connect(_close)
	save_btn.pressed.connect(_manual_save)
	
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
	set_process_unhandled_input(true)

	# --- SEARCH CONNECTIONS ---
	close_search_btn.pressed.connect(_close_search)
	find_next_btn.pressed.connect(_find_next)
	find_prev_btn.pressed.connect(_find_prev)
	find_input.text_submitted.connect(func(_text): _find_next()) # Enter key in box
	
	replace_one_btn.pressed.connect(_replace_one)
	replace_all_btn.pressed.connect(_replace_all)

func _unhandled_input(event: InputEvent) -> void:
	if not visible: return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		# Logic: If search is open, close search first. Otherwise close editor.
		if search_panel.visible:
			_close_search()
		else:
			_close()

func open(path: String, content: String, autosave_on: bool) -> void:
	_current_path = path
	_autosave_enabled = autosave_on
	
	var folder = path.get_base_dir().get_file()
	var file = path.get_file()
	title_label.text = "%s / %s" % [folder, file]
	
	editor.text = content
	status_label.text = "Ready"
	
	_autosave_timer.stop()
	_close_search() # Ensure search is closed on fresh open
	
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
	status_label.text = success_msg
	status_label.modulate = Color("41f095")
	var tween = create_tween()
	tween.tween_property(status_label, "modulate", Color(1,1,1,0.7), 1.5)

func _close() -> void:
	if not _autosave_timer.is_stopped():
		_perform_save("Saved on close")
	hide()
	closed.emit()

func _on_background_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not sheet.get_global_rect().has_point(get_global_mouse_position()):
			_close()

func _on_editor_input(event: InputEvent) -> void:
	# Ctrl+S
	if event is InputEventKey and event.pressed and event.keycode == KEY_S:
		if event.is_command_or_control_pressed():
			get_viewport().set_input_as_handled()
			_manual_save()
	
	# Ctrl+F (Find)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_F:
		if event.is_command_or_control_pressed():
			get_viewport().set_input_as_handled()
			_open_search(false) # False = Search Only
			
	# Ctrl+R (Replace)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_R:
		if event.is_command_or_control_pressed():
			get_viewport().set_input_as_handled()
			_open_search(true) # True = Show Replace

# --- SEARCH & REPLACE LOGIC ---

func _open_search(show_replace: bool) -> void:
	search_panel.show()
	replace_bar.visible = show_replace
	
	# If text is selected in editor, use it as search query
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
	
	# Search flags: 1 = Match Case? No, let's keep simple. 
	# 0 = Standard (Case Sensitive by default in Godot backend usually, but let's just run it)
	# To make it case-insensitive we would need TextEdit.SEARCH_FLAG_CASE_INSENSITIVE
	# Note: In Godot 4.x, search flags are Enums. 2 = Case Insensitive.
	var flags = 2 
	if reverse: flags += 1 # 1 = Backwards
	
	# Search from current caret position
	var line = editor.get_caret_line()
	var col = editor.get_caret_column()
	
	var result = editor.search(query, flags, line, col)
	
	if result.x != -1:
		# Found!
		# Select the result (this highlights it)
		editor.select(result.y, result.x, result.y, result.x + query.length())
		editor.set_caret_line(result.y)
		editor.set_caret_column(result.x + query.length())
		editor.center_viewport_to_caret()
		match_label.text = "Found"
		match_label.modulate = Color.WHITE
	else:
		# Not found from cursor... wrap around?
		# Let's try searching from the beginning (or end)
		var start_line = 0 if not reverse else editor.get_line_count() - 1
		var start_col = 0 if not reverse else editor.get_line_width(start_line)
		
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
	
	# If we currently have the query selected, replace it immediately
	if editor.has_selection() and editor.get_selected_text() == query:
		editor.insert_text_at_caret(replacement)
		# After replace, find next
		_find_next()
	else:
		# If we haven't selected it yet, find it first
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
		_manual_save() # Good practice to save after a bulk op
	else:
		match_label.text = "Nothing to replace"
