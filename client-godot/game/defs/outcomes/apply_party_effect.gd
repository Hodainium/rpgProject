## Applies a GameplayEffect to party members through the field context (heals, damage, MP, ult charge, revives).
@tool
class_name ApplyPartyEffect
extends RunOutcome

@export var effect: GameplayEffect
## Also apply to dead members (an effect that raises HP above 0 revives them).
@export var include_dead: bool = false


func apply(run: Object) -> void:
	run.apply_party_effect(effect, include_dead)
