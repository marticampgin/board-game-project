# Implementation decisions

The master specification is authoritative. LOCKED choices are requirements; PROTOTYPE DEFAULT values are editable data; DEFERRED systems are not implied by scaffolding; OPEN choices use the documented fallback.

## Scope

Complete Milestones 0 and 1 first, validate them, then extend to Milestone 2 if feasible. Milestones 3–5 (complete victory loop, full content, polish and multiplayer) are not part of the initial completion claim.

## Engine and presentation

- Godot **4.7.2.stable.official.ed1daf0bf**, Standard, statically typed GDScript. The exact binary and export templates were found installed.
- Procedural meshes and native Godot Controls implement the tabletop presentation; no external art or addons are needed.
- Compatibility rendering is selected for reproducible desktop and WebGL smoke tests. The scene uses standard 3D materials/lights and can switch to Forward+; renderer choice does not affect rules. This is a documented deviation from the spec's desktop Forward+ default.
- Playwright exercises the actual Godot web export. A development-only JavaScript bridge exposes snapshots and the shared command boundary; it does not implement a second game engine. Browser plugin is not available.

## Architecture and deterministic data

- Domain classes extend RefCounted. Runtime collections use JSON-safe dictionaries behind a typed GameState wrapper, stable string IDs, and string axial keys `q,r`.
- The command interface accepts `type`, `player_id`, optional `expected_version` and `expected_phase`, and action-specific choices. All clients use this boundary. Invalid commands must leave state and RNG unchanged.
- Phase transitions between actionable phases are explicit `advance` commands. The phase itself remains visible and serializable for inspection; this also makes every phase testable.
- All four seats are controlled locally in the development slice. Submitted plans resolve together once all four players are ready.
- Replays/checksums exclude wall-clock metadata; logs may attach elapsed timestamps outside authoritative state.

## Map fairness and capture defaults

- Generation allows eight attempts and one bounded repair. Early opportunity weights count capturable sites within cost 6, exploration/combat within cost 8 and useful road access within cost 1; `(max-min)/min` must not exceed 25%. The long-distance validation heuristic prices Swamp at 3; actual Move always stops on entering Swamp.
- The validator also removes each noncentral tower from the travel graph in turn to ensure one early tower cannot seal off the Worldspire.
- A contested unoccupied Minor Tower uses Attack + combat d6 strictly greater than base Defence 4 plus level and trait modifiers. Ties hold. Neutral unguarded Minor Towers capture automatically.
- Watchtower reveals details within range 3 while controlled. Fortress adds +1 tower Defence and +1 Defence to its controller defending there. Trait values are JSON data.
- World events and victory routes remain Milestone 3 content; passing through a World Phase in the early slice explicitly logs that boundary.
- Seeds use signed 32-bit integers across UI, CLI, JSON and browser to preserve exact round trips.

## Milestones 0–1 checkpoint

Godot headless rules, CLI process/persistence tests, and the real Godot web export passed. Browser input completed three rounds with all heroes moving, tower capture and income. 1280×720 and 1920×1080 were exercised. Milestone 2 begins after this checkpoint.
