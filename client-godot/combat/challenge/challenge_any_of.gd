## True when at least one nested condition is (an empty list is false). Spec economy-challenges.
@tool
class_name ChallengeAnyOf
extends ChallengeCondition

@export var conditions: Array[ChallengeCondition] = []


func met(battle: Battle, tally: ChallengeTally) -> bool:
	for condition in conditions:
		if condition != null and condition.met(battle, tally):
			return true
	return false


func describe() -> String:
	return "any of (%s)" % ", ".join(PackedStringArray(conditions.map(func(c: ChallengeCondition) -> String: return c.describe() if c != null else "?")))


func problems() -> PackedStringArray:
	var found := nested_problems(conditions)
	if conditions.is_empty():
		found.append("any_of with no conditions is never true")
	return found


## The problems of every nested condition, plus an empty slot.
static func nested_problems(nested: Array[ChallengeCondition]) -> PackedStringArray:
	var found := PackedStringArray()
	for index in nested.size():
		if nested[index] == null:
			found.append("nested condition %d is empty" % (index + 1))
		else:
			for problem in nested[index].problems():
				found.append("%s: %s" % [nested[index].describe(), problem])
	return found
