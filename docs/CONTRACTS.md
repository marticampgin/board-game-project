# Shared implementation contracts

These interfaces keep independently implemented model, renderer and tools aligned. Paths use preloads rather than requiring editor-generated class caches.

## Hex / RNG / map (generation owner)

`scripts/domain/hex/hex.gd` static functions: `key(q:int,r:int)->String`, `parse(key:String)->Vector2i`, `neighbors(key:String)->Array[String]`, `distance(a:String,b:String)->int`, `range_keys(center:String,radius:int)->Array[String]`, `ring(center:String,radius:int)->Array[String]`, `to_world(key:String,size:float=1.0)->Vector3`, `from_world(point:Vector3,size:float=1.0)->String`, `to_cube(key:String)->Vector3i`, `from_cube(cube:Vector3i)->String`.

`scripts/services/deterministic_rng.gd`: `new(master_seed:int=1)`, `draw(stream:String,minimum:int,maximum:int)->Dictionary` returns `{stream,draw_index,minimum,maximum,result}`, `snapshot()->Dictionary`, `restore(data:Dictionary)->void`. Use safe serializable PRNG state (integer precision must survive JSON) and independently derived streams.

`scripts/domain/generation/map_generator.gd`: `generate(seed:int)->Dictionary` returns `{seed, radius:4, hexes:Dictionary, locations:Dictionary, sanctuaries:Array[String], roads:Array, report:Dictionary}`. Hex record `{id,q,r,terrain,region,location_id}`. Location record `{id,hex,kind,name,owner_id:"",level:1,trait,discovered_by:Array}`, kind `minor_tower`, `ancient_tower`, `worldspire`, `settlement`, `ruin`, `monster_camp`. Road is a two-key array `[a,b]`. `validate(map:Dictionary)->Dictionary` returns `{valid,errors:Array, ...diagnostics}`. Exactly 61 hexes, 16 locations, 4 sanctuaries, 4 ancient including Worldspire; no location at sanctuary.

`scripts/domain/resolvers/movement.gd`: `reachable(map:Dictionary,heroes:Dictionary,hero_id:String)->Dictionary` keyed by destination hex: `{cost:int,path:Array[String],road_only:bool}`. Hero dictionary fields below. Forest Ranger cost 1, other cost 2; swamp ends Move; road-only budget 4 otherwise 3; occupied tiles block traversal; no current hex in reachable. `travel_costs(map:Dictionary,start:String)->Dictionary` for map validation, standard terrain, swamp cost 3.

## Rules / state (rules owner)

`scripts/domain/state/game_state.gd`: `var data:Dictionary`, `to_dict()->Dictionary`, `to_json()->String`, static `from_dict(data:Dictionary)` creates validated state or null, `checksum()->String` canonical recursively sorted JSON SHA256. Data fields: `schema_version:1,content_version,master_seed,round_number,phase,action_cycle,current_actor_index,initiative_order:Array[String],initiative_scores:Dictionary,heroes:Dictionary,map:Dictionary,plans:Dictionary,ready:Array[String],rng:Dictionary,command_sequence,event_sequence,state_version,events:Array,commands:Array`. Phase string is `world`, `planning`, `initiative`, `cycle_1`, `cycle_2`, `bonus`, `resolution`. Player/hero IDs both `p1`..`p4`.

Hero record `{id,player_id,class_id,name,hp,max_hp,attack,defence,speed,move,hex,sanctuary,gold,power,fate,relics:Array,statuses:Dictionary,flags:Dictionary,controlled_locations:Array}`. Class IDs ranger, warlord, merchant, cultist in seat order. JSON data files provide stats and traits.

`scripts/domain/game_rules.gd`: `var state:GameState`, `new(seed:int=20260922)` creates game at round 1/world with full starting state; `static from_snapshot(data:Dictionary)` restores rules; `execute(command:Dictionary)->Dictionary` returns `{is_valid,reason_code,message,events:Array,state_version}`. `current_actor()->String` returns empty outside cycles. `legal_actions(player_id:String)->Dictionary` returns keys for legal commands, including `move:{targets:reachable}`, `capture:{...}`, `pass:{...}` in M1. `snapshot()->Dictionary`, `checksum()->String`. All events `{sequence,type,round,phase,actor_id,visibility:"public",data:Dictionary}`.

Commands M1: `advance` (world->planning, initiative->cycle_1, bonus->resolution, resolution->world); `submit_plan` with player_id and `plan:Dictionary`; `ready` with player_id; `move` with player_id and `target:String`; `capture`; `pass`. Ready all transitions planning->initiative and calculates scores; consuming all cycle_1 actors automatically enters cycle_2; consuming cycle_2 enters bonus. No bonus grants in M1; advance moves to resolution. `advance` at resolution grants income/recovery/fate, then enters world with incremented round. Plans and ready reset for next round. `events`/`commands` retained for replay; rejection returned and logged externally without mutating authoritative state. `expected_version` and `expected_phase` guards must work. `command_id` optional idempotency guard.

## Tools/tests (tooling owner)

`tests/run_tests.gd` extends SceneTree, preloads test suites; exits 1 on failed assertion. Generation owner writes `tests/unit/test_hex_map.gd`; rules owner writes `tests/unit/test_rules.gd`. Each suite exposes `run()->Array[String]` of errors; tooling integrates both and additional acceptance integration tests.

