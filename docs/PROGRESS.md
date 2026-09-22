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

## Milestone 2

In progress after Milestones 0–1 passed. No Milestone 3–5 completion is claimed.
