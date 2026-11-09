## A light pulse (spec vfx-framework 3.1): an OmniLight3D whose energy follows `curve` over the layer. Bind
## "light_color", "light_energy" (the peak), "omni_range"… 3D only.
class_name FxLightLayer
extends FxLayer

@export var color: Color = Color.WHITE
@export var energy: float = 2.0
@export var light_range: float = 4.0
## Energy over the layer's 0..1 time; none = a quick fade out.
@export var curve: Curve
@export var seconds: float = 0.3

const PEAK: StringName = &"fx_peak"


func kind() -> StringName:
	return &"light"


func native_space() -> int:
	return Space.WORLD_3D


func build() -> Node:
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = energy
	light.omni_range = light_range
	light.shadow_enabled = false
	return light


## A live retune of a bound light_energy sets the new peak (update writes peak * curve every tick).
func rebind(node: Node, params: Dictionary, definition: FxDefinition) -> void:
	super(node, params, definition)
	for binding in bindings:
		if binding.property == "light_energy":
			node.set_meta(PEAK, node.light_energy)


func start(node: Node) -> void:
	super(node)
	node.set_meta(PEAK, node.light_energy)


func update(node: Node, local_time: float, length_seconds: float, params: Dictionary) -> void:
	var u := progress(local_time, length_seconds)
	node.light_energy = float(node.get_meta(PEAK, energy)) * (curve.sample_baked(u) if curve != null else 1.0 - u)
	super(node, local_time, length_seconds, params)


func reset(node: Node) -> void:
	node.light_energy = float(node.get_meta(PEAK, energy))
	super(node)


func natural_length(_node: Node, _params: Dictionary) -> float:
	return seconds
