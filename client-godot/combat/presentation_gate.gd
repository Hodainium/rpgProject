## Where combat waits for presentation (spec "Execution table and animation events").
##
## Before each execution an ability awaits next_execution(); after the last one it awaits finished().
## This base class is the headless gate: every call returns immediately, as if every animation were skipped,
## so a replay finishes without yielding a frame. ClientGate waits for animation events instead.
##
## The gate only decides WHEN executions happen. Which rows run, and in what order, comes from the
## animation's execute keys (ExecutionReader), so timing can never change a result.
class_name PresentationGate
extends RefCounted


## Called when an ability starts, with its execution sequence.
func begin_ability(_unit_id: StringName, _ability: BattleAbility, _sequence: Array[StringName]) -> void:
	pass


## Waits until the next execution may resolve.
func next_execution() -> void:
	pass


## Waits until the ability's animation has ended (or been skipped).
func finished() -> void:
	pass


## Spec battle-death-fade 3.3: waits, after a battle's result is final, until the screens are done with it (an enemy still
## fading out). The headless gate returns at once: replays, traces, steps and tests never wait.
func hold_end() -> void:
	pass
