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

## Milestone 2 timing and combat defaults

- Combat keeps the scheduled phase and opens explicit participant windows. Attack declaration starts the action; only the final resolution consumes that scheduled slot. Defending, reacting, rerolling and being downed do not consume the defender's slot.
- Stance submissions are sealed until both are chosen. Trick is charged at reveal to avoid leaking the secret through the public Fate total. Attacker reroll precedes defender reroll; a player with no Fate does not receive an impossible prompt.
- Assault's extra point applies to any loss, including ties with zero base damage. Guard reduces positive damage only and never creates damage from zero. Prepared Hex modifies the die with a minimum of 1 and maximum of 6.
- Wolf Pack: HP 4 / Attack 3 / Defence 1, reward 2 Gold. Stone Guardian: 6 / 4 / 4, reward 2 Power. Relic Wraith: 5 / 5 / 3, reward 1 Relic. Monster defenders stay in their camp; hero margin damage uses the shared resolver.
- A severe hit's 1 Gold drop is cumulative with defeat consequences. A downed hero drops one Relic, otherwise loses up to 2 Gold, and returns at 60% rounded-up HP with Recovering until World. Sanctuaries are reserved to their owning hero so recovery can never create overlapping pieces.
- Snare targets a nearby, walkable, unoccupied non-Sanctuary hex; visible details within range 2 establish discovery. Only one per Ranger is active and unused traps expire at Resolution. Opponents see a generic warning marker.
- Challenge can stop movement only after at least one actual step. Accepting uses its once-per-round flag; declining does not. Bribe offers and acceptance are separate legal decisions; canceled attacks still consume the attacker's action.
- Prepared Hex expires at the next Planning phase or the target's first declared combat, including a Bribe-canceled combat.
- Forced March waives one difficult-terrain cost but never bypasses Swamp's mandatory stop. Cycle 1 initiative changes apply to Cycle 2; Cycle 2 changes carry to next round. Equal adjusted scores preserve the already randomized order.
- Any successful enemy hero combat hit contests and cancels an Ancient Tower commitment. Any different action on the claimant's next scheduled slot also cancels it; completion is deliberately required on that next slot.
- Level 2 adds 1 Defence for 3 Gold. Level 3 adds 1 income for 5 Gold, with no additional Defence. Definitions and tests distinguish this from compounding both benefits.
- These are documented prototype defaults, not final balance claims. Victory, trading, exploration, class thematic Fate gains and the remaining content remain Milestone 3 work.
- The first bot uses stable public heuristics instead of weighted random decisions: Guard when badly wounded, otherwise Assault, reroll own die on 1–2, pursue capturable sites and nearby combat, and resolve only legal windows. It consumes no additional RNG and never reads opposing sealed choices.

## Expanded scope: complete Milestones 3–5

The user explicitly authorized completing every milestone, including the presentation pass and ENet proof, before stopping. The earlier slice boundaries above record historical checkpoints and do not limit the active scope. Final production art remains outside this prototype.

- Settlement capture is an automatic single action when no enemy hero occupies the site. The spec supplies no separate Settlement defence roll.
- Both Ruins contain one guaranteed Relic plus a seeded weighted bonus. Two Wraith camps provide the other guaranteed Relic sources. Four contested sources make Ascension reachable without relying on a lucky reward draw.
- Explore Alternatives costs 2 Fate and offers two distinct bonus rewards. Cultist Dark Bargain is an optional Ruin exploration branch: lose 2 Health, survive the payment, gain 2 Power and the class Fate trigger.
- Conquest and Dominion claims are declared after Resolution income and confirmed before income at the following Resolution. Every accepted action rechecks claim requirements. Ascension requires Begin Ritual followed by Complete Ritual on the next scheduled action; ordinary non-displacing damage alone does not cancel it.
- Equipment occupies at most three slots. The eight data-defined items implement actual effects, including one-use Tower Kit and Lucky Charm's once-per-round keep-better reroll. Planning purchases resolve with the simultaneous plans.
- World events use their own saved RNG stream. Bridge closure requires a surviving alternative and whole-board connectivity; curses modify movement terrain while retaining underlying terrain and explicit expiry.
- Local modes are sandbox (all seats), solo (chosen human plus three deterministic bots), and hotseat (private Planning and stance handoffs). The development browser bridge intentionally exposes the full local state for tests; network observations must be filtered before transport.
- Manual saves and round autosaves use validated versioned envelopes, a temporary replacement file, and one rotating backup. Mode and human seat are presentation metadata. CLI tooling can continue the same saved domain state.
- Presentation settings persist separately from gameplay: four audio buses, generated nonessential text-backed cues, reduced motion, animation speed, UI scale and hints. The Music bus has no soundtrack in this prototype.
- Match duration is measured, never forced. The 40-round automated-test guard reports a failure if a bot match stalls; it cannot invent a winner or alter game rules.

## Multiplayer proof defaults

- Native ENet uses a direct address and configurable port (UI/CLI default 24567), one host and at most three connected client seats. Browser play remains local or solo.
- The host advances shared phases and controls bot seats. Unclaimed seats are bots; a disconnected human's seat temporarily becomes a bot but remains reserved by a random reconnect token.
- Planning allows 60 seconds. Actions and reactions use the specification's provisional 20-second default. Timeout handling submits ordinary validated safe commands, and another player's edits do not extend the waiting player's deadline. Tests can shorten or disable timers without modifying rules.
- Reconnect recovers an authorized observation from the same live host. Host migration/restart recovery and production account or relay infrastructure are outside the proof.
- Client views are not save files. Full command/RNG history stays with the host; per-player view checksums and a common public checksum provide synchronization diagnostics without sending private plans or sealed stances.
