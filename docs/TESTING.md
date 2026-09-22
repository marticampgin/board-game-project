# Tests and developer commands

## Prerequisites and checks

Use Godot **4.7.2 stable Standard**, Node.js 20+, and `npm install`. Set `GODOT_BIN` if the pinned engine is not on PATH. The script launcher verifies the exact stable version prefix before running.

```powershell
npm run check
npm run test:headless
npm run test:cli
npm test
```

Direct engine invocation is also supported:

```powershell
Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tests/run_tests.gd
```

No Godot test addon is required. Each suite returns failure messages, and the runner prints a summary and exits 0 on success or 1 on any failure. Verify the deliberate failure path with the following command; **exit 1 is expected**:

```powershell
npm run test:headless -- --self-test-failure
```

## Coverage

| Suite | Behavioral evidence |
|---|---|
| `tests/unit/test_hex_map.gd` | Axial/cube/world conversion, ranges/rings, independent RNG streams, terrain/road/occupancy movement, 100 generated seeds and fairness diagnostics |
| `tests/unit/test_rules.gd` | Rules commands, initiative/ties, cycle scheduling, capture/income, serialization and rejected input |
| `tests/integration/test_acceptance.gd` | All seven phases across three rounds, every hero moves, capture and exact income, no duplicate scheduled actions, seed regeneration, full replay/event equivalence, JSON restore and RNG continuation before every command |
| `tests/integration/cli.test.mjs` | Real headless process adapter, persisted state and backup, rejected command purity, command file input, three-round simulation, replay checksum, JSONL logging and process exit status |
| `tests/browser/` | Real Godot web export, UI interaction and layout smoke checks through Playwright |

Combat, class timing, Ancient Tower commitments, victory routes, and complete-match bot win tests belong to later milestones and are not claimed by this coverage.

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
```

`capture` works when the current hero stands on a capturable Minor Tower. Neutral capture is automatic; an enemy-owned tower uses the documented contest roll. `advance` cannot bypass Planning or a player's action. Rejections print a reason code and return exit 2 without changing the saved state.

Every command is also available as a JSON object. A command file avoids shell-specific quoting:

```json
{ "type": "move", "player_id": "p1", "target": "0,1", "expected_version": 6, "expected_phase": "cycle_1", "command_id": "my-unique-command" }
```

```powershell
npm run cli -- command --file command.json
npm run cli -- advance --expected-version 0 --expected-phase world --command-id start-round
```

Versions are obtained from `state`; stale versions and duplicate IDs are rejected. A generic `command` adapter ensures future domain actions remain accessible without implementing separate JavaScript game logic. Implemented action aliases are `advance`, `plan`/`submit_plan`, `ready`, `move`, `capture`, and `pass`.

## Reproduction and map validation

```powershell
npm run cli -- new --seed 20260922 --state .realm/repro.json
npm run cli -- simulate --rounds 3 --state .realm/repro.json
npm run cli -- replay --state .realm/repro.json
npm run cli -- validate-map --seed 1 --count 100 --json
npm run cli -- state --state .realm/repro.json --json
```

Simulation stops at the configured round count with `stop_reason: configured_round_limit`; this is a round-rhythm smoke bot, not a complete-match victory simulation. It captures towers where legal and otherwise selects reachable movement toward neutral towers. It fails immediately on a rejected command or bounded-loop exhaustion.

CLI saves default to `.realm/state.json`, backups to `.realm/state.json.bak`, and logs to `.realm/state.actions.jsonl`. A per-save `.lock` prevents concurrent writers. Read-only queries and replay do not rewrite the save. Tools exit 1 for bad files, invalid map generation, parser/runtime failures, or engine discovery errors.

## Action diagnostics

```powershell
npm run cli -- logs --limit 20
npm run cli -- logs --limit 1000 --json
```

Readable output groups command status, actor, round/phase, state versions and before/after hashes with the emitted event sequence. JSONL retains the full submitted command, rejection reason, source (`ui`, `cli`, or `bot`), UTC timestamp, elapsed microseconds, before/after RNG snapshots, and full event payloads. Native UI uses the same logger under Godot's `user://logs/` directory and displays recent events in the HUD.

For a reproducible bug, retain the seed, save, command JSON and relevant action-log lines. Compare before/after checksums: rejected actions must have identical hashes. `replay` checks accepted history against the final saved checksum; timestamp and duration metadata never affect replay.

## Browser checks

Install matching Godot export templates, then:

```powershell
npx playwright install chromium
npm run build:web
npm run test:e2e
```

For manual browser play, `npm run serve:web` serves the generated build locally. Browser tests use the development command bridge into the exported Godot engine, alongside real rendered input. JavaScript does not reimplement the game model.
