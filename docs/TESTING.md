# Tests and developer commands

## Prerequisites and checks

Use Godot **4.7.2 stable Standard**, Node.js 20+, and `npm install`. Set `GODOT_BIN` if the pinned engine is not on PATH. The script launcher verifies the exact stable version prefix before running. The install hook creates `node_modules/.gdignore` so Godot does not import development dependencies.

```powershell
npm run check
npm run test:headless
npm run test:cli
npm run test:network
npm run test:network-ui
npm test
npm run test:headless -- --suite bots
```

Direct engine invocation is also supported:

```powershell
Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tests/run_tests.gd
```

No Godot test addon is required. Each suite returns failure messages, and the runner prints a summary and exits 0 on success or 1 on any failure. Optional suite IDs are `hex`, `rules`, `combat`, `milestone2`, `milestone3`, `content`, `network`, `persistence`, `acceptance`, `bots`, `victory_routes`, and `complete_matches`. Long suites stream progress by seed. Verify the deliberate failure path with the following command; **exit 1 is expected**:

```powershell
npm run test:headless -- --suite combat --self-test-failure
```

## Coverage

| Suite | Behavioral evidence |
|---|---|
| `tests/unit/test_hex_map.gd` | Axial/cube/world conversion, ranges/rings, independent RNG streams, terrain/road/occupancy movement, 100 generated seeds and fairness diagnostics |
| `tests/unit/test_rules.gd` | Rules commands, initiative/ties, cycle scheduling, capture/income, serialization and rejected input |
| `tests/unit/test_combat.gd` | All sixteen stance pairings, outcome margins, ties, Guard/Counter/Trick/Assault effects, modifiers, monsters and arithmetic purity |
| `tests/unit/test_milestone2.gd` | Ordered private stances and Fate, Bribe/Prepared Hex, all-class down/recovery, displacement, monster rewards, Rest, Ancient commitments/cancellation, upgrades, simultaneous plans, Snare, Challenge and Forced March |
| `tests/unit/test_milestone3.gd` | Trade/networks/purchases, class Fate triggers, claims before/after income, immediate cancellation, ritual completion/cancellation and shared victories |
| `tests/unit/test_content.gd` | Five world events and expiry, four Relic sources, seeded reward alternatives, Dark Bargain, exploration affinity, hints and equipment effects |
| `tests/unit/test_persistence.gd` | Atomic envelope saves, backup rotation, metadata and schema validation |
| `tests/unit/test_network.gd` | Authorized projections/checksums/private history, command gate purity, independent per-seat deadlines and safe defaults |
| `tests/integration/test_acceptance.gd` | All seven phases across three rounds, every hero moves, capture and exact income, no duplicate scheduled actions, seed regeneration, full replay/event equivalence, JSON restore and RNG continuation before every command |
| `tests/integration/test_bots.gd` | Four bots reach twenty rounds or legitimate earlier victory, with no lost/duplicate scheduled actions, legal deterministic policy, pending-decision save/load, RNG continuation and replay |
| `tests/integration/test_victory_routes.gd` | Each of the three victory routes from a fresh generated game using only legal commands; other seats legally Pass, with no injected resources or winner |
| `tests/integration/test_complete_matches.gd` | Twenty-five fresh matches with four active bots, real victories within forty rounds, replay/JSON checksums and a persisted seed/route/resource report |
| `tests/integration/cli.test.mjs` | Real headless process adapter, persisted state and backup, all conflict command aliases, rejected command purity, command file input, three-round simulation, replay checksum, filtered JSONL logs and process exit status |
| `tests/integration/network.test.mjs` | Real ENet host and two separate native clients, seeded checksums, remote Move/full combat, sealed plan/stance packets, forged-seat/stale-version/stale-sequence purity, planning/reaction timeouts, reconnect snapshot and sequence continuation, detailed host audit |
| `tests/presentation/network_ui_smoke.gd` | Actual native Main/lobby/read-only adapter in three processes, multiplayer phase and action controls, permissions, rendered heroes and filtered state |
| `tests/browser/` | Real Godot web export, UI interaction and layout smoke checks through Playwright |

The complete-match report is written to `artifacts/bot_matches.json`. The Milestone 3 run completed all 25 seeds (1–25), with a median of 6 rounds: 15 Ascension, 10 Dominion, and no stalls (maximum 12 rounds). Every round restores canonical JSON before continuing, and every completed match independently replays its accepted history. These are regression results from a simple deterministic policy, not a balance or match-length claim. The separate fresh-game proofs reached Conquest in round 7, Dominion in round 6, and Ascension in round 5 for seed `20260922`.

