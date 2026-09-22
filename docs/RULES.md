# Implemented rules: Milestones 0 and 1

This document describes the playable slice. The [master specification](../shattered_realm_codex_master_spec.md) remains authoritative for later combat, class abilities, exploration, upgrades and victory systems.

## Board and heroes

Four locally controlled heroes start on separate Sanctuaries of a seed-generated radius-four board: 61 hexes, four Ancient Towers including the central Worldspire, four Minor Towers, two Settlements, two Ruins, and four Monster Camps. Sanctuaries do not count toward the sixteen locations. The generator validates travel opportunities and balanced access before accepting a map.

Seats are Ranger, Warlord, Merchant and Cultist. Their definitions supply distinct base stats; each starts at full Health with 4 Gold, 2 Power, 1 Fate, and no controlled locations or Relics. Gold, Power and Fate are public. Power caps at 12 and Fate at 5. Ranger movement through Forest costs 1; the rest of the class ability kits belong to later milestones.

Broad terrain, landmarks and hero positions are visible. Minor location details become known within two hexes of a hero and remain discovered. Watchtower and Fortress traits are data definitions. Ownership applies to locations, not ordinary hexes.

## A round

1. **World:** start the round; no event is drawn on round one. The world-event content system is deferred.
2. **Planning:** all four seats submit a no-change plan and mark Ready. Plans resolve together after all players are ready. Purchases and class preparations are deferred.
3. **Initiative:** Speed + a seeded d3 determines order; seeded tie-breaks are recorded. The same order applies to both cycles.
4. **Action Cycle 1:** each player receives exactly one scheduled action.
5. **Action Cycle 2:** each player receives a second scheduled action in order.
6. **Bonus:** the explicit phase exists, with no bonus grants in this slice.
7. **Resolution:** pay location income, apply supported recovery/status cleanup, reset round flags, and gain 1 Fate up to the cap. Start the next World phase.

World, Initiative, Bonus and Resolution use an explicit Continue/`advance` command. Planning advances when every seat is Ready. Action cycles advance automatically after each hero has acted. Passing consumes the scheduled action. Actions cannot be banked or duplicated.

## Move and capture

Move is one action with a base budget of 3 movement points. Plains cost 1. Forest costs 2, or 1 for Ranger. Entering Swamp ends movement. Mountains and Water are impassable. A Move entirely following connected road edges gets a 4-point budget and costs 1 per edge. Other heroes block both entry and traversal. The legal-action query supplies the chosen path and cost before confirmation.

Stand on an unowned, unguarded Minor Tower and use Capture to claim it in one action. Each controlled Minor Tower yields 1 Power at Resolution, respecting the Power cap. An enemy-owned Minor Tower with its owner absent can be contested: Attack + d6 must exceed tower Defence (4 + upgrade level above one + Fortress modifier). Warlord receives +1 from Martial Presence. A tie holds the tower, and an unsuccessful attempt still consumes the action. The calculation and seeded roll are logged. An owner standing on the tower blocks entry until the later hero-combat system is available. Ancient Towers, Settlements, Ruins and Monster Camps are landmarks in this milestone; their full interactions are deferred.

The slice supports repeated rounds and inspection of economy changes. It does not yet implement combat, victory claims, or a final win screen.
