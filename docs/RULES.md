# Implemented rules: complete local game

This document describes the playable local prototype. The [master specification](../shattered_realm_codex_master_spec.md) remains authoritative; values are tunable JSON data, and the decision record identifies explicit prototype assumptions.

## Board and heroes

Four locally controlled heroes start on separate Sanctuaries of a seed-generated radius-four board: 61 hexes, four Ancient Towers including the central Worldspire, four Minor Towers, two Settlements, two Ruins, and four Monster Camps. Sanctuaries do not count toward the sixteen locations. The generator validates travel opportunities and balanced access before accepting a map.

Seats are Ranger, Warlord, Merchant and Cultist. Their definitions supply distinct base stats; each starts at full Health with 4 Gold, 2 Power, 1 Fate, and no controlled locations or Relics. Gold, Power and Fate are public. Power caps at 12 and Fate at 5. Ranger movement through Forest costs 1; the implemented class abilities are described below.

Broad terrain, landmarks and hero positions are visible. Minor location details become known within two hexes of a hero and remain discovered. Watchtower and Fortress traits are data definitions. Ownership applies to locations, not ordinary hexes.

## A round

1. **World:** start the round; no event is drawn on round one. Later rounds select an eligible seeded world event and expire old world effects.
2. **Planning:** all four seats submit a plan and mark Ready. Plans apply together after all players are ready. Available choices are no change, a 2-Fate initiative push for +2 this round, Ranger Snare, Cultist Prepared Hex, and equipment purchases when controlling a Settlement.
3. **Initiative:** Speed + a seeded d3 + planned/status modifiers determines order; seeded tie-breaks are recorded. Snare and Forced March can change the next cycle's order, while preserving every player's action.
4. **Action Cycle 1:** each player receives exactly one scheduled action.
5. **Action Cycle 2:** each player receives a second scheduled action in order.
6. **Bonus:** the explicit phase exists, with no bonus grants in this slice.
7. **Resolution:** first confirm existing victory claims that survived a full response round. Otherwise pay income, create newly eligible claims, apply recovery/status cleanup, reset round flags, and gain 1 Fate up to the cap. Start the next World phase.

World, Initiative, Bonus and Resolution use an explicit Continue/`advance` command. Planning advances when every seat is Ready. Action cycles advance automatically after each hero has acted. Passing consumes the scheduled action. Actions cannot be banked or duplicated.

## Move and capture

Move is one action with a base budget of 3 movement points. Plains cost 1. Forest costs 2, or 1 for Ranger. Entering Swamp ends movement. Mountains and Water are impassable. A Move entirely following connected road edges gets a 4-point budget and costs 1 per edge. Other heroes and living monsters block entry and traversal. Sanctuaries are reserved for their owner so a downed hero always has a free recovery destination. The legal-action query supplies the chosen path and cost before confirmation.

Stand on an unowned, unguarded Minor Tower and use Capture to claim it in one action. Each controlled Minor Tower yields 1 Power at Resolution, respecting the Power cap. An enemy-owned Minor Tower with its owner absent can be contested: Attack + d6 must exceed tower Defence (4 + upgrade level above one + Fortress modifier). Warlord receives +1 from Martial Presence. A tie holds the tower, and an unsuccessful attempt still consumes the action. The calculation and seeded roll are logged. Displace or down an occupying enemy hero before entering its tower.

Ancient Towers and the Worldspire require two scheduled Capture actions: begin a public commitment, then complete it on the hero's next action while still eligible. Movement, displacement, downing, or successful contest cancels the commitment. Controlled Ancient Towers yield 2 Power. Upgrade an owned tower while standing there: level 2 costs 3 Gold, level 3 costs 5 Gold; level 3 adds 1 income. Three is the maximum level. Unoccupied Settlements capture in one action and yield 2 Gold per Resolution; a Merchant connected network adds 1 Gold per owned Settlement.

## Combat, Fate and recovery

Attack an adjacent hero or living monster as one scheduled action. Hero participants choose secret stances, revealed together. Monsters use a fixed profile. Each side rolls a seeded d6: attacker Attack + stance/modifiers + die versus defender Defence + stance/modifiers + die. Forest and controlled-tower defences apply; ties favor the defender. The full arithmetic appears in events/logs.

| Stance | Effect |
|---|---|
| Assault | +2 total; take 1 extra damage when losing |
| Guard | +1 total; reduce damage when losing by 1, minimum 1 |
| Counter | +3 against Assault, otherwise −1; a defending winner against Assault retaliates for 1 |
| Trick | Costs 1 Fate; +2 against Guard/Counter; a winning Trick suppresses their defensive effect |

After reveal, the attacker may spend 1 Fate to reroll its own die once, then the defender may do the same. The replacement is final unless Lucky Charm preserves a better old roll once that round. Decline is always available in a Fate decision window. A failed attack holds position; a margin of −4 or lower inflicts 1 overextension damage before stance adjustments. Successful margins 1–3 deal 2 damage, 4–6 deal 3 and displace, and 7+ deal 4, displace and drop 1 Gold. The defender chooses a legal adjacent displacement hex; if none exists, take 1 additional damage. Winning does not capture or advance automatically.

