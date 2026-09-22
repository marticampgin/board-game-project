extends Node
## Native ENet proof of concept. Only the host owns Rules and gameplay RNG.
## Every RPC payload is projected before serialization; clients never receive a save.
signal observation_updated(view: Dictionary)
signal lobby_updated(lobby: Dictionary)
signal command_result(result: Dictionary)
signal connection_failed(message: String)

const Rules = preload("res://scripts/domain/game_rules.gd")
const Observation = preload("res://scripts/network/observation.gd")
const Gate = preload("res://scripts/network/command_gate.gd")
const ActionLog = preload("res://scripts/services/action_logger.gd")
const Bot = preload("res://scripts/domain/bots/simple_bot.gd")
const Objectives = preload("res://scripts/domain/bots/objective_policy.gd")
const PLAYERS: Array[String] = ["p1", "p2", "p3", "p4"]

var is_host: bool = false
var local_player_id: String = ""
var latest_observation: Dictionary = {}
var reconnect_token: String = ""
var rules: RefCounted = null
var started: bool = false
var auto_drive: bool = true
var bot_interval_seconds: float = 0.25
var reaction_timeout_seconds: float = 20.0
var planning_timeout_seconds: float = 60.0
var action_timeout_seconds: float = 20.0
var log_path: String = "user://logs/network_actions.jsonl"
var action_log: RefCounted
var next_sequence: int = 1

var _api: SceneMultiplayer
var _peer: ENetMultiplayerPeer
var _seats: Dictionary = {}
var _peer_seats: Dictionary = {}
var _next_sequence_by_seat: Dictionary = {}
var _tokens: Dictionary = {}
var _join_token: String = ""
var _clock_seconds: float = 0.0
var _drive_elapsed: float = 0.0
var _window_key: String = ""
var _window_started: float = 0.0
var _waiting_since: Dictionary = {}
var _active: bool = false
var _inflight: bool = false

func _ready() -> void:
	_setup_api()

func _setup_api() -> void:
	if _api != null or not is_inside_tree(): return
	_api = SceneMultiplayer.new()
	_api.root_path = get_path()
	_api.allow_object_decoding = false
	_api.server_relay = false
	get_tree().set_multiplayer(_api, get_path())
	_api.peer_disconnected.connect(_on_peer_disconnected)
	_api.connected_to_server.connect(_on_connected)
	_api.connection_failed.connect(_on_connection_failed)
	_api.server_disconnected.connect(_on_server_disconnected)

func host_game(port: int, seed: int) -> Error:
	disconnect_session()
	_setup_api()
	if _api == null: return ERR_UNCONFIGURED
	if port < 1 or port > 65535: return ERR_INVALID_PARAMETER
	_peer = ENetMultiplayerPeer.new()
	var error: Error = _peer.create_server(port, 3)
	if error != OK:
		connection_failed.emit("Could not host ENet: " + error_string(error))
		return error
	_api.multiplayer_peer = _peer
	is_host = true
	_active = true
	local_player_id = "p1"
	rules = Rules.new(seed)
	action_log = ActionLog.new(log_path)
	for player: String in PLAYERS:
		_seats[player] = {"player_id": player, "connected": player == "p1", "kind": "host" if player == "p1" else "bot"}
		_next_sequence_by_seat[player] = 1
	_broadcast()
	return OK

func join_game(address: String, port: int, token: String = "") -> Error:
	disconnect_session()
	_setup_api()
	if _api == null: return ERR_UNCONFIGURED
	if port < 1 or port > 65535 or address.strip_edges().is_empty(): return ERR_INVALID_PARAMETER
	_join_token = token
	reconnect_token = token
	_peer = ENetMultiplayerPeer.new()
	var error: Error = _peer.create_client(address.strip_edges(), port)
	if error != OK:
		connection_failed.emit("Could not join ENet: " + error_string(error))
		return error
	_api.multiplayer_peer = _peer
	_active = true
	return OK

func start_match() -> Dictionary:
	if not is_host or rules == null: return _local_failure("NETWORK_HOST_ONLY", "Only the host may start the match")
	if started: return _local_failure("NETWORK_ALREADY_STARTED", "This match has already started")
	started = true
	_window_key = ""
	_broadcast()
	return {"is_valid": true, "reason_code": "OK", "message": "Match started", "state_version": rules.state.data.state_version}

