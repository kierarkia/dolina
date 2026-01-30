class_name AuditDashboard
extends Control

# --- SIGNALS ---
signal close_requested
# Emitted when user wants to fix a specific file
signal review_requested(stem: String, col_name: String, context_list: Array)

# --- NODES ---
@onready var target_col_select: OptionButton = %TargetColSelect
@onready var scan_btn: Button = %ScanBtn
@onready var close_btn: Button = %CloseBtn
@onready var result_list: VBoxContainer = %ResultList

# Inputs
@onready var refusal_edit: TextEdit = %RefusalEdit
@onready var refusal_limit: SpinBox = %RefusalLimit
@onready var preface_edit: TextEdit = %PrefaceEdit
@onready var preface_limit: SpinBox = %PrefaceLimit
@onready var postface_edit: TextEdit = %PostfaceEdit
@onready var postface_limit: SpinBox = %PostfaceLimit
@onready var clear_btn: Button = %ClearBtn

# --- DEFAULTS ---
const DEFAULT_REFUSALS = "i cannot\ni can't\ni am unable\napologize\nsorry\nas an ai\nlanguage model\npolicy\ncontent warning\ncannot fulfill\ncannot rewrite\ncannot comply\nagainst my\nviolation of"
const DEFAULT_PREFACE = "here is the\nhere's the\nsure\ncertainly\nhappy to help\nbelow is the\nfollowing is the\ni can help with that\nplease find the"
const DEFAULT_POSTFACE = "hope this helps\nhope that helps\nlet me know\nfeel free to\nif you have any\nif you need\nwould you like me\ncan i help\nis there anything else\nfurther assistance\nhappy to help\nquestions"

var _project_manager: ProjectManager

func setup(pm: ProjectManager) -> void:
	_project_manager = pm
	_refresh_columns()

func _ready() -> void:
	close_btn.pressed.connect(func(): close_requested.emit())
	scan_btn.pressed.connect(_run_audit)
	clear_btn.pressed.connect(_clear_results)
	
	# Set defaults
	refusal_edit.text = DEFAULT_REFUSALS
	preface_edit.text = DEFAULT_PREFACE
	postface_edit.text = DEFAULT_POSTFACE
	
	# Set default limits (e.g., 100 chars)
	refusal_limit.value = 100
	preface_limit.value = 100
	postface_limit.value = 100

func _refresh_columns() -> void:
	target_col_select.clear()
	if _project_manager:
		for col in _project_manager.current_columns:
			target_col_select.add_item(col.to_upper())

func _run_audit() -> void:
	if target_col_select.selected == -1: return
	
	var col_name = _project_manager.current_columns[target_col_select.selected]
	scan_btn.disabled = true
	scan_btn.text = "Scanning..."
	
	# Clear previous results
	for child in result_list.get_children():
		child.queue_free()
	
	# Prepare Configuration Data
	var config = {
		"refusals": _get_phrases(refusal_edit),
		"preface": _get_phrases(preface_edit),
		"postface": _get_phrases(postface_edit),
		"refusal_lim": int(refusal_limit.value),
		"preface_lim": int(preface_limit.value),
		"postface_lim": int(postface_limit.value),
		"col": col_name,
		"dataset": _project_manager.current_dataset # Passing reference is safe for read-only
	}
	
	# Run on Thread
	WorkerThreadPool.add_task(_audit_task.bind(config))

# --- THREADED LOGIC ---

func _audit_task(config: Dictionary) -> void:
	var issues = []
	var dataset = config["dataset"]
	var col = config["col"]
	
	var stems = dataset.keys()
	
	for stem in stems:
		var files = dataset[stem].get(col, [])
		if files.is_empty(): continue
		
		# Assume first file is the text file
		var path = files[0]
		if not path.get_extension().to_lower() in ["txt", "md", "json"]: continue
		
		var f = FileAccess.open(path, FileAccess.READ)
		if not f: continue
		
		var content = f.get_as_text()
		var lower_content = content.to_lower()
		var length = lower_content.length()
		
		var detected_issues = []
		
		# 1. Check Refusals (Start)
		var limit_r = min(length, config["refusal_lim"])
		var start_text_r = lower_content.substr(0, limit_r)
		for phrase in config["refusals"]:
			if start_text_r.contains(phrase):
				detected_issues.append("Refusal: '%s'" % phrase)
				break # Only need one hit per type
		
		# 2. Check Preface (Start)
		var limit_p = min(length, config["preface_lim"])
		var start_text_p = lower_content.substr(0, limit_p)
		for phrase in config["preface"]:
			if start_text_p.contains(phrase):
				detected_issues.append("Preface: '%s'" % phrase)
				break
				
		# 3. Check Postface (End)
		var limit_end = min(length, config["postface_lim"])
		var end_text = lower_content.right(limit_end)
		for phrase in config["postface"]:
			if end_text.contains(phrase):
				detected_issues.append("Postface: '%s'" % phrase)
				break
		
		if not detected_issues.is_empty():
			issues.append({
				"stem": stem,
				"issues": detected_issues
			})
			
	# Return to Main Thread
	call_deferred("_on_audit_complete", issues)

func _on_audit_complete(issues: Array) -> void:
	scan_btn.disabled = false
	scan_btn.text = "Run Audit"
	
	if issues.is_empty():
		var lbl = Label.new()
		lbl.text = "No issues found! Great job."
		result_list.add_child(lbl)
		return

	# NEW: Create the "Review Queue" list
	var all_bad_stems = []
	for item in issues:
		all_bad_stems.append(item.stem)

	# Generate buttons
	for item in issues:
		var btn = Button.new()
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.text = "%s (%s)" % [item.stem, ", ".join(item.issues)]
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
		
		var col_name = _project_manager.current_columns[target_col_select.selected]
		
		# UPDATE: Pass the 'all_bad_stems' list with the signal
		btn.pressed.connect(func():
			review_requested.emit(item.stem, col_name, all_bad_stems)
		)
		result_list.add_child(btn)

# --- HELPER ---

func _get_phrases(edit: TextEdit) -> Array[String]:
	var raw = edit.text.split("\n", false)
	var clean: Array[String] = []
	for line in raw:
		var s = line.strip_edges().to_lower()
		if s != "": clean.append(s)
	return clean

func _clear_results() -> void:
	for child in result_list.get_children():
		child.queue_free()
