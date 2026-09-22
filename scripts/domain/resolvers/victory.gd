extends RefCounted
const Economy = preload("res://scripts/domain/resolvers/economy.gd")

static func progress(game: RefCounted, player_id: String) -> Dictionary:
	var hero: Dictionary = game.state.data.heroes[player_id]
	var towers: int = 0
	var worldspire_owned: bool = false
	for location: Dictionary in game.state.data.map.locations.values():
		if location.owner_id == player_id and location.kind in ["ancient_tower", "worldspire"]:
			towers += 1
			if location.kind == "worldspire": worldspire_owned = true
	var network: Dictionary = Economy.network(game, player_id)
	var required_towers: int = game.definitions.victory.conquest.ancient_towers
	var required_settlements: int = game.definitions.victory.dominion.settlements
	var required_gold: int = game.definitions.victory.dominion.gold
	var required_relics: int = game.definitions.victory.ascension.relics
	var at_worldspire: bool = hero.hex == game.state.data.map.locations.worldspire.hex
	var ritual: bool = game.state.data.commitments.get(player_id, {}).get("kind", "") == "ritual"
	return {
		"conquest": {"controlled": towers, "required": required_towers, "eligible": towers >= required_towers and worldspire_owned},
		"dominion": {"settlements": network.settlements.size(), "required": required_settlements, "connected": network.connected, "path": network.path, "gold": hero.gold, "required_gold": required_gold, "eligible": network.settlements.size() >= required_settlements and network.connected and int(hero.gold) >= required_gold},
		"ascension": {"relics": hero.relics.size(), "required": required_relics, "at_worldspire": at_worldspire, "ritual_active": ritual, "eligible": hero.relics.size() >= required_relics and at_worldspire}
	}

static func cancel_invalid(game: RefCounted) -> void:
	for claim_id: String in game.state.data.victory_claims.keys():
		var claim: Dictionary = game.state.data.victory_claims[claim_id]
		if not progress(game, claim.player_id)[claim.route].eligible:
			game.state.data.victory_claims.erase(claim_id)
			game._emit("VictoryClaimCanceled", claim.player_id, {"route": claim.route, "claim_id": claim_id, "cause": "requirements_lost"})
	for player_id: String in game.state.data.commitments.keys():
		if game.state.data.commitments[player_id].kind == "ritual" and not progress(game, player_id).ascension.eligible:
			game._cancel_commitment(player_id, "ritual_requirements_lost")

static func confirm_existing(game: RefCounted) -> bool:
	cancel_invalid(game)
	var eligible: Array[Dictionary] = []
	var longest: int = 0
	for claim_id: String in game.state.data.victory_claims:
		var claim: Dictionary = game.state.data.victory_claims[claim_id]
		var held: int = int(game.state.data.round_number) - int(claim.created_round)
		if held < int(game.definitions.victory[claim.route].response_rounds): continue
		if held > longest:
			eligible.clear()
			longest = held
		if held == longest: eligible.append(claim)
	if eligible.is_empty(): return false
	var winners: Array[String] = []
	var routes: Array[String] = []
	for claim: Dictionary in eligible:
		if not winners.has(claim.player_id): winners.append(claim.player_id)
		if not routes.has(claim.route): routes.append(claim.route)
	winners.sort()
	routes.sort()
	_achieve(game, winners, routes[0] if routes.size() == 1 else "shared", {"claims": eligible, "rounds_held": longest})
	return true

static func create_claims(game: RefCounted) -> void:
	for player_id: String in ["p1", "p2", "p3", "p4"]:
		var tracks: Dictionary = progress(game, player_id)
		for route: String in ["conquest", "dominion"]:
			var claim_id: String = player_id + "_" + route
			if tracks[route].eligible and not game.state.data.victory_claims.has(claim_id):
				var claim: Dictionary = {"player_id": player_id, "route": route, "created_round": game.state.data.round_number, "required_round": int(game.state.data.round_number) + int(game.definitions.victory[route].response_rounds)}
				game.state.data.victory_claims[claim_id] = claim
				game._emit("VictoryClaimCreated", player_id, claim)

static func begin_ritual(game: RefCounted, player_id: String) -> void:
	game.state.data.commitments[player_id] = {"kind": "ritual", "location_id": "worldspire", "hex": game.state.data.heroes[player_id].hex, "round": game.state.data.round_number, "cycle": game.state.data.action_cycle}
	game._emit("RitualBegun", player_id, game.state.data.commitments[player_id])

static func complete_ritual(game: RefCounted, player_id: String) -> void:
	game.state.data.commitments.erase(player_id)
	game._emit("RitualCompleted", player_id, {"relics": game.state.data.heroes[player_id].relics.duplicate()})
	_achieve(game, [player_id], "ascension", {})

static func _achieve(game: RefCounted, winners: Array[String], route: String, details: Dictionary) -> void:
	game.state.data.victory = {"winners": winners, "route": route, "round": game.state.data.round_number, "shared": winners.size() > 1, "details": details.duplicate(true)}
	game.state.data.current_actor_index = 0
	game._set_phase("victory")
	game._emit("VictoryAchieved", "", game.state.data.victory)