func submit(command: Dictionary) -> void:
	if not _active or local_player_id.is_empty():
		command_result.emit(_local_failure("NETWORK_DISCONNECTED", "No connected player seat"))
		return
	if _inflight:
		command_result.emit(_local_failure("NETWORK_PENDING", "Wait for the current command result"))
		return
	var intent: Dictionary = command.duplicate(true)
	if not intent.has("player_id") and intent.get("type", "") != "advance": intent.player_id = local_player_id
	if not intent.has("expected_version"): intent.expected_version = int(latest_observation.get("state_version", -1))
	if is_host:
		if intent.get("type", "") != "advance" and intent.get("player_id", "") != local_player_id:
			command_result.emit(_local_failure("NETWORK_SEAT", "Use your own seat for player commands"))
			return
		var response: Dictionary = submit_as_host(intent, "network:host:p1")
		command_result.emit(_filter_result(response, local_player_id))
	else:
		_inflight = true
		_request_command.rpc_id(1, next_sequence, intent)

func submit_as_host(command: Dictionary, source: String = "network:host") -> Dictionary:
	# Local-only harness / bot entry point, deliberately not an RPC.
	if not is_host or rules == null: return _local_failure("NETWORK_HOST_ONLY", "Only the host owns the rules")
	if not started: return _local_failure("NETWORK_NOT_STARTED", "Start the match first")
	var intent: Dictionary = command.duplicate(true)
	if not intent.has("expected_version"): intent.expected_version = int(rules.state.data.state_version)
	var result: Dictionary = action_log.execute(rules, intent, source)
	if result.is_valid: _broadcast()
	return result

func disconnect_session() -> void:
	_active = false
	if _peer != null: _peer.close()
	if _api != null: _api.multiplayer_peer = OfflineMultiplayerPeer.new()
	_peer = null
	is_host = false
	started = false
	rules = null
	local_player_id = ""
	latest_observation = {}
	_seats.clear()
	_peer_seats.clear()
	_tokens.clear()
	_next_sequence_by_seat.clear()
	_clock_seconds = 0.0
	_drive_elapsed = 0.0
	_window_key = ""
	_window_started = 0.0
	_waiting_since.clear()
	_inflight = false
	next_sequence = 1

func lobby_snapshot() -> Dictionary:
	var seats: Array = []
	for player: String in PLAYERS:
		if _seats.has(player): seats.append(_seats[player].duplicate(true))
	return {"started": started, "seats": seats}

func _on_connected() -> void:
	if not is_host: _hello.rpc_id(1, _join_token)

@rpc("any_peer", "call_remote", "reliable")
func _hello(token: String) -> void:
	if not is_host: return
	var peer_id: int = _api.get_remote_sender_id()
	if _peer_seats.has(peer_id): return
	var player: String = ""
	if not token.is_empty():
		player = str(_tokens.get(token, ""))
		if player.is_empty() or bool(_seats[player].connected):
			_join_rejected.rpc_id(peer_id, "Reconnect token is invalid or its seat is already connected")
			return
	else:
		for candidate: String in ["p2", "p3", "p4"]:
			if _seats[candidate].kind == "bot" and not _tokens.values().has(candidate):
				player = candidate
				break
		if player.is_empty():
			_join_rejected.rpc_id(peer_id, "All human seats are reserved; reconnect with your seat token")
			return
		token = Crypto.new().generate_random_bytes(32).hex_encode()
		_tokens[token] = player
	_peer_seats[peer_id] = player
	_seats[player] = {"player_id": player, "connected": true, "kind": "human"}
	_welcome.rpc_id(peer_id, player, token, int(_next_sequence_by_seat[player]))
	_broadcast()

@rpc("authority", "call_remote", "reliable")
func _welcome(player_id: String, token: String, sequence: int) -> void:
	if is_host: return
	local_player_id = player_id
	reconnect_token = token
	next_sequence = sequence
	_inflight = false

@rpc("authority", "call_remote", "reliable")
func _join_rejected(message: String) -> void:
	if is_host: return
	disconnect_session()
	connection_failed.emit(message)

