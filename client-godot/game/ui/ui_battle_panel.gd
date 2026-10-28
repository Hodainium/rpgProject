## Spec ff7-ui 2.3 / 2.12 (F15): the base of every battle HUD panel (party window, command window, hint window, turn
## order). It finds the shown battle, its ActionRecorder and its ViewGate once, and calls battle_changed() whenever
## something a panel draws may differ (a turn, a hit, a break, an ult, a death…), at most once a frame. Panels read the
## battle; they change it only through the recorder, never directly.
class_name UIBattlePanel
extends UIScreen

## The battle signals after which a panel may look different, with their argument counts.
const REDRAW_SIGNALS := {&"turn_started": 2, &"execution_resolved": 3, &"unit_broken": 2, &"unit_recovered": 1,
	&"interrupt_started": 2, &"damage_drained": 3, &"action_delayed": 2, &"unit_downed": 2, &"unit_died": 1,
	&"unit_revived": 1, &"one_more_started": 1, &"phase_changed": 2, &"damage_dealt": 4}

var battle: Battle
var recorder: ActionRecorder
var gate: ViewGate
var _queued: bool = false


func bind(context: UIContext) -> void:
	context.main.battle_prepared.connect(_on_battle_prepared)
	context.on_run(self, &"battle_started", _on_battle_started)
	context.on_run(self, &"battle_finished", _on_battle_finished)
	# A panel made after battle_prepared fired for this battle takes the battle's recorder and gate now.
	if context.main.recorder != null and context.main.gate != null:
		_on_battle_prepared(context.main.recorder, context.main.gate)
	# Spec ui-fixes B3: and one made after battle_started (a clicked room starts the battle before the deferred UI
	# state adds the panels) takes the running battle.
	if context.run != null and context.run.current_battle != null:
		_on_battle_started(context.run.current_battle)


## Override: a new battle and its recorder are ready (connect to recorder signals here).
func on_recorder(_recorder: ActionRecorder) -> void:
	pass


## Override: the battle started (or the panel came up during one).
func on_battle(_battle: Battle) -> void:
	pass


## Override: the battle ended; battle is null afterwards.
func on_battle_end() -> void:
	pass


## Override: redraw from battle and recorder.
func battle_changed() -> void:
	pass


## Asks for battle_changed() at the end of this frame (many signals in one action redraw once).
func changed() -> void:
	if _queued:
		return
	_queued = true
	_redraw.call_deferred()


func _redraw() -> void:
	_queued = false
	if is_instance_valid(self) and battle != null:
		battle_changed()


func _on_battle_prepared(new_recorder: ActionRecorder, new_gate: ViewGate) -> void:
	if new_recorder == recorder:
		return
	recorder = new_recorder
	gate = new_gate
	on_recorder(recorder)
	changed()


func _on_battle_started(new_battle: Battle) -> void:
	if new_battle == battle:
		return
	battle = new_battle
	for signal_name in REDRAW_SIGNALS:
		battle.connect(signal_name, _on_any.unbind(REDRAW_SIGNALS[signal_name]))
	on_battle(battle)
	changed()


func _on_any() -> void:
	changed()


func _on_battle_finished(_outcome: String) -> void:
	battle = null
	on_battle_end()