The native network acceptance report is `artifacts/network_acceptance.json`; captured recipient observations/results are `artifacts/network_peer_*.jsonl`. Reconnect tokens are redacted from exported test journals. The test starts fresh seed `20260922`, moves remote heroes using reported legal targets, and resolves a real player duel without modifying authoritative state. Timeouts use the service's deterministic elapsed-time tick. `npm test` runs the headless, CLI and native network acceptance suites. `test:network-ui` separately loads the native presentation, while Playwright verifies the browser export.

## CLI playbook

```powershell
npm run cli -- new --seed 20260922
npm run cli -- advance
npm run cli -- plan p1 '{}'
npm run cli -- ready p1
npm run cli -- ready p2
npm run cli -- ready p3
npm run cli -- ready p4
npm run cli -- advance
npm run cli -- state
npm run cli -- legal
```

Use the actor and targets reported by `state` and `legal`. Replace the example player and target below with those legal values:

```powershell
npm run cli -- move p1 0,1
npm run cli -- capture p1
npm run cli -- pass p1
npm run cli -- attack p1 p2
npm run cli -- stance p1 assault
npm run cli -- fate p1
npm run cli -- decline-fate p2
npm run cli -- displace p2 0,1
npm run cli -- reaction p3 decline
npm run cli -- forced-march p2 0,1
npm run cli -- rest p1
npm run cli -- upgrade p1
npm run cli -- trade p3 power_to_gold
npm run cli -- explore p1 --use-fate
npm run cli -- reward p1 gold_cache
npm run cli -- purchase p1 iron_weapon
npm run cli -- dark-bargain p4
npm run cli -- begin-ritual p1
npm run cli -- complete-ritual p1
npm run cli -- progress
```

These are command forms, not a single universally legal sequence. Use `legal PLAYER` for each eligible participant when a reaction/combat window is open; the scheduled actor may be waiting on another player. `capture` acts on the current tower, automatically beginning/completing Ancient commitments. Neutral Minor capture is automatic; an enemy-owned Minor Tower uses the documented contest roll. `advance` cannot bypass Planning, a player's action, or a pending decision. Rejections print a reason code and return exit 2 without changing the saved state.

Planning uses one JSON object, applying it when all four seats are ready. A Ranger example is `{"type":"submit_plan","player_id":"p1","plan":{"snare":"0,1","initiative_push":true}}`; Cultist uses `prepared_hex: "p2"`. Add `purchases: ["iron_weapon"]` when controlling a Settlement with sufficient Gold and equipment slots. The `purchase` convenience alias submits a purchases-only plan, replacing any prior unready plan; use the JSON form to combine purchases and preparation. Only choose targets returned by `legal` and spend available resources. Submit through `command --file` for reliable shell quoting.

Every command is also available as a JSON object. A command file avoids shell-specific quoting:

```json
{ "type": "move", "player_id": "p1", "target": "0,1", "expected_version": 6, "expected_phase": "cycle_1", "command_id": "my-unique-command" }
```

```powershell
npm run cli -- command --file command.json
npm run cli -- advance --expected-version 0 --expected-phase world --command-id start-round
```

Versions are obtained from `state`; stale versions and duplicate IDs are rejected. A generic `command` adapter ensures future domain actions remain accessible without implementing separate JavaScript game logic. Aliases map `stance` to `choose_stance`, `fate` to `spend_fate`, `decline-fate` to `decline_fate`, `reaction` to `resolve_reaction`, `reward` to `choose_reward`, and `rest`/`forced-march`/`dark-bargain` to `special`. Ritual aliases use the corresponding underscored command names. Canonical command names are also accepted. `progress [PLAYER]` reads victory tracks and public claims without changing state or RNG.

## Reproduction and map validation

```powershell
npm run cli -- new --seed 20260922 --state .realm/repro.json
npm run cli -- simulate --rounds 40 --state .realm/repro.json
npm run cli -- replay --state .realm/repro.json
npm run cli -- validate-map --seed 1 --count 100 --json
npm run cli -- state --state .realm/repro.json --json
npm run cli -- bot-step --state .realm/repro.json
```

