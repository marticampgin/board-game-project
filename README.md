# Shattered Realm

A deterministic four-seat local board-game prototype built from [the master specification](shattered_realm_codex_master_spec.md). The current playable scope is **Milestones 0 and 1**: seeded hex board, planning, initiative, two action cycles, movement, neutral Minor Tower capture, income, discovery, and inspectable command/event history.

Combat, Ancient Tower commitments, class actions, upgrades, exploration, victory routes, and online multiplayer remain later milestones. The current slice can play successive rounds; it does not declare a match winner.

## Run

Use **Godot 4.7.2 stable Standard** (`4.7.2.stable.official.ed1daf0bf`) and Node.js 20 or newer. Open `project.godot` in Godot and press F5, or:

```powershell
npm install
npm start
```

The tools find `Godot_v4.7.2-stable_win64_console.exe`, `godot`, or `godot4` on PATH. To select the engine explicitly:

```powershell
$env:GODOT_BIN = 'C:\path\to\Godot_v4.7.2-stable_win64_console.exe'
```

The game uses primitive 3D terrain, roads, landmarks and heroes; no art downloads or Godot addons are needed. Compatibility rendering supports desktop and the browser smoke build. Enter a seed, advance World into Planning, ready all four seats, reveal initiative, and move/capture/pass through both cycles. Complete Bonus and Resolution to receive income and start the next round. The local development interface controls every seat.

## Exercise the actual rules from a terminal

```powershell
npm run cli -- new --seed 20260922
npm run cli -- simulate --rounds 3
npm run cli -- state
npm run cli -- replay
npm run cli -- logs --limit 10
npm run cli -- validate-map --seed 1 --count 100
```

Every implemented action has an alias: `advance`, `plan`, `ready`, `move`, `capture`, and `pass`. `legal p1` reports authoritative targets and movement paths. `command --file command.json` accepts any shared command object, including version/phase guards and command IDs. See `npm run cli -- help` and [testing documentation](docs/TESTING.md) for examples. CLI saves default to `.realm/state.json`; use `--state FILE` for independent matches.

UI, CLI, scripted simulation, tests, and replay call the same GDScript rules. No game rules are duplicated in JavaScript.

## Verify

```powershell
npm run check
npm test
npm run build:web
npm run test:e2e
```

The browser build needs the matching Godot export templates. Install Playwright's browser once with `npx playwright install chromium`. Test artifacts and generated builds are ignored by Git.

Headless checks cover 100 map seeds, weighted movement, all seven phase types, three complete rounds, every hero moving, tower income, deterministic replay, JSON saves and RNG continuation, and rejected-command purity. CLI tests verify atomic persistence, structured logs, readable queries, process status, and the test runner's intentional failure path. Browser tests exercise the actual exported Godot game.

## Project guide

- [Implemented player rules](docs/RULES.md)
- [Architecture and save/replay boundaries](docs/ARCHITECTURE.md)
- [Tests, CLI and debugging](docs/TESTING.md)
- [Decisions and prototype assumptions](docs/DECISIONS.md)
- [Component interface contracts](docs/CONTRACTS.md)
- [Asset attribution](ATTRIBUTION.md)
