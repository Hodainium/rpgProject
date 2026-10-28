## Spec ff7-ui 2.2 (F10): what a toast host shows and how. One set per host (the run's toasts, the battle feed); a
## new toast is a new rule here, never code.
class_name UIToastSet
extends Resource

enum Stack {
	QUEUE,  ## One after another: a new toast waits while max_visible are showing.
	STACK,  ## Lines pile up at once; past max_visible the oldest leaves.
}

@export var rules: Array[UIToastRule] = []
@export var stack: Stack = Stack.QUEUE
@export var max_visible: int = 1
## STACK only (spec ui-fixes B4): 0 = max_visible is a hard cap (the oldest leaves at once). Above 0 it is a soft cap:
## more may show, and each toast over it expires early, the oldest first, one every this many seconds (it leaves
## through leave_fast()).
@export var overflow_seconds: float = 0.0
## QUEUE only: toasts waiting beyond this are dropped, lowest priority (then oldest) first.
@export var max_queued: int = 5
## The toast scene; its root script has set_item(toast: Dictionary, ctx) and may have leave() (fade out, then free
## itself). Empty: a plain Label.
@export var entry_scene: PackedScene
## Channels that clear every toast (the battle feed clears on Message.Battle.Started and .Ended).
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var clear_on: Array[StringName] = []
