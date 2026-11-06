## Counts the gameplay events a battle delivers, by receiving side and event tag, for `ChallengeEventCondition` (spec
## economy-challenges). Attached before the battle runs; it only observes (connects to each unit's event signal), so it can
## never change combat. An event sent to two units counts once for each unit that receives it.
class_name ChallengeTally
extends RefCounted

var _counts: Dictionary = {}  # "<side>|<tag>" -> int


func attach(battle: Battle) -> void:
	for unit in battle.units():
		var side := ChallengeCondition.side_of(unit)
		unit.asc.gameplay_event_received.connect(func(tag: StringName, _payload: Variant) -> void: _count(side, tag))


func _count(side: int, tag: StringName) -> void:
	var key := "%d|%s" % [side, tag]
	_counts[key] = int(_counts.get(key, 0)) + 1


## Events received by units of `side` whose tag is `tag` or one of its children (`Event.Damage` counts `Event.Damage.Dealt`).
func count(side: int, tag: StringName) -> int:
	var total := 0
	var prefix := "%d|" % side
	for key in _counts:
		if not str(key).begins_with(prefix):
			continue
		var event := str(key).substr(prefix.length())
		if event == str(tag) or event.begins_with(str(tag) + "."):
			total += int(_counts[key])
	return total