At zero Health, drop a carried Relic or lose up to 2 Gold, cancel commitments, return to Sanctuary and restore 60% maximum Health rounded up. Recovering grants targeting protection and −1 Attack/Defence until the next World phase. Defeat never removes a scheduled action. A severe combat loss or downing can grant 1 Fate, at most once per round and within the cap. Rest at an eligible Sanctuary/controlled Settlement restores 3 Health for one action. Resolution normally heals 1; a hero downed that round skips that heal.

Wolf Pack, Stone Guardian and Relic Wraith are the three monster profiles. Attack them through the same stance/dice/Fate pipeline; cleared camps stop blocking movement. Rewards can grant Gold, Power or a Relic. Two Wraith camps and two Ruins provide four guaranteed, contested Relic sources. Carry three to attempt Ascension.

## Class timing

- **Ranger — Snare (Planning):** spend 1 Power to trap an eligible nearby hex, maximum one active trap. An enemy entering ends movement and receives −2 initiative for the next cycle. The board shows a generic warning.
- **Warlord — Challenge (Reaction):** once per round, optionally stop an enemy's movement as it leaves adjacency, after at least one step occurred. **Forced March (Action):** spend 1 Power during movement to ignore one difficult-terrain penalty and gain +2 initiative for the next cycle.
- **Merchant — Bribe (Reaction):** offer 2 Gold when attacked, once per round. Acceptance transfers Gold and consumes the attack; refusal grants Merchant +1 Defence for that combat. Each participant explicitly chooses.
- **Cultist — Prepared Hex (Planning):** spend 1 Power and select a visible enemy. Its next initiated combat before the next Planning phase takes −1 to its combat die.

Reactions only appear for eligible abilities; there is no universal reaction allowance. The first new location discovered by Ranger, first Merchant Trade, first Cultist Dark Bargain, and first Warlord attack on a strategically stronger hero each grant 1 Fate per round, respecting the cap. Stronger means more controlled Towers or a higher total equipped tier. Ranger exploration yields 1 extra Gold; Cultist Occult Sense gives imprecise nearby Relic-region hints.

## Trade, exploration and equipment

Trade at an owned or neutral Settlement, or the temporary Wandering Market: exchange 2 Gold for 1 Power, or 1 Power for 2 Gold. Each exchange costs one action. Merchant Seal improves the received amount by 1. Roads connect owned Settlements only through walkable hexes without an intermediate enemy-controlled key location.

Explore a fresh discovered Ruin to receive its guaranteed Relic and a seeded bonus: Gold, Power, healing or equipment. The reward odds are available before confirmation. Spend 2 Fate to reveal two different bonuses and choose one. A Ruin becomes exhausted after resolution. Explore also collects unclaimed Gold/Relics on the current hex. Cultist's Dark Bargain explores a fresh Ruin while deliberately paying 2 Health for 2 extra Power; it requires more than 2 Health and cannot down the Cultist.

Control a Settlement to buy equipment during Planning, with at most three equipped items. Eight definitions are available: Iron Weapon, Reinforced Armor, Trail Boots, Scout Lens, Tower Kit, Lucky Charm, Merchant Seal, and Ward Stone. Most cost 4 Gold; Lucky Charm costs 6. Benefits and tradeoffs appear in the purchase choices. Purchases apply together when Planning ends. Spending below 15 Gold cancels an active Dominion claim.

## World events

From round two, one eligible event changes a public board condition:

- **Collapsed Bridge:** closes a marked bridge for two rounds while preserving an alternate route.
- **Unstable Leyline:** a Tower produces 1 extra Power and has 1 less Defence until Resolution.
- **Monster Migration:** reinforces the camp nearest the richest hero with 1 Health/Defence, at most twice.
- **Cursed Ground:** a region's Plains use Forest movement cost for the round; combat terrain stays unchanged.
- **Wandering Market:** an unoccupied neutral hex permits Trade until Resolution.

Effects have explicit expiry events; they never remove a scheduled action.

## Win the game

- **Conquest:** control all four Ancient Towers, including Worldspire. Resolution creates a public claim; retain every required Tower through the next Resolution to win.
- **Dominion:** control both Settlements with a valid road connection and hold at least 15 Gold. Resolution creates a public claim; preserve all requirements through the next Resolution. Spending below 15, losing a Settlement, or breaking the road network immediately cancels the claim.
- **Ascension:** carry at least three Relics on Worldspire. Begin Ritual, then Complete Ritual on the next scheduled action. Leaving, displacement, downing, losing requirements or choosing another action cancels the ritual. Completion wins immediately.

New Conquest/Dominion claims never win during the Resolution that creates them. Existing claims are verified before new income. Exact simultaneous qualifying claims use the documented shared-victory fallback. There is no normal match round limit; automated simulations stop at 40 and report a stall instead of inventing a winner.

## Native multiplayer decisions

The host validates every intent and owns gameplay dice. Each connected player controls only their assigned seat. Private plans and unrevealed stances remain off other clients' wire data; public trap warnings remain visible. The default online planning deadline is 60 seconds, optional-decision deadline 20 seconds, and action fallback 90 seconds. Timeouts choose no-change Ready, Decline, Guard for an unsubmitted stance, or safe Pass as applicable. Disconnected seats temporarily use the simple bot; a reconnect token returns control of the reserved seat while the host remains active. Local/solo games have no network deadline.
