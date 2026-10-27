## Spec keys-and-gear 3.2: keys for the party (up to 99). Not doubled by Run.Keys.Double (only found keys are).
@tool
class_name GainKeys
extends RunOutcome

@export var amount: int = 1


func apply(run: Object) -> void:
	run.add_keys(amount)
