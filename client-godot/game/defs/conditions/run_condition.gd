## Base class for event-choice conditions (spec game-skeleton, section 3.1). Content can add subclasses.
@tool
class_name RunCondition
extends Resource


## `run` is the RunController.
func holds(_run: Object) -> bool:
	return true
