class_name ThumbnailLoader
extends Node

# --- CONFIG ---
static var _cache_limit_bytes: int = 128 * 1024 * 1024 
static var _current_cache_size: int = 0

# --- DATA ---
static var _cache: Dictionary = {}

# --- PUBLIC API ---

static func set_cache_limit_mb(mb: int) -> void:
	_cache_limit_bytes = mb * 1024 * 1024
	_enforce_cache_limit()

static func request_thumbnail(path: String, target_height: int, on_complete: Callable) -> void:
	# 1. IMMEDIATE RETURN: Don't touch the disk here. Just schedule the work.
	WorkerThreadPool.add_task(func(): 
		_process_request_threaded(path, target_height, on_complete)
	)

# --- INTERNAL LOGIC ---

# This entire function now runs on a background thread
static func _process_request_threaded(path: String, target_height: int, on_complete: Callable) -> void:
	if not FileAccess.file_exists(path):
		on_complete.call_deferred(null)
		return

	# This is the slow operation (Disk I/O) - now safe in a thread!
	var file_timestamp = FileAccess.get_modified_time(path)
	
	# 2. Check Cache (Thread-safe read is generally okay for Dictionaries in Godot 4)
	if _cache.has(path):
		var entry = _cache[path]
		
		# A. Check Staleness
		if entry["timestamp"] == file_timestamp:
			# Cache Hit! 
			# We must update "last_accessed" on the main thread to avoid race conditions
			_update_access_time.call_deferred(path)
			on_complete.call_deferred(entry["texture"])
			return
		else:
			# Stale! We will overwrite it below.
			pass
	
	# 3. Cache Miss (or Stale) - Load Image
	_load_image_from_disk(path, target_height, file_timestamp, on_complete)

static func _load_image_from_disk(path: String, target_height: int, timestamp: int, on_complete: Callable) -> void:
	var img = Image.load_from_file(path)
	var texture: ImageTexture = null
	var est_size = 0
	
	if img:
		var orig_size = img.get_size()
		if orig_size.y > target_height:
			var aspect = float(orig_size.x) / float(orig_size.y)
			var target_w = int(target_height * aspect)
			img.resize(target_w, target_height, Image.INTERPOLATE_BILINEAR)
		
		est_size = img.get_width() * img.get_height() * 4
		texture = ImageTexture.create_from_image(img)
	
	# Send back to main thread
	_finalize_load.call_deferred(path, texture, timestamp, est_size, on_complete)

static func _finalize_load(path: String, texture: ImageTexture, timestamp: int, size: int, on_complete: Callable) -> void:
	if texture:
		# Add/Overwrite cache
		if _cache.has(path):
			_current_cache_size -= _cache[path]["size"]
			
		_cache[path] = {
			"texture": texture,
			"timestamp": timestamp,
			"last_accessed": Time.get_ticks_msec(),
			"size": size
		}
		_current_cache_size += size
		_enforce_cache_limit()
		
	on_complete.call(texture)

static func _update_access_time(path: String) -> void:
	if _cache.has(path):
		_cache[path]["last_accessed"] = Time.get_ticks_msec()

static func _enforce_cache_limit() -> void:
	if _current_cache_size <= _cache_limit_bytes:
		return
		
	var keys = _cache.keys()
	keys.sort_custom(func(a, b): 
		return _cache[a]["last_accessed"] < _cache[b]["last_accessed"]
	)
	
	for key in keys:
		if _current_cache_size <= _cache_limit_bytes:
			break
		_remove_from_cache(key)

static func _remove_from_cache(path: String) -> void:
	if _cache.has(path):
		_current_cache_size -= _cache[path]["size"]
		_cache.erase(path)
