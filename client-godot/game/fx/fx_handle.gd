## What FxManager.play returns (spec vfx-framework 3.2): a live effect you can retune (set_param), stop (fade out) and
## watch (finished). An inert handle (unknown id, effects off, headless) does nothing and is never playing.
class_name FxHandle
extends RefCounted

enum LayerState { SKIPPED, PENDING, RUNNING, DONE }

## Emitted once, when the effect is over and its instance went back to the pool.
signal finished

var definition: FxDefinition
var anchor: FxAnchor
var params: Dictionary = {}
var instance: FxInstance
var service: FxService
var depth: int = 0
var elapsed: float = 0.0
var stopping: bool = false
var stop_at: float = 0.0
var done: bool = false
var inert: bool = false
## Its layers are being ticked right now (a nested play must not recycle or re-tick it).
var ticking: bool = false
## Per layer slot.
var states: PackedInt32Array = PackedInt32Array()
var starts: PackedFloat64Array = PackedFloat64Array()
var ends: PackedFloat64Array = PackedFloat64Array()
## How the 2D holder follows the anchor (set by FxService).
var ui_follow: int = 0


static func make_inert(def: FxDefinition = null) -> FxHandle:
	var handle := FxHandle.new()
	handle.definition = def
	handle.inert = true
	handle.done = true
	return handle


func is_playing() -> bool:
	return not done


## Changes a parameter of the running effect; its bound layer properties follow at once.
func set_param(param_name: StringName, value: Variant) -> void:
	if service != null and not done:
		service.set_handle_param(self, param_name, value)


## Fade the effect out over `fade` seconds (a looping aura needs this; a one-shot may be cut short).
func stop(fade: float = 0.2) -> void:
	if service != null and not done:
		service.stop_handle(self, fade)
