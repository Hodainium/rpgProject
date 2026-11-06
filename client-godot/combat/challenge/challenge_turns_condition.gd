## The battle's turn count compared to a number (spec economy-challenges): "turns <= 25".
@tool
class_name ChallengeTurnsCondition
extends ChallengeCondition

@export_enum("At most", "At least", "Exactly") var compare: int = Compare.LESS_OR_EQUAL
@export var turns: int = 1


func met(battle: Battle, _tally: ChallengeTally) -> bool:
	return compare_ints(battle.turn, compare, turns)


func describe() -> String:
	return "turns %s %d" % [["<=", ">=", "=="][compare], turns]


func problems() -> PackedStringArray:
	return PackedStringArray() if turns >= 1 else PackedStringArray(["turns must be 1 or more"])
