extends RefCounted
const Combat = preload("res://scripts/domain/resolvers/combat.gd")
var errors: Array[String] = []

func run() -> Array[String]:
	errors.clear()
	_test_stance_matrix()
	_test_margin_bands()
	_test_damage_effects()
	_test_modifiers_and_purity()
	_test_monsters()
	return errors

func _check(condition: bool, message: String) -> void:
	if not condition:
		errors.append(message)

func _test_stance_matrix() -> void:
	var stances := ["assault", "guard", "counter", "trick"]
	# Columns are opposing stance. Explicit fixture prevents repeating resolver logic.
	var expected := {"assault": [2, 2, 2, 2], "guard": [1, 1, 1, 1], "counter": [3, -1, -1, -1], "trick": [0, 2, 2, 0]}
	for a in range(4):
		for d in range(4):
			var result := Combat.evaluate({"attack": 3}, {"defence": 3}, stances[a], stances[d], 3, 3)
			_check(result.attacker_total == 6 + expected[stances[a]][d], "Attacker stance matrix %s/%s" % [stances[a], stances[d]])
			_check(result.defender_total == 6 + expected[stances[d]][a], "Defender stance matrix %s/%s" % [stances[a], stances[d]])
			_check(result.success == (result.margin > 0), "Ties must favor defender in every stance pairing")
	var definitions := Combat.stance_definitions()
	_check(definitions.size() == 4 and definitions.trick.fate_cost == 1, "Four data-driven stances; Trick costs one Fate")
	definitions.assault.base_modifier = 999
	_check(Combat.stance_definitions().assault.base_modifier == 2, "Definition snapshots cannot mutate resolver tables")

func _test_margin_bands() -> void:
	# [margin, attacker damage, defender damage, displacement, gold drop]
	var cases := [[-7, 1, 0, false, false], [-4, 1, 0, false, false], [-3, 0, 0, false, false], [0, 0, 0, false, false], [1, 0, 2, false, false], [3, 0, 2, false, false], [4, 0, 3, true, false], [6, 0, 3, true, false], [7, 0, 4, true, true], [10, 0, 4, true, true]]
	for item in cases:
		var result := Combat.evaluate({"attack": 10 + item[0]}, {"defence": 10}, "none", "none", 3, 3)
		_check(result.margin == item[0], "Margin arithmetic")
		_check([result.attacker_damage, result.defender_damage, result.displace, result.drop_gold] == item.slice(1), "Outcome band at margin %d" % item[0])

func _test_damage_effects() -> void:
	var result := Combat.evaluate({"attack": 3}, {"defence": 3}, "none", "guard", 3, 3)
	_check(result.attacker_damage == 0, "A close failed attack has no default self damage")
	result = Combat.evaluate({"attack": 3}, {"defence": 3}, "assault", "counter", 3, 3)
	_check(result.margin == -1 and result.attacker_damage == 2 and result.retaliation_damage == 1, "Defending Counter retaliation stacks with Assault loss risk")
	result = Combat.evaluate({"attack": 0}, {"defence": 5}, "assault", "counter", 3, 3)
	_check(result.attacker_damage == 3, "Overextension, Assault risk, Counter retaliation stack")
	result = Combat.evaluate({"attack": 3}, {"defence": 5}, "assault", "none", 3, 3)
	_check(result.margin == 0 and result.attacker_damage == 1, "Assault adds loss damage even when base damage is zero")
	result = Combat.evaluate({"attack": 3}, {"defence": 3}, "counter", "assault", 3, 3)
	_check(result.success and result.retaliation_damage == 0 and result.defender_damage == 3, "Attacking Counter cannot retaliate; defending Assault suffers loss extra")
	result = Combat.evaluate({"attack": 5}, {"defence": 3}, "none", "guard", 3, 3)
	_check(result.margin == 1 and result.defender_damage == 1 and result.defender_damage_reduction == 1, "Guard reduces two damage to minimum one")
	result = Combat.evaluate({"attack": 0}, {"defence": 5}, "guard", "none", 3, 3)
	_check(result.margin == -4 and result.attacker_damage == 1, "Guard cannot eliminate one overextension damage")
	result = Combat.evaluate({"attack": 2}, {"defence": 3}, "guard", "none", 3, 3)
	_check(result.margin == 0 and result.attacker_damage == 0, "Guard does not create damage when loss has no damage")
	result = Combat.evaluate({"attack": 3}, {"defence": 3}, "trick", "guard", 3, 3)
	_check(result.margin == 1 and result.defender_damage == 2 and result.guard_suppressed, "Winning Trick suppresses Guard reduction")
	result = Combat.evaluate({"attack": 3}, {"defence": 3}, "trick", "counter", 3, 3)
	_check(result.success and result.counter_suppressed and result.retaliation_damage == 0, "Winning Trick suppresses Counter retaliation")

func _test_modifiers_and_purity() -> void:
	var attacker := {"attack": 3, "hp": 8, "fate": 2, "statuses": {"recovering": true}}
	var defender := {"defence": 2, "hp": 9, "gold": 4}
	var modifiers := {"attacker_modifier": -1, "defender_modifier": 2, "attacker_die_modifier": -1, "defender_die_modifier": 0, "attacker_modifiers": {"recovering": -1}, "defender_modifiers": {"forest": 1, "tower": 1}}
	var before := JSON.stringify([attacker, defender, modifiers])
	var result := Combat.evaluate(attacker, defender, "assault", "guard", 1, 4, modifiers)
	_check(result.attacker_die == 1 and result.attacker_raw_die == 1, "Prepared Hex cannot reduce die below one")
	_check(result.attacker_total == 5 and result.defender_total == 9, "Stat, stance, external and die terms are applied once")
	_check(JSON.stringify([attacker, defender, modifiers]) == before, "Pure combat arithmetic does not mutate participants or modifiers")
	_check(result.attacker_modifiers == {"recovering": -1} and result.defender_modifiers == {"forest": 1, "tower": 1}, "Calculation retains named modifier breakdown")
	result = Combat.evaluate(attacker, defender, "none", "none", 6, 1, {"attacker_die_modifier": -1})
	_check(result.attacker_die == 5 and result.attacker_raw_die == 6, "Prepared Hex applies to final rerolled die")

func _test_monsters() -> void:
	var profiles: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/monsters.json"))
	_check(profiles.size() == 3, "Three monster profiles")
	for id: String in ["wolf_pack", "stone_guardian", "relic_wraith"]:
		_check(profiles.has(id), "Required monster " + id)
		var monster: Dictionary = profiles[id]
		_check(monster.stance == "none" and monster.hp > 0 and monster.attack > 0 and monster.defence > 0, "Fixed monster stats and no stance prompt")
		var result := Combat.evaluate({"attack": 3}, monster, "guard", "none", 3, 3)
		_check(result.defender_stance_modifier == 0 and result.defender_total == monster.defence + 3, "Monsters share opposed combat arithmetic")
	_check(profiles.wolf_pack.reward.gold == 2 and profiles.stone_guardian.reward.power == 2 and profiles.relic_wraith.reward.relics == 1, "Distinct Gold, Power and Relic rewards")
