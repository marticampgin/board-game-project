extends RefCounted
## Disk operations stay outside the deterministic model. One rotating backup is
## retained, and a failed write never replaces the previous usable snapshot.
const State = preload("res://scripts/domain/state/game_state.gd")

static func write(path: String, snapshot: Dictionary, metadata: Dictionary = {}) -> Dictionary:
	if not path.begins_with("user://") or path.contains(".."):
		return {"ok": false, "error": "INVALID_SAVE_PATH"}
	var errors: Array = State.validation_errors(snapshot)
	if not errors.is_empty():
		return {"ok": false, "error": "INVALID_SNAPSHOT", "details": errors}
	if not State.is_serializable(metadata):
		return {"ok": false, "error": "INVALID_METADATA"}
	var absolute: String = ProjectSettings.globalize_path(path)
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if directory_error != OK:
		return {"ok": false, "error": error_string(directory_error)}
	var temporary: String = absolute + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": error_string(FileAccess.get_open_error())}
	var envelope: Dictionary = {"save_format": 1, "engine_version": Engine.get_version_info().string, "snapshot": snapshot, "metadata": metadata}
	file.store_string(JSON.stringify(envelope, "  "))
	file.flush()
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK:
		return {"ok": false, "error": error_string(write_error)}
	if FileAccess.file_exists(absolute):
		var backup_error: Error = DirAccess.copy_absolute(absolute, absolute + ".bak")
		if backup_error != OK:
			return {"ok": false, "error": "BACKUP_FAILED: " + error_string(backup_error)}
	var rename_error: Error = DirAccess.rename_absolute(temporary, absolute)
	if rename_error != OK:
		return {"ok": false, "error": "REPLACE_FAILED: " + error_string(rename_error)}
	if OS.has_feature("web"):
		JavaScriptBridge.force_fs_sync()
	return {"ok": true, "path": path, "checksum": State.canonical_json(snapshot).sha256_text()}

static func read(path: String) -> Dictionary:
	if not path.begins_with("user://") or path.contains(".."):
		return {"ok": false, "error": "INVALID_SAVE_PATH"}
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "SAVE_NOT_FOUND"}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": error_string(FileAccess.get_open_error())}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary or parsed.get("save_format", 0) != 1 or not parsed.get("snapshot") is Dictionary or not parsed.get("metadata", {}) is Dictionary:
		return {"ok": false, "error": "INVALID_SAVE_FORMAT"}
	var errors: Array = State.validation_errors(parsed.snapshot)
	if not errors.is_empty():
		return {"ok": false, "error": "INVALID_SNAPSHOT", "details": errors}
	return {"ok": true, "snapshot": parsed.snapshot, "metadata": parsed.get("metadata", {})}

static func exists(path: String) -> bool:
	return FileAccess.file_exists(path)