Simulation stops on `stop_reason: victory` or the configured round limit. Normal matches have no round cap; the complete-match acceptance harness uses forty rounds and labels unfinished games `stalled_round_limit`. All four seats share the deterministic `SimpleBot` policy: resolve owned decision windows, finish commitments, plan legal preparations/purchases, heal, pursue public victory goals, and interfere with reachable threats. Warlord pursues Conquest, Merchant pursues Dominion, and Ranger/Cultist pursue Relics and Ascension. Discovery frontiers reveal unknown opportunities without consulting hidden location details. Low-health heroes use Guard; others use Assault. Dice of 1–2 are rerolled. Challenge is accepted; Bribe is offered/accepted at half Health or less. Opponents' sealed plans/stances are not consulted. Rejected commands, invalid combat calculations and a 120-command-per-round guard fail the run.

Full CLI audit recording takes longer than rules-only simulation tests because it computes before/after hashes of complete history for every action. `simulate` reports action/event counts, the actual victory result, and final checksum; `replay` independently confirms accepted history. Run all complete-match proofs with `npm run test:headless -- --suite victory_routes` and the 25-game sample with `npm run test:headless -- --suite complete_matches`.

CLI saves default to `.realm/state.json`, backups to `.realm/state.json.bak`, and logs to `.realm/state.actions.jsonl`. A per-save `.lock` prevents concurrent writers. CLI also accepts the UI's `save_format: 1` envelope and preserves its metadata on continuation. Read-only queries and replay do not rewrite the save. Tools exit 1 for bad files, invalid map generation, parser/runtime failures, or engine discovery errors.

## Action diagnostics

```powershell
npm run cli -- logs --limit 20
npm run cli -- logs --limit 1000 --json
npm run cli -- logs --event CombatResolved --limit 5
npm run cli -- logs --actor p2 --limit 20
npm run cli -- logs --rejected
```

Readable output groups command status, actor, round/phase, decision-window stage, state versions and before/after hashes with the emitted event sequence. JSONL retains the full submitted command, rejection reason, source (`ui`, `cli`, or `bot`), UTC timestamp, elapsed microseconds, before/after RNG snapshots, and full event payloads including combat calculations. Actor/event/rejection filters make individual interactions easy to inspect. Native UI uses the same logger under Godot's `user://logs/` directory and displays recent events in the HUD.

For a reproducible bug, retain the seed, save, command JSON and relevant action-log lines. Compare before/after checksums: rejected actions must have identical hashes. `replay` checks accepted history against the final saved checksum; timestamp and duration metadata never affect replay.

## Native host/join from the terminal

Run each long-lived peer in a separate terminal; these invoke the same `NetworkSession` service as the native UI:

```powershell
npm run net -- host --port 24567 --seed 20260922 --session .realm/host
npm run net -- join --address 127.0.0.1 --port 24567 --session .realm/p2
npm run net -- join --address 127.0.0.1 --port 24567 --session .realm/p3
```

Enter `{"op":"start"}` in the host terminal. Each client accepts one ordinary command JSON per line, for example `{"type":"ready"}`; its own player ID, sequence and state version are supplied automatically. Host automatically advances public phases and drives bot seats. `--manual` disables automatic phase/bot actions for controlled experiments. Outside the peer terminals:

```powershell
npm run net -- send --session .realm/host --op start
npm run net -- send --session .realm/p2 --command '{"type":"ready","player_id":"p2"}'
npm run net -- inspect --session .realm/p2
npm run net -- logs --session .realm/host --limit 20
npm run net -- logs --session .realm/p2 --json
npm run net -- join --address 127.0.0.1 --port 24567 --token TOKEN --session .realm/p2-reconnected
```

Use either start method once. `inspect` exposes only that seat's authorized observation and legal options. Reconnect uses the token stored in that client's `credentials.json`; the host must still be running. `network.jsonl` records local observation/result delivery and control requests, `observation.json` retains the latest authorized view, and the host's `actions.jsonl` contains the complete authoritative audit including protocol rejections. `send --file request.json` accepts an explicit control request such as `{"op":"submit","command":{"type":"move","target":"0,1"}}`. `--host` and `--join` also work as mode aliases. Ctrl+C closes a terminal peer.

The native proof uses direct-address UDP/ENet. Browser networking, matchmaking, NAT traversal, accounts and host migration are outside scope. Client observations intentionally omit the authoritative seed/RNG/history and cannot be loaded as game saves.

## Browser checks

Install matching Godot export templates, then:

```powershell
npx playwright install chromium
npm run build:web
npm run test:e2e
```

For manual browser play, `npm run serve:web` serves the generated build locally. Browser tests use the development command bridge into the exported Godot engine, alongside real rendered input. JavaScript does not reimplement the game model.
