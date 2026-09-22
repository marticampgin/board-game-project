extends RefCounted
## Stable serialized IDs. Domain snapshots deliberately never contain Node IDs.
enum Phase { WORLD, PLANNING, INITIATIVE, CYCLE_1, CYCLE_2, BONUS, RESOLUTION, VICTORY }
enum Timing { ACTION, PLANNING, REACTION, PASSIVE }
const PHASE_IDS: Array[String] = ["world", "planning", "initiative", "cycle_1", "cycle_2", "bonus", "resolution", "victory"]
const PLAYER_IDS: Array[String] = ["p1", "p2", "p3", "p4"]
const COMMAND_IDS: Array[String] = ["advance", "submit_plan", "ready", "move", "capture", "pass", "attack", "choose_stance", "spend_fate", "decline_fate", "displace", "resolve_reaction", "special", "upgrade", "trade", "explore", "choose_reward", "begin_ritual", "complete_ritual"]
