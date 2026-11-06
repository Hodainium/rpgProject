## True when every nested condition is (an empty list is true). Spec economy-challenges.
@tool
class_name ChallengeAllOf
extends ChallengeCondition

@export var conditions: Array[ChallengeCondition] = []


func met(battle: Battle, tally: ChallengeTally) -> bool:
	for condition in conditions:
		if condition == null or not condition.met(battle, tally):
			return false
	return true


func describe() -> String:
	return "all of (%s)" % ", ".join(PackedStringArray(conditions.map(func(c: ChallengeCondition) -> String: return c.describe() if c != null else "?")))


func problems() -> PackedStringArray:
	return ChallengeAnyOf.nested_problems(conditions)
