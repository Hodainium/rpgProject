## Spec event-pass 2.2: a weighted pick of the next page (a gamble), on the event's own stream
## floor/<n>/event_roll/<cell>/<k>. A page may be the one the choice is on, so a choice can be taken again.
@tool
class_name GoToRandomPage
extends RunOutcome

@export var pages: Array[int] = []
## The weights as typed (1 = normal, 3 = three times as likely), one per page. Editor-only view of weights_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var weights: Array[float]:
	get:
		var typed: Array[float] = []
		for value in weights_x100:
			typed.append(Fixed.to_display(value))
		return typed
	set(typed):
		weights_x100.clear()
		for value in typed:
			weights_x100.append(Fixed.from_typed(value))

@export_storage var weights_x100: Array[int] = []


func apply(run: Object) -> void:
	run.event_random_page(pages, weights_x100)
