## The opposite of the nested condition. Spec economy-challenges.
@tool
class_name ChallengeNot
extends ChallengeCondition

@export var condition: ChallengeCondition


func met(battle: Battle, tally: ChallengeTally) -> bool:
	return condition == null or not condition.met(battle, tally)


func describe() -> String:
	return "not (%s)" % (condition.describe() if condition != null else "?")


func problems() -> PackedStringArray:
	if condition == null:
		return PackedStringArray(["not has no condition"])
	return condition.problems()
