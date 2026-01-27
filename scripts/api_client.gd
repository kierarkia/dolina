class_name ApiClient
extends Node

# --- SIGNALS ---
signal request_completed(response: Dictionary)
signal request_failed(error_msg: String, code: int)
signal log_message(text: String)

# --- NODES ---
# We create this dynamically to ensure it's fresh
var _http: HTTPRequest

func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

# --- PUBLIC API ---

func send_request(api_url: String, api_key: String, model: String, messages: Array, temperature: float = 0.7, max_tokens: int = 4096) -> void:
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		request_failed.emit("Client is busy", 0)
		return

	# --- 1. URL SANITIZATION ---
	var final_url = api_url.strip_edges()
	
	# Fix: Gemini OpenAI Path
	if "googleapis.com" in final_url and "/openai/" in final_url and not final_url.ends_with("chat/completions"):
		if final_url.ends_with("/"):
			final_url += "chat/completions"
		else:
			final_url += "/chat/completions"
		log_message.emit("Auto-corrected URL path: " + final_url)

	# --- 2. TLS SETTINGS ---
	var tls_options = null
	if "localhost" in final_url or "127.0.0.1" in final_url:
		tls_options = TLSOptions.client_unsafe()
	else:
		tls_options = TLSOptions.client() # Secure for Cloud
	_http.set_tls_options(tls_options)

	# --- 3. PAYLOAD CONSTRUCTION ---
	var headers = [
		"Content-Type: application/json",
		"Authorization: Bearer %s" % api_key
	]
	
	var body_data = {
		"model": model,
		"messages": messages,
		"max_tokens": max_tokens,
		"temperature": temperature 
	}
	
	var json_body = JSON.stringify(body_data)
	
	log_message.emit("Sending request to %s..." % model)
	var error = _http.request(final_url, headers, HTTPClient.METHOD_POST, json_body)
	if error != OK:
		request_failed.emit("Failed to initiate HTTP request", error)

# --- HELPERS ---

# Static helper to prepare content blocks
static func create_text_content(text: String) -> Dictionary:
	return { "type": "text", "text": text }

# Handles reading disk -> Base64
static func create_image_content(file_path: String) -> Dictionary:
	if not FileAccess.file_exists(file_path):
		return {}
		
	var f = FileAccess.open(file_path, FileAccess.READ)
	var buffer = f.get_buffer(f.get_length())
	var b64 = Marshalls.raw_to_base64(buffer)
	var mime = "image/jpeg"
	
	if file_path.ends_with(".png"): mime = "image/png"
	elif file_path.ends_with(".webp"): mime = "image/webp"
	
	return {
		"type": "image_url",
		"image_url": {
			"url": "data:%s;base64,%s" % [mime, b64]
		}
	}

# --- INTERNAL HANDLERS ---

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		request_failed.emit("Connection Error", result)
		return
		
	var body_str = body.get_string_from_utf8()
	var json = JSON.new()
	var parse_err = json.parse(body_str)
	
	if parse_err != OK:
		# DEBUG: Print the raw body if JSON fails. 
		print("RAW RESPONSE BODY: ", body_str)
		request_failed.emit("JSON Parse Error (Check Console)", 0)
		return
		
	var data = json.data
	
	if response_code >= 400:
		var err_msg = "API Error (%d)" % response_code
		if data is Dictionary:
			if data.has("error"):
				# Handle OpenAI/Google standard error format
				var e = data["error"]
				if e is Dictionary and e.has("message"):
					err_msg += ": " + e["message"]
				elif e is String:
					err_msg += ": " + e
		request_failed.emit(err_msg, response_code)
		return

	request_completed.emit(data)