@rpc("any_peer", "call_remote", "reliable")
func _request_command(client_sequence: int, command: Dictionary) -> void:
	if not is_host or rules == null: return
	var peer_id: int = _api.get_remote_sender_id()
	var player: String = str(_peer_seats.get(peer_id, ""))
	var expected: int = int(_next_sequence_by_seat.get(player, 1))
	var gate: Dictionary = Gate.check(player, expected - 1, client_sequence, command, started)
	if not player.is_empty(): _next_sequence_by_seat[player] = gate.next_sequence
	var result: Dictionary
	var source: String = "network:peer%d:%s" % [peer_id, player]
	if gate.is_valid:
		result = action_log.execute(rules, command, source)
	else:
		result = _local_failure(gate.reason_code, gate.message)
		_audit_rejection(command, source, result, client_sequence)
	result = _filter_result(result, player)
	result.client_sequence = client_sequence
	result.next_sequence = gate.next_sequence
	# Both observation and result use the reliable channel; clients see the
	# matching version before they unlock submission for their next command.
	if result.is_valid: _broadcast()
	_deliver_result.rpc_id(peer_id, result)

@rpc("authority", "call_remote", "reliable")
func _deliver_result(result: Dictionary) -> void:
	if is_host: return
	next_sequence = int(result.get("next_sequence", next_sequence))
	_inflight = false
	command_result.emit(result)

@rpc("authority", "call_remote", "reliable")
func _receive_observation(view: Dictionary) -> void:
	if is_host: return
	if view.get("player_id", "") != local_player_id or not Observation.verify(view):
		connection_failed.emit("Observation checksum or recipient does not match")
		return
	if not latest_observation.is_empty() and int(view.state_version) < int(latest_observation.state_version): return
	latest_observation = view.duplicate(true)
	started = bool(view.started)
	lobby_updated.emit(view.lobby.duplicate(true))
	observation_updated.emit(latest_observation)

func _broadcast() -> void:
	if not is_host or rules == null: return
	_sync_window_clock()
	var lobby: Dictionary = lobby_snapshot()
	latest_observation = Observation.build(rules, "p1", started, lobby)
	lobby_updated.emit(lobby)
	observation_updated.emit(latest_observation)
	for peer_id: int in _peer_seats:
		var player: String = _peer_seats[peer_id]
		_receive_observation.rpc_id(peer_id, Observation.build(rules, player, started, lobby))

func _filter_result(result: Dictionary, player: String) -> Dictionary:
	var safe: Dictionary = result.duplicate(true)
	safe.events = Observation.visible_events(rules.snapshot(), safe.get("events", []), player)
	return safe

func _local_failure(code: String, message: String) -> Dictionary:
	return {"is_valid": false, "reason_code": code, "message": message,
		"state_version": int(rules.state.data.state_version) if rules != null else int(latest_observation.get("state_version", 0)), "events": []}

func _audit_rejection(command: Dictionary, source: String, result: Dictionary, sequence: int) -> void:
	var hash: String = rules.checksum()
	var state: Dictionary = rules.state.data
	var entry: Dictionary = {"log_schema": 1, "timestamp_utc": Time.get_datetime_string_from_system(true) + "Z",
		"source": source, "client_sequence": sequence, "command": command.duplicate(true), "accepted": false,
		"reason_code": result.reason_code, "message": result.message, "duration_us": 0,
		"seed": state.master_seed, "round_before": state.round_number, "phase_before": state.phase, "phase_after": state.phase,
		"version_before": state.state_version, "version_after": state.state_version,
		"checksum_before": hash, "checksum_after": hash, "rng_before": state.rng.duplicate(true), "rng_after": state.rng.duplicate(true), "events": []}
	action_log.entries.append(entry)
	action_log._append(entry)

func _on_peer_disconnected(peer_id: int) -> void:
	if not is_host or not _peer_seats.has(peer_id): return
	var player: String = _peer_seats[peer_id]
	_peer_seats.erase(peer_id)
	_seats[player].connected = false
	_seats[player].kind = "bot"
	_broadcast()

func _on_connection_failed() -> void:
	disconnect_session()
	connection_failed.emit("Could not reach the ENet host")

