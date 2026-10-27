## Spec keys-and-gear 2.1: the golden key: locked rooms and chests open for free until the stairs.
@tool
class_name GiveGoldenKey
extends RunOutcome


func apply(run: Object) -> void:
	run.give_golden_key()