CLI and Playwright consume the exact contracts above. Root owns project config, scenes/presentation, web export and browser test implementation. Tooling owner owns CLI launcher, logging service, tests/run_tests.gd and integration/CLI tests, package.json initially, README and docs except DECISIONS/CONTRACTS.

## Milestone 2 extensions

The content version is `0.2.0-m2`. State adds `monsters`, `pending_combat`, `pending_reaction`, `pending_move`, `traps`, `commitments`, `ground_loot`, `cycle_2_modifiers`, and `next_cycle_order`. These are serializable data; `GameState.validation_errors` checks pending participant/phase/reference/calculation consistency before restoration.

Commands: `attack {player_id,target_id}`, `choose_stance {player_id,stance}`, `spend_fate {player_id}`, `decline_fate {player_id}`, `displace {player_id,target}`, `resolve_reaction {player_id,choice}`, `special {player_id,special_id,target?}`, `upgrade {player_id}`. `capture` begins or completes an Ancient commitment according to state. Planning supports `{initiative_push:true,snare:hex,prepared_hex:enemy_id}` for applicable classes/resources.

`legal_actions` returns attack targets keyed by hero/monster ID with `{hex,name,kind,hp,defence}`. Stance/reaction windows expose `choices`; displacement exposes `targets`; Special exposes a `choices` dictionary with `rest`/`forced_march` entries. Planning options expose `initiative_push`, `snare_targets`, and `prepared_hex_targets`. All clients must query legal actions for the decision owner, who may differ from the current scheduled actor.

Pending combat stages: `stances`, `fate_attacker`, `fate_defender`, `displacement`. Reaction kinds: `challenge`, `bribe_offer`, `bribe_response`. Reactions and combat preserve the underlying cycle and consume only the declared attack/move slot when its final resolution completes.

`Combat.evaluate` is pure arithmetic and returns full stat/stance/modifier/die totals and outcome fields. `battle_flow.gd` applies costs, damage, drops and recovery; `class_flow.gd` handles simultaneous preparation and interrupted paths. `SimpleBot.choose(rules)` proposes one ordinary command without mutating state.

## Milestone 3 extensions

Content version `0.3.0-m3` is the complete rules format. State adds `pending_exploration`, `world_effects`, `market_hex`, `victory_claims`, and `victory`; terminal phase is `victory`. The presentation/application version can advance without changing this content schema.

Commands: `trade {player_id,direction:gold_to_power|power_to_gold}`, `explore {player_id,use_fate?:bool}`, `choose_reward {player_id,choice:reward_id}`, `begin_ritual {player_id}`, `complete_ritual {player_id}`. `special.dark_bargain` is the Cultist exploration branch. Planning accepts `purchases:Array[String]`, at most three equipped items overall.

Legal Trade choices provide `cost_resource/cost/gain_resource/gain`. Explore provides `alternatives_available`, cost and reward odds. `choose_reward.choices` is a Dictionary keyed by reward ID, with display definitions as values. Planning `purchases` is a Dictionary keyed by upgrade ID with cost, effects and description; `slots` gives remaining equipment capacity. `victory_progress(player_id)` returns the Conquest, Dominion and Ascension tracks. Victory is `{winners:Array[String],route,round,shared,details}`.

`SnapshotStore.write/read` deals only with `user://` paths and validates a save envelope `{save_format:1,snapshot,metadata}`. Mode and human seat are metadata. Canonical domain checksums exclude metadata. CLI loaders understand both envelopes and raw snapshots. `SimpleBot.choose(rules, preferences={})` allows deterministic route preferences for test scenarios; ordinary Solo uses class goals and public information.

## Milestone 5 transport boundary

`NetworkSession` is a Node using its own `SceneMultiplayer` subtree and native ENet. Its methods are `host_game(port,seed)->Error`, `join_game(address,port,token="")->Error`, `start_match()->Dictionary`, `submit(command)->void`, and `disconnect_session()`. Signals: `observation_updated(view)`, `lobby_updated(lobby)`, `command_result(result)`, `connection_failed(message)`. Host-only `submit_as_host` is a local harness/bot entry point and is never an RPC.

The host owns `GameRules` and RNG. Clients submit a monotonic client sequence, expected state version and their own seat's command. Seat identity comes from the connection; payload identity cannot impersonate another player. Rejected requests are logged without changing authoritative game state. The host advances shared phases, drives bot seats and applies configurable safe timeout defaults.

An observation is `{player_id,state_version,state,legal_actions,victory_progress,public_checksum,view_checksum,started,lobby}`. `state` is a filtered view, **not a save**. It omits seed, RNG, command history, opponents' plans/preparations/hints, sealed opposing stances and undiscovered site/monster details. Site and Relic identifiers are normalized where their original IDs would reveal hidden content. Opposing plans are never sent merely for a UI to hide them. Each client verifies its view checksum; the public checksum is identical across different authorized views of the same version.

`RemoteRulesView` exposes read-only `state`, `legal_actions`, `current_actor`, `victory_progress`, `snapshot` and `checksum` for the existing presenter. It cannot execute rules or restore a match. Native Main routes commands through NetworkSession; the browser development bridge remains a local-game testing tool.

Reconnect tokens reserve and reclaim a disconnected human's seat while the host process remains alive. The host sends a fresh authorized observation. There is no host migration, Internet relay, account service or production matchmaking in this proof.
