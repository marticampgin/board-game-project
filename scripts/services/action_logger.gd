extends RefCounted
## Diagnostic data lives outside authoritative state: wall-clock time never changes replay hashes.

var entries: Array[Dictionary] = []
var path: String
var last_error: String = ""

func _init(output_path: String = "") -> void:
	path = output_path

func execute(rules: RefCounted, command: Dictionary, source: String = "local") -> Dictionary:
	var before: Dictionary = rules.snapshot()
	var before_hash: String = rules.checksum()
	var started: int = Time.get_ticks_usec()
	var result: Dictionary = rules.execute(command)
	var after: Dictionary = rules.snapshot()
	var entry: Dictionary = {
		"log_schema": 1,
		"timestamp_utc": Time.get_datetime_string_from_system(true) + "Z",
		"source": source,
		"command": command.duplicate(true),
		"accepted": result.get("is_valid", false),
		"reason_code": result.get("reason_code", "UNKNOWN"),
		"message": result.get("message", ""),
		"duration_us": Time.get_ticks_usec() - started,
		"seed": before.get("master_seed", 0),
		"round_before": before.get("round_number", 0),
		"phase_before": before.get("phase", ""),
		"phase_after": after.get("phase", ""),
		"decision_before": _decision_label(before),
		"decision_after": _decision_label(after),
		"version_before": before.get("state_version", 0),
		"version_after": after.get("state_version", 0),
		"checksum_before": before_hash,
		"checksum_after": rules.checksum(),
		"rng_before": before.get("rng", {}).duplicate(true),
		"rng_after": after.get("rng", {}).duplicate(true),
		"events": result.get("events", []).duplicate(true)
	}
	entries.append(entry)
	_append(entry)
	return result

func to_jsonl() -> String:
	var lines: PackedStringArray = []
	for entry: Dictionary in entries:
		lines.append(JSON.stringify(entry))
	return "\n".join(lines) + ("\n" if not entries.is_empty() else "")

func to_text() -> String:
	var lines: PackedStringArray = []
	for entry: Dictionary in entries:
		lines.append(format_entry(entry))
	return "\n".join(lines)

static func format_entry(entry: Dictionary) -> String:
	var command: Dictionary = entry.get("command", {})
	var status: String = "ACCEPT" if entry.get("accepted", false) else "REJECT"
	var lines: PackedStringArray = [
		"[%s] %s r%s %s v%s->%s %s %s %s (%s)" % [
			entry.get("timestamp_utc", ""), status, entry.get("round_before", 0),
			entry.get("phase_before", ""), entry.get("version_before", 0),
			entry.get("version_after", 0), command.get("type", "?"),
			command.get("player_id", "-"), command.get("target", ""), entry.get("reason_code", "")
		],
		"  hash %s -> %s" % [entry.get("checksum_before", ""), entry.get("checksum_after", "")]
	]
	if entry.get("decision_before", "action") != "action" or entry.get("decision_after", "action") != "action":
		lines.append("  decision %s -> %s" % [entry.get("decision_before", "action"), entry.get("decision_after", "action")])
	if not entry.get("accepted", false):
		lines.append("  " + str(entry.get("message", "")))
	for event: Dictionary in entry.get("events", []):
		lines.append("  #%s %s %s" % [event.get("sequence", "?"), event.get("type", "?"), JSON.stringify(event.get("data", {}))])
	return "\n".join(lines)

static func _decision_label(snapshot: Dictionary) -> String:
	if not snapshot.get("pending_exploration", {}).is_empty(): return "exploration:reward"
	if not snapshot.get("victory", {}).is_empty(): return "victory"
	var reaction: Dictionary = snapshot.get("pending_reaction", {})
	if not reaction.is_empty():
		return "reaction:" + str(reaction.get("kind", ""))
	var combat: Dictionary = snapshot.get("pending_combat", {})
	if not combat.is_empty():
		return "combat:" + str(combat.get("stage", ""))
	return "action"

func _append(entry: Dictionary) -> void:
	if path.is_empty():
		return
	var absolute: String = ProjectSettings.globalize_path(path)
	var error: Error = DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if error != OK:
		last_error = "Cannot create log directory: %s" % error_string(error)
		push_warning(last_error)
		return
	var file: FileAccess = FileAccess.open(absolute, FileAccess.READ_WRITE if FileAccess.file_exists(absolute) else FileAccess.WRITE)
	if file == null:
		last_error = "Cannot open action log %s: %s" % [path, error_string(FileAccess.get_open_error())]
		push_warning(last_error)
		return
	file.seek_end()
	file.store_line(JSON.stringify(entry))
	file.flush()
