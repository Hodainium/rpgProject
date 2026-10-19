## Starts a battle in the current room; the event ends when it does.
@tool
class_name StartEncounter
extends RunOutcome

@export var encounter: EncounterDefinition


func apply(run: Object) -> void:
	run.event_start_encounter(encounter)
