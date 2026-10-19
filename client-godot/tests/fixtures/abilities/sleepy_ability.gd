## Test-only BROKEN ability for the zero-frame rule: it awaits a frame instead of the presentation gate.
## The replay runner must report ContentAwaitedFrame (a runner error, not a verdict).
class_name FixtureSleepyAbility
extends BattleAbility


func _activate_ability() -> bool:
	await get_tree().process_frame
	return await super()
