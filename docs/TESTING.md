# Tests and developer commands

## Prerequisites and checks

Use Godot **4.7.2 stable Standard**, Node.js 20+, and `npm install`. Set `GODOT_BIN` if the pinned engine is not on PATH. The script launcher verifies the exact stable version prefix before running. The install hook creates `node_modules/.gdignore` so Godot does not import development dependencies.

```powershell
npm run check
npm run test:headless
npm run test:cli
npm test
npm run test:headless -- --suite bots
```

Direct engine invocation is also supported:

```powershell
Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tests/run_tests.gd
```

No Godot test addon is required. Each suite returns failure messages, and the runner prints a summary and exits 0 on success or 1 on any failure. Optional suite IDs are `hex`, `rules`, `combat`, `milestone2`, `acceptance`, and `bots`. Verify the deliberate failure path with the following command; **exit 1 is expected**:

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
| `tests/integration/test_acceptance.gd` | All seven phases across three rounds, every hero moves, capture and exact income, no duplicate scheduled actions, seed regeneration, full replay/event equivalence, JSON restore and RNG continuation before every command |
| `tests/integration/test_bots.gd` | Twenty rounds with four bots, 160 scheduled actions, legal deterministic policy, combat/capture, pending-decision save/load, RNG continuation and accepted-command replay |
| `tests/integration/cli.test.mjs` | Real headless process adapter, persisted state and backup, all conflict command aliases, rejected command purity, command file input, three-round simulation, replay checksum, filtered JSONL logs and process exit status |
| `tests/browser/` | Real Godot web export, UI interaction and layout smoke checks through Playwright |

Victory routes, exploration, settlement economy, and complete-match bot win tests belong to Milestone 3 and are not claimed by this coverage.

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
```

These are command forms, not a single universally legal sequence. Use `legal PLAYER` for each eligible participant when a reaction/combat window is open; the scheduled actor may be waiting on another player. `capture` acts on the current tower, automatically beginning/completing Ancient commitments. Neutral Minor capture is automatic; an enemy-owned Minor Tower uses the documented contest roll. `advance` cannot bypass Planning, a player's action, or a pending decision. Rejections print a reason code and return exit 2 without changing the saved state.

Planning uses one JSON object, applying it when all four seats are ready. A Ranger example is `{"type":"submit_plan","player_id":"p1","plan":{"snare":"0,1","initiative_push":true}}`; Cultist uses `prepared_hex: "p2"`. Only choose targets returned by `legal` and spend available resources. Submit through `command --file` for reliable shell quoting.

Every command is also available as a JSON object. A command file avoids shell-specific quoting:

```json
{ "type": "move", "player_id": "p1", "target": "0,1", "expected_version": 6, "expected_phase": "cycle_1", "command_id": "my-unique-command" }
```

```powershell
npm run cli -- command --file command.json
npm run cli -- advance --expected-version 0 --expected-phase world --command-id start-round
```

Versions are obtained from `state`; stale versions and duplicate IDs are rejected. A generic `command` adapter ensures future domain actions remain accessible without implementing separate JavaScript game logic. Aliases map `stance` to `choose_stance`, `fate` to `spend_fate`, `decline-fate` to `decline_fate`, `reaction` to `resolve_reaction`, and `rest`/`forced-march` to `special`. Canonical command names are also accepted. `special p2 forced_march HEX` is the longer equivalent.

## Reproduction and map validation

```powershell
npm run cli -- new --seed 20260922 --state .realm/repro.json
npm run cli -- simulate --rounds 20 --state .realm/repro.json
npm run cli -- replay --state .realm/repro.json
npm run cli -- validate-map --seed 1 --count 100 --json
npm run cli -- state --state .realm/repro.json --json
npm run cli -- bot-step --state .realm/repro.json
```

Simulation stops at the configured round count with `stop_reason: configured_round_limit`; it is not a complete-match victory simulation. All four seats share the deterministic `SimpleBot` policy: resolve owned decision windows, plan legal class preparations, heal, capture/upgrade, attack legal targets, and move toward discovered strategic locations. Low-health heroes use Guard; others use Assault. Reroll dice of 1–2. Challenge is accepted; Bribe is offered/accepted when the relevant hero is at half Health or less. Opponents' sealed plans/stances are not consulted. The simulation fails on rejected commands, invalid combat calculations, or a 120-command-per-round guard.

The twenty-round seed `20260922` acceptance run exercises movement, towers, combat, recovery, class effects, monster rewards and upgrades; exact counts can change as data is tuned. Full CLI audit recording takes longer than the headless rules-only bot suite because it computes before/after hashes of complete history for every action. `simulate` reports action/event counts and the final checksum; `replay` independently confirms accepted history.

CLI saves default to `.realm/state.json`, backups to `.realm/state.json.bak`, and logs to `.realm/state.actions.jsonl`. A per-save `.lock` prevents concurrent writers. Read-only queries and replay do not rewrite the save. Tools exit 1 for bad files, invalid map generation, parser/runtime failures, or engine discovery errors.

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

## Browser checks

Install matching Godot export templates, then:

```powershell
npx playwright install chromium
npm run build:web
npm run test:e2e
```

For manual browser play, `npm run serve:web` serves the generated build locally. Browser tests use the development command bridge into the exported Godot engine, alongside real rendered input. JavaScript does not reimplement the game model.
