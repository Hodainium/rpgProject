## Project-specific GameplayAbility for battles (Lyra-style extension, client-godot/CLAUDE.md section 2).
##
## Adds targeting, the execution table and the animation that drives it. Activation runs the execution sequence
## read from the animation; before each execution it awaits the battle's presentation gate, which is the only thing
## a combat ability may await (spec "Zero-frame rule").
class_name BattleAbility
extends GameplayAbility

enum Targeting {
	SINGLE_ENEMY,  ## One opposing unit.
	ALL_ENEMIES,   ## Every living opposing unit.
	BLAST_ENEMY,   ## One opposing unit plus its living neighbours by slot.
	SINGLE_ALLY,   ## One unit on the actor's side (may be the actor).
	ALL_ALLIES,    ## Every living unit on the actor's side.
	SELF,          ## The actor.
}

@export var targeting: Targeting = Targeting.SINGLE_ENEMY
## What each hit does. The animation decides which rows run, how often and when.
@export var executions: Array[ExecutionRow] = []
## Required. Its `execute(&"<row id>")` method-track keys are the source of truth for the execution sequence.
@export var animation: Animation


## True when this targeting needs a target unit id in the action.
func needs_target() -> bool:
	return targeting in [Targeting.SINGLE_ENEMY, Targeting.BLAST_ENEMY, Targeting.SINGLE_ALLY]


func row_by_id(row_id: StringName) -> ExecutionRow:
	for row in executions:
		if row != null and row.id == row_id:
			return row
	return null


## Payload (set by Battle via try_activate): {"battle": Battle, "unit": BattleUnit, "primary": BattleUnit or null,
## "targets": Array[BattleUnit] in canonical order}.
func _activate_ability() -> bool:
	var action: Dictionary = current_event_payload
	var battle: Battle = action["battle"]
	var unit: BattleUnit = action["unit"]
	commit_ability()
	var sequence := ExecutionReader.sequence_for(animation)
	battle.gate.begin_ability(unit.unit_id, self, sequence)
	for row_id in sequence:
		await battle.gate.next_execution()
		battle.resolve_execution(unit, self, row_by_id(row_id), action)
	await battle.gate.finished()
	return true
