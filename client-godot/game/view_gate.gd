## ClientGate that tells the screens which unit is acting, so they can play the ability's animation on that unit's
## view (spec game-skeleton 3.7). The view calls release_execution() from the animation's `execute` keys and
## release_finished() when it ends. With `skip_all` every ability resolves at once (no animation).
## Whoever handles ability_began must release the gate, or the battle waits forever.
class_name ViewGate
extends ClientGate

signal ability_began(unit_id: StringName, ability: BattleAbility)

var skip_all: bool = false


func begin_ability(unit_id: StringName, ability: BattleAbility, sequence: Array[StringName]) -> void:
	super(unit_id, ability, sequence)
	if skip_all:
		release_finished()
		return
	ability_began.emit(unit_id, ability)
