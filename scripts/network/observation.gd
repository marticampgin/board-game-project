extends RefCounted
## A transport boundary, not a save format. Never restore Rules from this view.
## Seed and RNG are private too: either would reconstruct undiscovered content.
const State = preload("res://scripts/domain/state/game_state.gd")
const PLAYERS: Array[String] = ["p1", "p2", "p3", "p4"]

static func build(game: RefCounted, player_id: String, started: bool = true, lobby: Dictionary = {}) -> Dictionary:
	var source: Dictionary = game.snapshot()
	var progress: Dictionary = {}
	for player: String in PLAYERS: progress[player] = game.victory_progress(player)
	var public_state: Dictionary = project_state(source, "")
	var view: Dictionary = {"player_id": player_id, "state_version": source.state_version,
		"state": project_state(source, player_id), "legal_actions": game.legal_actions(player_id) if started else {},
		"victory_progress": progress, "started": started, "lobby": lobby.duplicate(true),
		"public_checksum": State.canonical_json({"state": public_state, "victory_progress": progress}).sha256_text()}
	view["view_checksum"] = checksum(view)
	return view

static func checksum(view: Dictionary) -> String:
	var payload: Dictionary = view.duplicate(true)
	payload.erase("view_checksum")
	return State.canonical_json(payload).sha256_text()

static func verify(view: Dictionary) -> bool:
	return view.get("view_checksum", "") == checksum(view)

static func project_state(source: Dictionary, viewer: String) -> Dictionary:
	var result: Dictionary = source.duplicate(true)
	for key: String in ["rng", "commands", "master_seed"]: result.erase(key)
	result.map.erase("seed")
	result.map.report = {"valid": bool(source.map.report.get("valid", true))}
	result.plans = {}
	if not viewer.is_empty() and source.plans.has(viewer): result.plans[viewer] = source.plans[viewer].duplicate(true)
	var remap: Dictionary = _location_aliases(source, viewer)
	var locations: Dictionary = {}
	for location_id: String in source.map.locations:
		var location: Dictionary = source.map.locations[location_id]
		var known: bool = _known(location, viewer)
		var public_site: bool = _public_site(location)
		var safe: Dictionary
		if known:
			safe = location.duplicate(true)
		else:
			safe = {"id": remap.get(location_id, location_id), "hex": location.hex,
				"kind": location.kind if public_site else "unknown", "name": location.name if public_site else "Undiscovered",
				"owner_id": location.owner_id if public_site else "", "level": location.level if public_site else 1,
				"trait": "", "discovered_by": []}
		# A rival's discovery history is not part of public board knowledge.
		safe.discovered_by = [viewer] if not viewer.is_empty() and location.discovered_by.has(viewer) else []
		locations[safe.id] = safe
	result.map.locations = locations
	for tile: Dictionary in result.map.hexes.values():
		tile.location_id = remap.get(tile.location_id, tile.location_id)
	for player: String in result.heroes:
		var hero: Dictionary = result.heroes[player]
		if player != viewer:
			hero.erase("prepared_hex")
			hero.erase("occult_hint")
			hero.relics = _relic_tokens(hero.relics.size())
		hero.controlled_locations = _replace_identifiers(hero.controlled_locations, remap)
	result.monsters = {}
	for monster_id: String in source.monsters:
		var monster: Dictionary = source.monsters[monster_id]
		if _known(source.map.locations[monster.camp_id], viewer): result.monsters[monster_id] = monster.duplicate(true)
	result.traps = {}
	for owner: String in source.traps:
		var trap: Dictionary = source.traps[owner]
		if owner == viewer:
			result.traps[owner] = trap.duplicate(true)
		else:
			result.traps["warning_" + str(trap.hex)] = {"hex": trap.hex, "warning": "trapped_hex", "expires_round": trap.expires_round}
	var combat: Dictionary = result.pending_combat
	if combat.get("stage", "") == "stances":
		var selected: Dictionary = combat.get("stances", {})
		combat.stances = {viewer: selected[viewer]} if not viewer.is_empty() and selected.has(viewer) else {}
		combat.erase("calculation")
		combat.erase("dice")
	var exploration: Dictionary = result.get("pending_exploration", {})
	if not exploration.is_empty() and exploration.get("player_id", "") != viewer:
		exploration.erase("choices")
		exploration.erase("dark_bargain")
	for loot: Dictionary in result.ground_loot.values():
		loot.relics = _relic_tokens(loot.get("relics", []).size())
	result.events = visible_events(source, source.events, viewer)
	# IDs encode site kinds; aliases also cover commitments and event references.
	return _scrub(_replace_identifiers(result, remap))

