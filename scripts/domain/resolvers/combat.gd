extends RefCounted
## Deterministic combat arithmetic only: callers validate windows/costs and apply
## results. This resolver neither spends resources nor mutates participants.

static var _stance_table: Dictionary = {}

static func stance_definitions() -> Dictionary:
	if _stance_table.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/stances.json"))
		assert(parsed is Dictionary, "Stance definitions must be a JSON dictionary")
		_stance_table = parsed
	return _stance_table.duplicate(true)

static func evaluate(attacker: Dictionary, defender: Dictionary, attacker_stance: String, defender_stance: String, attacker_die: int, defender_die: int, modifiers: Dictionary = {}) -> Dictionary:
	var table := stance_definitions()
	if (attacker_stance != "none" and not table.has(attacker_stance)) or (defender_stance != "none" and not table.has(defender_stance)):
		return _invalid("INVALID_STANCE", "Both stances must identify a known stance or fixed monster behavior.")
	if attacker_die < 1 or attacker_die > 6 or defender_die < 1 or defender_die > 6:
		return _invalid("INVALID_DIE", "Combat dice must be integers from one to six.")
	if not _integer(attacker.get("attack")) or not _integer(defender.get("defence")) or attacker.attack < 0 or defender.defence < 0:
		return _invalid("INVALID_STAT", "Combatants require nonnegative integer Attack and Defence stats.")
	for name in ["attacker_modifier", "defender_modifier", "attacker_die_modifier", "defender_die_modifier"]:
		if not _integer(modifiers.get(name, 0)):
			return _invalid("INVALID_MODIFIER", "Combat modifiers must be finite integers.")
	for name in ["attacker_modifiers", "defender_modifiers"]:
		var parts: Variant = modifiers.get(name, {})
		if not parts is Dictionary:
			return _invalid("INVALID_MODIFIER", "Named combat modifiers must be a dictionary.")
		for label: Variant in parts:
			if not label is String or not _integer(parts[label]):
				return _invalid("INVALID_MODIFIER", "Named combat modifiers require string labels and integer values.")
	var attack_definition: Dictionary = table.get(attacker_stance, {})
	var defend_definition: Dictionary = table.get(defender_stance, {})
	var attack_stance_bonus := _stance_modifier(attack_definition, defender_stance)
	var defend_stance_bonus := _stance_modifier(defend_definition, attacker_stance)
	var attack_die_bonus := int(modifiers.get("attacker_die_modifier", 0))
	var defend_die_bonus := int(modifiers.get("defender_die_modifier", 0))
	var effective_attack_die := clampi(attacker_die + attack_die_bonus, 1, 6)
	var effective_defend_die := clampi(defender_die + defend_die_bonus, 1, 6)
	var attack_bonus := int(modifiers.get("attacker_modifier", 0))
	var defend_bonus := int(modifiers.get("defender_modifier", 0))
	var attack_total := int(attacker.get("attack", 0)) + attack_stance_bonus + attack_bonus + effective_attack_die
	var defend_total := int(defender.get("defence", 0)) + defend_stance_bonus + defend_bonus + effective_defend_die
	var margin := attack_total - defend_total
	var success := margin > 0
	var defender_base_damage := 0
	var attacker_base_damage := 1 if margin <= -4 else 0
	var band := "defender_holds"
	if margin >= 7:
		defender_base_damage = 4
		band = "decisive"
	elif margin >= 4:
		defender_base_damage = 3
		band = "displace"
	elif margin > 0:
		defender_base_damage = 2
		band = "hit"
	elif margin <= -4:
		band = "overextension"
	var winner_definition: Dictionary = attack_definition if success else defend_definition
	var suppressed: Array = winner_definition.get("suppresses_on_win", [])
	var attack_loss_extra := int(attack_definition.get("loss_damage", 0)) if not success else 0
	var defend_loss_extra := int(defend_definition.get("loss_damage", 0)) if success else 0
	var retaliation := 0
	if not success and attacker_stance in defend_definition.get("retaliation_against", []):
		retaliation = int(defend_definition.get("retaliation_damage", 0))
	var attack_damage := attacker_base_damage + attack_loss_extra + retaliation
	var defend_damage := defender_base_damage + defend_loss_extra
	var attack_reduction := 0
	var defend_reduction := 0
	if not success and attack_damage > 0 and "damage_reduction" not in suppressed:
		attack_reduction = mini(int(attack_definition.get("damage_reduction", 0)), maxi(0, attack_damage - int(attack_definition.get("minimum_damage", 1))))
		attack_damage -= attack_reduction
	if success and defend_damage > 0 and "damage_reduction" not in suppressed:
		defend_reduction = mini(int(defend_definition.get("damage_reduction", 0)), maxi(0, defend_damage - int(defend_definition.get("minimum_damage", 1))))
		defend_damage -= defend_reduction
	return {
		"is_valid": true,
		"attacker_total": attack_total, "defender_total": defend_total, "margin": margin,
		"success": success, "winner": "attacker" if success else "defender", "outcome_band": band,
		"attacker_damage": attack_damage, "defender_damage": defend_damage,
		"displace": margin >= 4, "drop_gold": margin >= 7,
		"attacker_stance": attacker_stance, "defender_stance": defender_stance,
		"attacker_die": effective_attack_die, "defender_die": effective_defend_die,
		"attacker_raw_die": attacker_die, "defender_raw_die": defender_die,
		"attacker_die_modifier": attack_die_bonus, "defender_die_modifier": defend_die_bonus,
		"attacker_stat": int(attacker.get("attack", 0)), "defender_stat": int(defender.get("defence", 0)),
		"attacker_stance_modifier": attack_stance_bonus, "defender_stance_modifier": defend_stance_bonus,
		"attacker_modifier": attack_bonus, "defender_modifier": defend_bonus,
		"attacker_modifiers": modifiers.get("attacker_modifiers", {}).duplicate(true),
		"defender_modifiers": modifiers.get("defender_modifiers", {}).duplicate(true),
		"attacker_base_damage": attacker_base_damage, "defender_base_damage": defender_base_damage,
		"attacker_loss_damage": attack_loss_extra, "defender_loss_damage": defend_loss_extra,
		"attacker_damage_reduction": attack_reduction, "defender_damage_reduction": defend_reduction,
		"retaliation_damage": retaliation,
		"guard_suppressed": "damage_reduction" in suppressed and (defender_stance == "guard" if success else attacker_stance == "guard"),
		"counter_suppressed": "retaliation_damage" in suppressed and (defender_stance == "counter" if success else attacker_stance == "counter"),
	}

static func _stance_modifier(definition: Dictionary, opposing_stance: String) -> int:
	return int(definition.get("versus_modifiers", {}).get(opposing_stance, definition.get("base_modifier", 0)))

static func _integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value))

static func _invalid(code: String, message: String) -> Dictionary:
	return {"is_valid": false, "reason_code": code, "message": message}
