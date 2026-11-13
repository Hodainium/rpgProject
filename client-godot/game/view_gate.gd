## ClientGate that tells the screens which unit is acting, so they can play the ability's animation on that unit's
## view (spec game-skeleton 3.7). The view calls release_execution() from the animation's `execute` keys and
## release_finished() when it ends. With `skip_all` every ability resolves at once (no animation).
## Whoever handles ability_began must release the gate, or the battle waits forever.
class_name ViewGate
extends ClientGate

signal ability_began(unit_id: StringName, ability: BattleAbility)

var skip_all: bool = false

## Spec battle-death-fade 3.3: the longest the battle's end waits for the screens, whatever is still holding it.
const HOLD_CAP: float = 3.0

## Emitted when the last open hold is released.
signal holds_released

## Open holds (id -> true): a view holding the battle's end while an enemy fades out.
var _holds: Dictionary = {}
var _next_hold: int = 0


func begin_ability(unit_id: StringName, ability: BattleAbility, sequence: Array[StringName]) -> void:
	super(unit_id, ability, sequence)
	if skip_all:
		release_finished()
		return
	ability_began.emit(unit_id, ability)


## A view starts holding the battle's end (an enemy fading out). Returns the id to release with end_hold().
func begin_hold() -> int:
	_next_hold += 1
	_holds[_next_hold] = true
	return _next_hold


## Releases a hold (once; an unknown id is ignored).
func end_hold(id: int) -> void:
	if _holds.erase(id) and _holds.is_empty():
		holds_released.emit()


## Open holds: the explicit ones plus every death fade still playing in the scene tree (DeathFadeDriver.GROUP; a view that is
## freed takes its fade with it, so a freed view never holds).
func open_holds() -> int:
	var count := _holds.size()
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		for driver in tree.get_nodes_in_group(DeathFadeDriver.GROUP):
			if not (driver as DeathFadeDriver).is_done():
				count += 1
	return count


## Waits until every open hold is released, at most HOLD_CAP seconds of game time (the fades' own clock, so a slowed engine
## waits as long as they take); at once with skip_all or no holds, and it stops waiting when skip_all is set during the wait.
## At the cap the explicit holds are cleared and the fades still running are finished at once, so none holds a later battle.
func hold_end() -> void:
	if skip_all or open_holds() == 0:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var waited := 0.0
	while open_holds() > 0 and waited < HOLD_CAP and not skip_all:
		await tree.process_frame
		waited += tree.root.get_process_delta_time()
	if skip_all:
		_finish_all()
		return
	if open_holds() > 0:
		push_warning("battle end: %d hold(s) still open after %.1f s; leaving the battle anyway" % [open_holds(), HOLD_CAP])
		_finish_all()


## Releases every explicit hold and ends every running death fade (its view hides).
func _finish_all() -> void:
	_holds.clear()
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for driver in tree.get_nodes_in_group(DeathFadeDriver.GROUP):
		(driver as DeathFadeDriver).finish_now()
