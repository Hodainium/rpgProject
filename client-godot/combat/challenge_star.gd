## One star of a challenge (spec economy-challenges): a condition on a finished battle. Whole numbers only; nothing here
## draws from the RNG or reads anything but the battle's final state, so the replay and the client agree.
@tool
class_name ChallengeStar
extends Resource

enum Kind {
	## The party won.
	WIN,
	## The party won in at most `value` battle turns.
	TURNS_AT_MOST,
	## The party won and every party unit is standing at the end.
	PARTY_ALIVE,
}

@export var kind: Kind = Kind.WIN
## TURNS_AT_MOST: the turn limit. Unused by the other kinds.
@export var value: int = 0


## True when `battle` (finished) satisfies this star.
func reached(battle: Battle) -> bool:
	if battle.outcome != "Victory":
		return false
	match kind:
		Kind.WIN:
			return true
		Kind.TURNS_AT_MOST:
			return battle.turn <= value
		Kind.PARTY_ALIVE:
			for unit in battle.units():
				if unit.side == BattleUnit.Side.PARTY and not unit.alive:
					return false
			return true
	return false
