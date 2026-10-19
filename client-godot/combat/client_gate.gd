## Presentation gate for the playable client.
##
## Presentation drives it from the animation: an `execute` key calls release_execution(row_id), the end of the
## animation calls release_finished(), and skip() releases everything that is left. Executions always resolve in
## the sequence order read from the animation; a release naming a different row than expected is reported and
## still releases the next entry in order.
class_name ClientGate
extends PresentationGate

signal released

var _sequence: Array[StringName] = []
var _released: int = 0
var _consumed: int = 0
var _finished: bool = false


func begin_ability(_unit_id: StringName, _ability: BattleAbility, sequence: Array[StringName]) -> void:
	_sequence = sequence
	_released = 0
	_consumed = 0
	_finished = false


func next_execution() -> void:
	while _released <= _consumed:
		await released
	_consumed += 1


func finished() -> void:
	while not _finished:
		await released


## Called from an animation `execute` key.
func release_execution(row_id: StringName = &"") -> void:
	if _released >= _sequence.size():
		return
	var expected := _sequence[_released]
	if row_id != &"" and row_id != expected:
		push_warning("ClientGate: animation released '%s' but the sequence expects '%s'." % [row_id, expected])
	_released += 1
	released.emit()


## Called when the ability's animation ends. Any executions not yet released resolve now, in order.
func release_finished() -> void:
	_released = _sequence.size()
	_finished = true
	released.emit()


## Skips the rest of the animation: same as the animation ending now.
func skip() -> void:
	release_finished()
