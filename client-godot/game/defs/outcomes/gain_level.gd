## Spec playable-demo 3.11 (D28): free levels for every living member (or only `character`).
@tool
class_name GainLevel
extends RunOutcome

@export var count: int = 1
@export var character: CharacterDefinition


func apply(run: Object) -> void:
	run.gain_levels(count, character)
