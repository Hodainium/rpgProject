## A test on the units of one side (spec economy-challenges), built from GAS data: a state filter (alive or dead), an
## optional GameplayTagQuery on the unit's tags and an optional attribute comparison. `quantifier` says how many of the side's
## units must pass: ALL, ANY, or NONE. Examples: "every party unit is alive" (side PARTY, ALL, alive = ALIVE); "no party unit
## ended Downed" (PARTY, NONE, tag query requiring State.Downed); "every enemy was Broken" (ENEMY, ALL, query State.Broken);
## "the party ended above half health" (PARTY, ALL, attribute hp >= 5000 of max_hp).
@tool
class_name ChallengeUnitsCondition
extends ChallengeCondition

enum Quantifier { ALL, ANY, NONE }
enum AliveFilter { ANY_STATE, ALIVE, DEAD }

@export_enum("Party", "Enemy") var side: int = Side.PARTY
@export_enum("All", "Any", "None") var quantifier: int = Quantifier.ALL
@export_enum("Any state", "Alive", "Dead") var alive: int = AliveFilter.ANY_STATE
## Null = no tag test. The unit passes when its tags satisfy the query.
@export var tag_query: GameplayTagQuery
## Empty = no attribute test. Otherwise the unit's current value of this attribute (stored x100) is compared to
## `attribute_value_x100`; when `percent_of_attribute` is set (for example `max_hp`), the value compared is the percentage of
## that attribute (x100: 5000 = 50%), and `attribute_value_x100` is a percentage in the same unit.
@export var attribute: String = ""
@export_enum("At most", "At least", "Exactly") var attribute_compare: int = Compare.GREATER_OR_EQUAL
@export var attribute_value_x100: int = 0
@export var percent_of_attribute: String = ""


func met(battle: Battle, _tally: ChallengeTally) -> bool:
	var passing := 0
	var total := 0
	for unit in battle.units():
		if side_of(unit) != side:
			continue
		total += 1
		if _passes(unit):
			passing += 1
	match quantifier:
		Quantifier.ALL:
			# Review fix: "every unit of the side passes" over a side with no units is false, not vacuously true: a star must
			# be earned by units that exist.
			return total > 0 and passing == total
		Quantifier.ANY:
			return passing > 0
		_:
			return passing == 0


func _passes(unit: BattleUnit) -> bool:
	if alive == AliveFilter.ALIVE and not unit.alive:
		return false
	if alive == AliveFilter.DEAD and unit.alive:
		return false
	if tag_query != null and not tag_query.matches(unit.asc):
		return false
	if attribute != "":
		var data := unit.asc.get_attribute(attribute)
		if data == null:
			return false
		var value := int(data.current_value)
		if percent_of_attribute != "":
			var max_data := unit.asc.get_attribute(percent_of_attribute)
			if max_data == null or int(max_data.current_value) <= 0:
				return false
			value = value * 10000 / int(max_data.current_value)  # percent x100, integer division only
		return compare_ints(value, attribute_compare, attribute_value_x100)
	return true


func describe() -> String:
	return "%s of the %s units pass" % [["all", "any", "none"][quantifier], ["party", "enemy"][side]]


func problems() -> PackedStringArray:
	var found := PackedStringArray()
	if attribute == "" and percent_of_attribute != "":
		found.append("percent_of_attribute needs an attribute")
	if alive == AliveFilter.ANY_STATE and tag_query == null and attribute == "":
		found.append("this tests nothing (set alive, a tag query or an attribute)")
	return found