static func visible_events(source: Dictionary, events: Array, viewer: String) -> Array:
	var result: Array = []
	var aliases: Dictionary = _location_aliases(source, viewer)
	for event: Dictionary in events:
		var actor: String = str(event.get("actor_id", ""))
		if event.get("visibility", "public") != "public" and actor != viewer: continue
		if event.type == "GameCreated": continue
		if event.type in ["LocationDiscovered", "ExplorationChoicesOffered"] and actor != viewer: continue
		if event.type in ["RuinExplored", "EquipmentFound", "RelicCollected"] and actor != viewer:
			var location_id: String = str(event.data.get("location_id", event.data.get("source", "")))
			if aliases.has(location_id): continue
		var safe: Dictionary = event.duplicate(true)
		if safe.type == "TrapWarningPlaced": safe.actor_id = ""
		if safe.type == "DieRolled":
			# Draw counters/stream labels are diagnostic authority data, not UI dice.
			for key: String in ["stream", "draw_index", "minimum", "maximum"]: safe.data.erase(key)
		result.append(_scrub(_replace_identifiers(safe, aliases)))
	return result

static func _public_site(location: Dictionary) -> bool:
	return location.kind in ["ancient_tower", "worldspire"] or not str(location.owner_id).is_empty()

static func _known(location: Dictionary, viewer: String) -> bool:
	# Owning a location announces its kind publicly, while its trait still
	# requires individual discovery. This helper means full private knowledge.
	return not viewer.is_empty() and location.discovered_by.has(viewer)

static func _location_aliases(source: Dictionary, viewer: String) -> Dictionary:
	var result: Dictionary = {}
	for location_id: String in source.map.locations:
		var location: Dictionary = source.map.locations[location_id]
		if not _known(location, viewer) and not _public_site(location): result[location_id] = "site_" + str(location.hex)
	for monster_id: String in source.monsters:
		var monster: Dictionary = source.monsters[monster_id]
		if not _known(source.map.locations[monster.camp_id], viewer): result[monster_id] = "creature_" + str(monster.hex)
	return result

static func _relic_tokens(count: int) -> Array:
	var tokens: Array = []
	for index: int in range(count): tokens.append("relic_%d" % (index + 1))
	return tokens

static func _replace_identifiers(value: Variant, aliases: Dictionary) -> Variant:
	if value is String or value is StringName: return aliases.get(str(value), str(value))
	if value is Array:
		var values: Array = []
		for item: Variant in value: values.append(_replace_identifiers(item, aliases))
		return values
	if value is Dictionary:
		var values: Dictionary = {}
		for key: Variant in value: values[aliases.get(str(key), str(key))] = _replace_identifiers(value[key], aliases)
		return values
	return value

static func _scrub(value: Variant) -> Variant:
	if value is Dictionary:
		var values: Dictionary = {}
		for key: Variant in value:
			if str(key) in ["rng", "commands", "master_seed", "seed", "map_report"]: continue
			if str(key) == "relic_id":
				values[key] = "relic"
				continue
			if str(key) == "relics" and value[key] is Array:
				values[key] = _relic_tokens(value[key].size())
				continue
			values[key] = _scrub(value[key])
		return values
	if value is Array:
		var values: Array = []
		for item: Variant in value: values.append(_scrub(item))
		return values
	return value
