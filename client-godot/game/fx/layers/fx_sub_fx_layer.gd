## Plays another effect from this one (spec vfx-framework 3.1): after the layer's delay, at the same anchor, with
## parameters mapped from this effect's. `param_map` is {sub parameter: "$parent_param" or a literal}. The layer lasts as
## long as the sub-effect (a looping sub-effect keeps the parent alive until stopped); stopping the parent stops it.
## Nesting is capped (FxService.MAX_DEPTH) so an effect that contains itself cannot run away.
class_name FxSubFxLayer
extends FxLayer

@export var effect: FxDefinition
@export var param_map: Dictionary = {}

const HANDLE: StringName = &"fx_sub_handle"


func kind() -> StringName:
	return &"sub_fx"


func build() -> Node:
	return FxValueNode.new()


func start(node: Node) -> void:
	super(node)
	var service: FxService = FxLayer.meta_of(node, FxService.META_SERVICE)
	if service == null or effect == null:
		return
	var params: Dictionary = node.get_meta(META_PARAMS, {})
	var mapped := {}
	for key in param_map:
		var value: Variant = param_map[key]
		if (value is String or value is StringName) and String(value).begins_with("$"):
			var source := StringName(String(value).substr(1))
			if params.has(source):
				mapped[key] = params[source]
		else:
			mapped[key] = value
	node.set_meta(HANDLE, service.play_nested(effect, node.get_meta(META_ANCHOR), mapped, int(node.get_meta(FxService.META_DEPTH, 0)) + 1))


func stop(node: Node, fade: float) -> void:
	var handle: FxHandle = FxLayer.meta_of(node, HANDLE)
	if handle != null and handle.is_playing():
		handle.stop(fade)


func reset(node: Node) -> void:
	var handle: FxHandle = FxLayer.meta_of(node, HANDLE)
	if handle != null and handle.is_playing():
		handle.stop(0.0)
	node.set_meta(HANDLE, null)
	super(node)


func is_finished(node: Node) -> bool:
	var handle: FxHandle = FxLayer.meta_of(node, HANDLE)
	return handle == null or not handle.is_playing()


func tail(node: Node) -> float:
	var handle: FxHandle = FxLayer.meta_of(node, HANDLE)
	if handle != null and handle.is_playing():
		return maxf(handle.stop_at - handle.elapsed, 0.0)  # its particles in the air still need their time
	return 0.0


## A sub-effect runs until it is over, whatever the layer's own duration says.
func length(_node: Node, _params: Dictionary) -> float:
	return INF


func extra_problems(definition: FxDefinition, _probe: Node) -> PackedStringArray:
	var out := PackedStringArray()
	if effect == null:
		out.append("fx_sub_missing: layer '%s' plays no effect" % id)
	elif effect == definition or _reaches(effect, definition, 0):
		out.append("fx_cycle: layer '%s' plays %s, which plays this effect again" % [id, effect.id])
	else:
		for key in param_map:
			if effect.param(StringName(key)) == null:
				out.append("fx_param_missing: layer '%s' maps '%s', which %s does not declare" % [id, key, effect.id])
	for key in param_map:
		var value: Variant = param_map[key]
		if (value is String or value is StringName) and String(value).begins_with("$") \
				and definition.param(StringName(String(value).substr(1))) == null:
			out.append("fx_param_missing: layer '%s' maps '%s' from the undeclared parameter '%s'" % [id, key, value])
	return out


static func _reaches(from: FxDefinition, target: FxDefinition, depth: int) -> bool:
	if depth > FxService.MAX_DEPTH:
		return true
	for layer in from.layers:
		if layer is FxSubFxLayer and layer.effect != null:
			if layer.effect == target or _reaches(layer.effect, target, depth + 1):
				return true
	return false
