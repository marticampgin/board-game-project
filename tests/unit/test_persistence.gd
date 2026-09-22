extends RefCounted
const Rules = preload("res://scripts/domain/game_rules.gd")
const Store = preload("res://scripts/services/snapshot_store.gd")

func run() -> Array[String]:
	var errors: Array[String] = []
	var path: String = "user://test_saves/snapshot_%s.json" % Time.get_ticks_usec()
	var game: RefCounted = Rules.new(20260922)
	var original: String = game.checksum()
	var saved: Dictionary = Store.write(path, game.snapshot(), {"mode": "solo", "human_seat": "p3"})
	if not saved.ok: return ["Cannot create snapshot: " + str(saved)]
	var loaded: Dictionary = Store.read(path)
	if not loaded.ok: return ["Cannot read snapshot: " + str(loaded)]
	var restored: RefCounted = Rules.from_snapshot(loaded.snapshot)
	if restored == null or restored.checksum() != original: errors.append("Snapshot changes authoritative checksum")
	if loaded.metadata != {"mode": "solo", "human_seat": "p3"}: errors.append("Session metadata is not restored")
	game.execute({"type": "advance"})
	saved = Store.write(path, game.snapshot())
	if not saved.ok: errors.append("Atomic replacement failed: " + str(saved))
	var backup: Dictionary = Store.read(path + ".bak")
	if not backup.ok or Rules.from_snapshot(backup.snapshot).checksum() != original: errors.append("Backup is not the preceding snapshot")
	var corrupt: Dictionary = game.snapshot()
	corrupt.schema_version = -1
	if Store.write(path, corrupt).ok: errors.append("Unknown schema accepted for writing")
	loaded = Store.read(path)
	if not loaded.ok or Rules.from_snapshot(loaded.snapshot).checksum() != game.checksum(): errors.append("Rejected save corrupted existing file")
	if Store.read(path + ".missing").ok: errors.append("Missing save was accepted")
	if Store.write("res://forbidden.json", game.snapshot()).ok: errors.append("Save path escaped user data directory")
	for suffix: String in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(path + suffix): DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))
	return errors
