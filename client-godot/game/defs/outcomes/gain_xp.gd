## Spec playable-demo 3.11 (D28): XP for every living member (or only `character`); level-ups follow at once.
@tool
class_name GainXp
extends RunOutcome

@export var amount: int = 0
@export var character: CharacterDefinition


func apply(run: Object) -> void:
	run.gain_xp(amount, character)
