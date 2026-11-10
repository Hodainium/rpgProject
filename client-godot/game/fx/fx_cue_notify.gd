## A GameplayCue that plays an FxDefinition (spec vfx-framework F3): the bridge between GodotGAS and the effects
## system. Make a scene whose root has this script, set `fx` and its `bindings`, and register the scene under a
## `Cue.*` tag in godot_gas/cue_registry.tres. After that every GAS mechanism that triggers a cue plays the effect:
##   - an instant effect's `application_cue_tags` / `removal_cue_tags`: a one-shot on the target's view;
##   - a duration effect's `persistent_cue_tags`: a looping aura that fades out when the effect ends (end_cue);
##   - an ability's `execute_cue`, the same tag lists on items and passives.
## The target is the cue's target node: a battle unit (found through its `unit_id`), a Node3D or a Control. Nothing in
## GodotGAS is changed; this extends its GameplayCueNotify the way the sound cue does. Presentation only.
class_name FxCueNotify
extends GameplayCueNotify

@export var fx: FxDefinition
@export var bindings: Array[FxCueBinding] = []
## Spec vfx-content-pass: an effect this cue plays once on EACH unit named in the cue payload's `target_ids` (an ability passes the
## units it reaches when it executes the cue), `target_stagger` seconds apart, with its own parameter bindings. `fx` plays on the cue's
## own target (the caster); either may be empty.
@export var target_fx: FxDefinition
@export var target_bindings: Array[FxCueBinding] = []
@export var target_stagger: float = 0.0
## Seconds a looping effect takes to fade out when the cue ends.
@export var stop_fade: float = 0.25
## Shifts the effect from its target (world units).
@export var offset: Vector3 = Vector3.ZERO

## Tests point this at their own service; null = the FxManager autoload.
static var service_override: FxService

var _handle: FxHandle
## A persistent cue is "on" from execute_cue until it ends; while on, raising the quality tier starts its effect if it did
## not play (it played while effects were off).
var _on: bool = false
var _target: Node
var _payload: Dictionary = {}
## Counts plays of this (pooled) node, so a timer from an earlier play cannot end a later one.
var _play_id: int = 0


func execute_cue(target: Node, payload: Dictionary = {}) -> void:
	var service := _service()
	if service == null or (fx == null and target_fx == null) or not service.enabled:
		_end_when_free()  # headless (the verifier): nothing to draw, and no work per hit
		return
	_target = target
	_payload = payload
	if not auto_destroy:
		_on = true
		if not service.quality_changed.is_connected(_on_quality_changed):
			service.quality_changed.connect(_on_quality_changed)
	_play(service)


func _play(service: FxService) -> void:
	var target := _target
	var payload := _payload
	var params := {}
	for binding in bindings:
		var resolved: Variant = binding.resolve(target, payload)
		if resolved != null:
			params[binding.param] = resolved
	_play_on_targets(service, target, payload)
	if fx == null:
		_end_when_free()
		return
	_handle = service.play(fx, _anchor_for(target), params)
	if _handle.is_playing():
		if auto_destroy and not fx.is_looping():
			_handle.finished.connect(finish_cue, CONNECT_ONE_SHOT)
		elif auto_destroy:
			# A looping effect on a one-shot cue (listed in application_cue_tags instead of persistent_cue_tags): play it for
			# destroy_delay, then fade it out, so it cannot outlive the cue.
			var play_id := _play_id
			get_tree().create_timer(destroy_delay).timeout.connect(func() -> void:
				if play_id == _play_id:  # the cue may have finished and been pooled for another play since
					end_cue(), CONNECT_ONE_SHOT)
	else:
		_end_when_free()


## Plays `target_fx` on every unit in the payload's `target_ids`, staggered. Each play is its own handle, so the cue need not wait for it.
func _play_on_targets(service: FxService, target: Node, payload: Dictionary) -> void:
	if target_fx == null:
		return
	var params := {}
	for binding in target_bindings:
		var resolved: Variant = binding.resolve(target, payload)
		if resolved != null:
			params[binding.param] = resolved
	var ids: Array = payload.get("target_ids", [])
	for index in ids.size():
		var anchor := FxAnchor.unit(ids[index])
		if index == 0 or target_stagger <= 0.0 or not is_inside_tree():
			service.play(target_fx, anchor, params)
		else:
			var effect := target_fx
			get_tree().create_timer(target_stagger * index).timeout.connect(func() -> void:
				if is_instance_valid(service):
					service.play(effect, anchor, params))


## A persistent cue ends: fade a looping effect out, then hand the node back.
func end_cue() -> void:
	_on = false
	if _handle != null and _handle.is_playing():
		if not _handle.finished.is_connected(finish_cue):
			_handle.finished.connect(finish_cue, CONNECT_ONE_SHOT)
		_handle.stop(stop_fade)
	else:
		finish_cue()


func finish_cue() -> void:
	_on = false
	_handle = null
	var service := _service()
	if service != null and service.quality_changed.is_connected(_on_quality_changed):
		service.quality_changed.disconnect(_on_quality_changed)
	_play_id += 1
	super()


## The tier was raised while this persistent cue is on and its effect is not playing (it played at off): start it now.
func _on_quality_changed(_tier: int) -> void:
	var service := _service()
	if _on and service != null and is_instance_valid(_target) and (_handle == null or not _handle.is_playing()):
		_play(service)


func _anchor_for(target: Node) -> FxAnchor:
	if target != null and "unit_id" in target and target.unit_id != &"":
		return FxAnchor.unit(target.unit_id, offset)
	if target is Node3D:
		return FxAnchor.node3d(target, offset)
	if target is Control:
		return FxAnchor.control(target)
	return FxAnchor.screen()


## An inert play (headless, effects off, unknown id): a one-shot cue is over at once; a persistent one waits for end_cue.
func _end_when_free() -> void:
	if auto_destroy:
		finish_cue()  # at once: GodotGAS's manager copes with a cue that finishes inside execute_cue


func _service() -> FxService:
	if service_override != null:
		return service_override
	return Engine.get_main_loop().root.get_node_or_null("FxManager") as FxService if Engine.get_main_loop() is SceneTree else null
