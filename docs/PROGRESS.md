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

## Milestone 2 validation checkpoint (historical)

`npm test`: **6 Godot suites, 0 failures; 3 CLI tests, 0 failures**. The intentional failing assertion is checked by the CLI suite and correctly returns exit 1.

`npm run build:web` and `npm run test:e2e`: **3 Playwright tests passed**, Chromium at 1280×720 and 1920×1080; no relevant browser/script errors. Tests use the actual Godot web export and the standard Playwright fallback because the Browser plugin is unavailable.

Four-bot baseline, seed `20260922`: **20 rounds, 691 accepted commands, 160 scheduled actions, 79 combats, 23 captures, 5 upgrades, 4 down/recoveries and 2 monster defeats**. Five distinct pending decision stages survive JSON save/load; full replay matches `07047dcaa3e422f0d821b6c050d865ef81e2de4f8d74e0bc97a8749b2bdbe421`.

The Windows Desktop debug export launches with hardware OpenGL on NVIDIA RTX 4070 and exits cleanly after 90 frames. `build/windows/ShatteredRealm.exe` is a generated local artifact, excluded from Git. The native launch is a smoke test; the automated input flows run in Playwright.

## Milestone 3 — complete local rules and match flow

- Settlements, road networks, Trade, Ruins, rewards, Relics, five world events and all eight equipment upgrades.
- Conquest and Dominion claims with a full response round; Ascension's two-action ritual; immediate invalidation when requirements are lost.
- Fresh-game headless proofs for all three routes use only normal commands. No winner or starting resource is injected.
- Final 25-seed complete-match run: **25 finished, median 6 rounds, maximum 12; Ascension 15, Dominion 10, Conquest 0**. Every round boundary is JSON-restored; all final states replay to identical checksums. The separate Conquest proof finishes in round 7. A cross-process Cursed Ground event ordering mismatch was caught and fixed before acceptance.
- Actual Godot browser rendering reaches the final victory screen through each route: Conquest round 7, Dominion round 6, Ascension round 5.
- Menu modes include solo with a selected human hero and three bots, sandbox and private hotseat. Playwright verifies the human seat does not act automatically.
- Validated manual saves, round autosaves, rotating backup, saved mode/seat, and CLI interoperability. Settings and sound cues are outside the deterministic state.

## Milestone 4 — presentation and usability

- Cohesive procedural terrain, landmarks, faction banners, distinct monsters, Relic carriers and separate capture/ritual markers. Bridge closures, cursed terrain, leylines, markets and ground loot update with the domain state.
- Larger default board framing, cached meshes/materials and selective reconciliation; movement follows authorized paths and respects motion/speed preferences.
- Phase, initiative, legal actions, resources and victory threats are visible without the inspector. Glossary, tooltips, first-round hints, private handoffs and a final victory screen are implemented.
- Persistent Master/Music/SFX/UI volume, generated cues with text equivalents, reduced motion, animation speed and interface scale. The Music bus intentionally has no soundtrack.
- Actual native 1080p GPU profiling and scoped measurements are documented in `docs/PERFORMANCE.md`. Chromium uses software SwiftShader for layout/interaction testing; its frame rate is reported separately.

## Milestone 5 — native ENet proof

- Graphical Online host/join lobby and terminal equivalents; host-only simulation, phase advancement and RNG; unclaimed seats run bots.
- Private plans, sealed stances, undiscovered details, encoded source identifiers and RNG/seed/history are filtered before transport. The presenter uses a read-only authorized-view adapter.
- Seat authorization, ordered client sequences, state versions, public and per-view checksums, complete server diagnostics, safe timeouts and token-based reconnect.
- Real separate-process host plus two clients verify remote Move and combat, private payloads, rejected-command purity, Planning/reaction deadlines and reconnect continuation.
- Three actual Main scenes also run through round three together, with the right viewer and actions for each seat. This checks the graphical lobby callbacks and presenter against the same service.
- Defaults: 60-second Planning and 20-second action/reaction deadlines. Reconnect requires the original host process to remain alive.

## Final verification

`npm test`: **12 Godot suites, 3 CLI tests and native ENet acceptance pass**, including the 100-seed map check and 25 completed matches. `npm run test:network-ui` passes for three native game scenes. **Nine Playwright scenarios pass** using the actual Godot web export at 1280×720 and 1920×1080; screenshots/traces live in the OS temporary directory. Save/restore, persisted settings, Solo, hotseat privacy, camera, movement, combat, every victory route and one full match with all four seats actively competing are exercised. The final handoff-perspective fix has a targeted combat regression; explicit JSON state versions have native transport regressions.

Both Web and Windows Desktop exports build. `build/windows/ShatteredRealm.exe` launches on the available NVIDIA RTX 4070 and exits cleanly. Generated binaries, reports and logs remain outside Git; source, reproducible tools and tests are committed.

Milestones 0–5 are implemented. This remains the specified prototype: placeholder artwork, direct-address native multiplayer, no account/matchmaking/relay service or host migration. An independent human usability session and WAN/NAT testing have not been performed; local UI behavior, rendering and loopback multiplayer have automated evidence.
