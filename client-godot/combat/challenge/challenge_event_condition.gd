## How many gameplay events of a tag (or its children) units of one side received during the battle (spec
## economy-challenges): "the party used 3 ultimates" (side PARTY, Event.Ability.Used.Ultimate >= 3), "the enemy was never
## Broken" (ENEMY, Event.Damage.Dealt.Break == 0). Counted by the tally; an event sent to two units counts for each receiver.
@tool
class_name ChallengeEventCondition
extends ChallengeCondition

@export_enum("Party", "Enemy") var side: int = Side.PARTY
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var event_tag: StringName = &""
@export_enum("At most", "At least", "Exactly") var compare: int = Compare.GREATER_OR_EQUAL
@export var count: int = 1


func met(_battle: Battle, tally: ChallengeTally) -> bool:
	var seen := tally.count(side, event_tag) if tally != null else 0
	return compare_ints(seen, compare, count)


func describe() -> String:
	return "%s receives %s %s %d" % [["party", "enemy"][side], event_tag, ["<=", ">=", "=="][compare], count]


func problems() -> PackedStringArray:
	var found := PackedStringArray()
	if event_tag == &"":
		found.append("event_tag is empty")
	if count < 0:
		found.append("count must not be negative")
	return found
