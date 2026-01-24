class_name EmptyState
extends CenterContainer

signal examples_imported

# Use the RAW version of the link for direct download
const DOWNLOAD_URL = "https://github.com/kierarkia/dolina/raw/main/examples/data/datasets/dolina_examples.zip"

@onready var download_btn: Button = %DownloadBtn
@onready var progress_bar: ProgressBar = %ProgressBar
@onready var http_request: HTTPRequest = $HTTPRequest
@onready var label: Label = $VBoxContainer/Label

var _target_folder: String = ""

func _ready() -> void:
	download_btn.pressed.connect(_on_download_pressed)
	http_request.request_completed.connect(_on_request_completed)
	
	# Enable threading for responsiveness
	http_request.use_threads = true 
	
	# Disable processing initially (we only need it during download)
	set_process(false)

func _process(_delta: float) -> void:
	# Poll the request for status
	var body_size = http_request.get_body_size()
	var downloaded_bytes = http_request.get_downloaded_bytes()
	
	if body_size > 0:
		var percent = (float(downloaded_bytes) / float(body_size)) * 100
		progress_bar.value = percent

func setup(target_folder_path: String) -> void:
	_target_folder = target_folder_path

func _on_download_pressed() -> void:
	if _target_folder == "": return
	
	download_btn.disabled = true
	download_btn.text = "Downloading..."
	
	progress_bar.value = 0
	progress_bar.show()
	
	# Start polling for progress
	set_process(true)
	
	var temp_path = OS.get_cache_dir() + "/dolina_temp.zip"
	http_request.download_file = temp_path
	http_request.request(DOWNLOAD_URL)

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	# Stop polling
	set_process(false)
	
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		label.text = "Download Failed! (Code: %d)" % response_code
		download_btn.text = "Retry"
		download_btn.disabled = false
		progress_bar.hide()
		return

	download_btn.text = "Unzipping..."
	progress_bar.value = 100 
	
	await get_tree().process_frame
	
	var zip_path = http_request.download_file
	var success = _unzip_and_install(zip_path)
	
	# Cleanup
	DirAccess.remove_absolute(zip_path)
	
	if success:
		examples_imported.emit()
		download_btn.disabled = false
		download_btn.text = "Download Examples"
		progress_bar.hide()
	else:
		label.text = "Error Unzipping Files"
		download_btn.disabled = false
		progress_bar.hide()

func _unzip_and_install(zip_path: String) -> bool:
	var reader = ZIPReader.new()
	var err = reader.open(zip_path)
	if err != OK: return false
	
	var files = reader.get_files()
	for file_path in files:
		if file_path.ends_with("/"): continue
			
		var content = reader.read_file(file_path)
		var final_path = _target_folder + "/" + file_path
		
		var base_dir = final_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(base_dir):
			DirAccess.make_dir_recursive_absolute(base_dir)
			
		var f = FileAccess.open(final_path, FileAccess.WRITE)
		if f:
			f.store_buffer(content)
			f.close()
			
	reader.close()
	return true
