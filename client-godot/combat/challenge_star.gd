## One star of a challenge (spec economy-challenges): a list of conditions that must ALL hold on a battle the party won. A
## star with no conditions is "win the encounter". Everything it asks is data (see `ChallengeCondition`); this class has no
## rules of its own. A star is independent of the others: earning it never depends on another star.
@tool
class_name ChallengeStar
extends Resource

## Names the star inside its challenge ("win", "fast", "flawless"): the last part of its server reward id. 1-100 characters,
## no ':' , no '/' and no whitespace; unique within the challenge. Keep it stable once players have earned it.
@export var id: StringName = &""
## Shown to the player ("Win in 25 turns or fewer"). Optional.
@export var description: String = ""
## All must hold. Empty = just win.
@export var conditions: Array[ChallengeCondition] = []


## True when `battle` (finished) is a victory that satisfies every condition.
func reached(battle: Battle, tally: ChallengeTally = null) -> bool:
	if battle.outcome != "Victory":
		return false
	for condition in conditions:
		if condition == null or not condition.met(battle, tally):
			return false
	return true
