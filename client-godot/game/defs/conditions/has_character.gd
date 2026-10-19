@tool
class_name HasCharacter
extends RunCondition

@export var character: CharacterDefinition
## Only count living party members.
@export var alive_only: bool = true


func holds(run: Object) -> bool:
	return character != null and run.state.member_slot(character.id, alive_only) > 0
