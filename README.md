# Shattered Realm

A deterministic four-seat local board-game prototype built from [the master specification](shattered_realm_codex_master_spec.md). The complete local loop covers **Milestones 0–3**: seeded hex board, simultaneous planning, initiative, two action cycles, combat, Fate, class abilities, exploration, settlement economy, equipment, world events, and three visible victory routes.

Conquest and Dominion claims must survive a response round; Ascension requires a public two-action ritual. Twenty-five deterministic four-bot matches finish through the real command pipeline, and each victory route has a separate fresh-game command proof. Presentation polish and the network proof follow the local-game checkpoint.

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

An optional local Windows build is available at `build/windows/ShatteredRealm.exe`; double-click it to play without opening the editor. Generated builds are ignored by Git. Rebuild it with the matching export templates installed:

```powershell
Godot_v4.7.2-stable_win64_console.exe --headless --path . --export-debug "Windows Desktop" build/windows/ShatteredRealm.exe
```

The game uses primitive 3D terrain, roads, landmarks and heroes; no art downloads or Godot addons are needed. Compatibility rendering supports desktop and the browser smoke build. Enter a seed, choose local control or one human with three bots, submit preparations/purchases, ready the seats, reveal initiative, and act through both cycles. Combat opens participant stance and Fate windows; eligible reactions prompt their owner. Watch public victory claims and rituals. Manual save/load and rotating autosave retain pending decisions and RNG.

## Exercise the actual rules from a terminal

```powershell
npm run cli -- new --seed 20260922
npm run cli -- simulate --rounds 3
npm run cli -- state
npm run cli -- replay
npm run cli -- logs --limit 10
npm run cli -- validate-map --seed 1 --count 100
npm run cli -- simulate --rounds 20
npm run cli -- logs --event CombatResolved --limit 5
npm run cli -- new --seed 20260922 --state .realm/complete.json
npm run cli -- simulate --rounds 40 --state .realm/complete.json
```

Every implemented action and decision has a CLI command, including `trade`, `explore`, `reward`, `purchase`, `dark-bargain`, `begin-ritual`, and `complete-ritual`. `legal p1` reports authoritative targets and choices. `command --file command.json` accepts any shared command object, including version/phase guards and command IDs. `bot-step` submits one deterministic bot choice. See `npm run cli -- help` and [testing documentation](docs/TESTING.md) for all aliases. CLI saves default to `.realm/state.json`; use `--state FILE` for independent matches.

UI, CLI, scripted simulation, tests, and replay call the same GDScript rules. No game rules are duplicated in JavaScript.

## Verify

```powershell
npm run check
npm test
npm run build:web
npm run test:e2e
```

The browser build needs the matching Godot export templates. Install Playwright's browser once with `npx playwright install chromium`. Test artifacts and generated builds are ignored by Git.

Headless checks cover 100 map seeds, movement/income acceptance, all sixteen stance pairings, combat/Fate/reaction timing, recovery, tower commitments, equipment/economy, victory response windows, and 25 complete four-bot matches. Replay and JSON continuation compare state, events and RNG, including pending decisions. CLI tests verify persistence, all action aliases, structured logs, process status, and the test runner's intentional failure path. Browser tests exercise the actual exported Godot game. Detailed simulation results are written to `artifacts/bot_matches.json`.

## Project guide

- [Implemented player rules](docs/RULES.md)
- [Architecture and save/replay boundaries](docs/ARCHITECTURE.md)
- [Tests, CLI and debugging](docs/TESTING.md)
- [Decisions and prototype assumptions](docs/DECISIONS.md)
- [Component interface contracts](docs/CONTRACTS.md)
- [Asset attribution](ATTRIBUTION.md)
