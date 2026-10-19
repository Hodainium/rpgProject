## One choice on an event page. Shown disabled unless every condition holds; outcomes run in order.
## A choice whose outcomes neither go to a page nor start an encounter ends the event.
@tool
class_name EventChoice
extends Resource

@export var label: String = ""
@export var conditions: Array[RunCondition] = []
@export var outcomes: Array[RunOutcome] = []
