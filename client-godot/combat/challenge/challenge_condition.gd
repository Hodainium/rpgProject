## A condition on a finished battle (spec economy-challenges): the abstract base of everything a challenge star can ask.
## Conditions are resources composed in the editor (a star holds a list of them, AllOf / AnyOf / Not nest them), and a new
## kind is a new subclass overriding `met`; the star, the challenge and the replay never change. A condition reads only the
## battle's final state and the event tally (never the RNG, never a clock), so the replay and the client agree. Numbers are
## whole: counts as they are, attribute values and percentages stored x100 like the rest of combat.
@tool
class_name ChallengeCondition
extends Resource

enum Compare { LESS_OR_EQUAL, GREATER_OR_EQUAL, EQUAL }
enum Side { PARTY, ENEMY }


## True when `battle` (finished) satisfies this condition. `tally` counts the gameplay events the battle delivered (it may
## be null, which counts as no events).
func met(_battle: Battle, _tally: ChallengeTally) -> bool:
	return true


## Human text for the editor and the validator ("turns <= 25"). Defaults to the class name.
func describe() -> String:
	return str(get_script().get_global_name())


## Problems with this condition's settings, for the content validator. Empty when fine.
func problems() -> PackedStringArray:
	return PackedStringArray()


static func compare_ints(value: int, op: int, expected: int) -> bool:
	match op:
		Compare.LESS_OR_EQUAL:
			return value <= expected
		Compare.GREATER_OR_EQUAL:
			return value >= expected
		_:
			return value == expected


static func side_of(unit: BattleUnit) -> int:
	return Side.ENEMY if unit.side == BattleUnit.Side.ENEMY else Side.PARTY
