# Milestone acceptance

## Milestone 0 — passed

- Exact Godot 4.7.2 project imports and launches.
- Typed state/command/result/event definitions, independently seeded RNG streams, tested axial hex helpers.
- Minimal and full state JSON round trips preserve RNG continuation and checksums.
- Headless runner exits 0 for passing suites and 1 for an intentional failure.
- Rejected commands preserve authoritative state and RNG.

## Milestone 1 — passed

- 61 hexes, 16 locations, four sanctuaries and data-defined prototype classes.
- Native 3D board, roads, distinct heroes, ownership, camera controls and selected-hex details.
- Seven visible phases, stored simultaneous plans, initiative and two interleaved action cycles.
- Weighted path previews, legal Move and capture, income and capped Fate.
- Four-seat cards, action bar, journal, debug inspector, entered seed/regeneration.
- Scripted integration and Playwright complete three rounds, move all heroes, capture towers and receive income without duplicate actions.
- 100 required map seeds pass full validation; a separate 1,000-seed dispersed/negative sweep also passed.
- Playwright verified 1280×720 and 1920×1080. Screenshots and traces are saved to the OS temporary directory, outside Git.

## Verification at checkpoint

`npm test`: three Godot suites and two Node CLI tests passed. `npm run build:web`: export passed. `npm run test:e2e`: two Chromium tests passed. Parser errors are checked explicitly because Godot can sometimes return exit 0 while reporting an error.

## Milestone 2 — passed

- Adjacent hero/monster attacks, four sealed stances, d6 calculations, damage bands and displacement.
- Attacker/defender Fate windows, Planning initiative push, caps and once-per-round loss compensation.
- Snare, Challenge, Bribe, Prepared Hex, Forced March and Rest, with legal targets and explicit timing.
- All four classes can be downed and recover without losing a scheduled action or being eliminated.
- Ancient Tower begin/complete commitments, cancellation and tower upgrades.
- Three monster profiles and a shared deterministic bot policy.
- CLI aliases for every action/decision and filtered, readable JSONL diagnostics.
- Browser combat test submits both stances through private handoffs, verifies delayed reveal, rerolls the attacker die and resolves the defender window.
- A game authored through browser clicks replays through the native headless CLI to the identical checksum.

## Final validation

`npm test`: **6 Godot suites, 0 failures; 3 CLI tests, 0 failures**. The intentional failing assertion is checked by the CLI suite and correctly returns exit 1.

`npm run build:web` and `npm run test:e2e`: **3 Playwright tests passed**, Chromium at 1280×720 and 1920×1080; no relevant browser/script errors. Tests use the actual Godot web export and the standard Playwright fallback because the Browser plugin is unavailable.

Four-bot baseline, seed `20260922`: **20 rounds, 691 accepted commands, 160 scheduled actions, 79 combats, 23 captures, 5 upgrades, 4 down/recoveries and 2 monster defeats**. Five distinct pending decision stages survive JSON save/load; full replay matches `07047dcaa3e422f0d821b6c050d865ef81e2de4f8d74e0bc97a8749b2bdbe421`.

The Windows Desktop debug export launches with hardware OpenGL on NVIDIA RTX 4070 and exits cleanly after 90 frames. `build/windows/ShatteredRealm.exe` is a generated local artifact, excluded from Git. The native launch is a smoke test; the automated input flows run in Playwright.

## Remaining scope and next playable task

No remaining failing check is known for Milestones 0–2. No Milestone 3–5 completion is claimed. There is no match winner yet: settlement interactions, Trade, Ruins/exploration, world events, victory routes, remaining upgrade/class content, a save/load menu and multiplayer remain later work. CLI persistence and snapshot export already work.

Next smallest playable task: implement Settlement Capture and Trade with road-network validation, then extend the same action/event loop toward Milestone 3's public victory claims.
