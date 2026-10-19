@tool
class_name GoToPage
extends RunOutcome

@export var page: int = 0


func apply(run: Object) -> void:
	run.event_go_to_page(page)
