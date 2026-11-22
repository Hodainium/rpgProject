## Spec event-pass 2.2: a GameplayEffect on one member, several or everyone, through the run's field context (the same
## path as ApplyPartyEffect). A member brought to 0 HP is dead; a party wipe ends the run. A kill is just an effect.
@tool
class_name ApplyMemberEffect
extends RunOutcome

enum Target {
	FIRST,  ## The first living member by slot.
	SLOT,  ## The member at party position `slot` (nobody when that place is empty, or dead without include_dead).
	RANDOM,  ## A seeded pick among the living members (dead ones too with include_dead).
	LOWEST_HP,  ## The living member with the lowest HP share (ties: the lowest slot).
	CHARACTER,  ## The member playing `character`.
	ALL,  ## Every living member (dead ones too with include_dead), like ApplyPartyEffect.
}

@export var effect: GameplayEffect
@export var target: Target = Target.FIRST
@export_range(1, 4) var slot: int = 1
@export var character: CharacterDefinition
@export var include_dead: bool = false


func apply(run: Object) -> void:
	run.event_member_effect(effect, target, slot, character, include_dead)
