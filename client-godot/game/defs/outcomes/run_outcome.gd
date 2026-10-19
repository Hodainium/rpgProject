## Base class for event outcomes and item run hooks (spec game-skeleton, section 3.1). Content can add subclasses.
## Outcomes change run state only through RunController methods, so every change is logged and seeded.
@tool
class_name RunOutcome
extends Resource


## `run` is the RunController.
func apply(_run: Object) -> void:
	pass