func _on_server_disconnected() -> void:
	disconnect_session()
	connection_failed.emit("Host disconnected. Rejoin with your retained reconnect token if it returns.")

func _process(delta: float) -> void:
	tick(delta)

func tick(delta: float) -> void:
	if not is_host or not started or rules == null or rules.state.data.phase == "victory": return
	_clock_seconds += maxf(delta, 0.0)
	_sync_window_clock()
	expire_pending_windows()
	if not auto_drive: return
	_drive_elapsed += maxf(delta, 0.0)
	if _drive_elapsed < bot_interval_seconds: return
	_drive_elapsed = 0.0
	var command: Dictionary = _next_host_command()
	if not command.is_empty(): submit_as_host(command, "network:bot:" + str(command.get("player_id", "phase")))

func _sync_window_clock() -> void:
	var active: Dictionary = {}
	for player: String in PLAYERS:
		var fallback: Dictionary = _safe_default(player, rules.legal_actions(player))
		if fallback.is_empty(): continue
		var key: String = _decision_key(player, fallback.type)
		active[key] = float(_waiting_since.get(key, _clock_seconds))
	_waiting_since = active

func _decision_key(player: String, command_type: String) -> String:
	var state: Dictionary = rules.state.data
	return "%d:%s:%d:%s:%s:%s" % [int(state.round_number), state.phase, int(state.current_actor_index), player, command_type, state.pending_reaction.get("kind", "")]

func expire_pending_windows() -> void:
	if not is_host or not started or rules == null: return
	for player: String in PLAYERS:
		var legal: Dictionary = rules.legal_actions(player)
		var fallback: Dictionary = _safe_default(player, legal)
		if fallback.is_empty(): continue
		var key: String = _decision_key(player, fallback.type)
		var elapsed: float = _clock_seconds - float(_waiting_since.get(key, _clock_seconds))
		var limit: float = reaction_timeout_seconds
		if fallback.type == "ready": limit = planning_timeout_seconds
		elif fallback.type == "pass": limit = action_timeout_seconds
		if limit <= 0.0 or elapsed < limit: continue
		submit_as_host(fallback, "network:timeout:" + player)
		_sync_window_clock()
		return

static func _safe_default(player: String, legal: Dictionary) -> Dictionary:
	var command: Dictionary = {"player_id": player}
	if legal.has("resolve_reaction"): command.merge({"type": "resolve_reaction", "choice": "decline"})
	elif legal.has("decline_fate"): command.type = "decline_fate"
	elif legal.has("choose_stance"): command.merge({"type": "choose_stance", "stance": "guard"})
	elif legal.has("displace"):
		var targets: Array = legal.displace.targets.keys()
		targets.sort()
		if targets.is_empty(): return {}
		command.merge({"type": "displace", "target": targets[0]})
	elif legal.has("choose_reward"):
		var choices: Array = legal.choose_reward.choices.keys()
		choices.sort()
		if choices.is_empty(): return {}
		command.merge({"type": "choose_reward", "choice": choices[0]})
	elif legal.has("ready"): command.type = "ready"
	elif legal.has("pass"): command.type = "pass"
	else: return {}
	return command

func _next_host_command() -> Dictionary:
	var state: Dictionary = rules.snapshot()
	if state.phase in ["world", "initiative", "bonus", "resolution"]: return {"type": "advance"}
	for player: String in PLAYERS:
		if _seats[player].kind != "bot": continue
		var legal: Dictionary = rules.legal_actions(player)
		var window: Dictionary = Bot._window_choice(state, player, legal)
		if not window.is_empty(): return window
		if state.phase == "planning":
			if legal.has("submit_plan") and not state.plans.has(player):
				return {"type": "submit_plan", "player_id": player, "plan": Bot._plan(state, player, legal.submit_plan)}
			if legal.has("ready"): return {"type": "ready", "player_id": player}
	var actor: String = rules.current_actor()
	if actor.is_empty() or _seats[actor].kind != "bot": return {}
	if not state.pending_combat.is_empty() or not state.pending_reaction.is_empty() or not state.get("pending_exploration", {}).is_empty(): return {}
	return Objectives.choose(state, actor, rules.legal_actions(actor), rules.victory_progress(actor))

func _exit_tree() -> void:
	if _peer != null: _peer.close()
