## A layer property driven by an FxDefinition parameter (spec vfx-framework 3.1): value = param * scale + offset, with
## an optional remap curve for a float. `property` is a NodePath-style path on the layer's node, e.g. "amount",
## "process_material:color" or "material:shader_parameter/glow_color". Presentation only.
class_name FxBinding
extends Resource

@export var property: String
@export var param: StringName
@export var scale: float = 1.0
@export var offset: float = 0.0
## Remaps a float: the parameter, normalised over its range (0..1 when it has none), samples this curve first.
@export var curve: Curve


## The value to write for the parameter's value `raw` (`definition` gives the range for the curve).
func value_for(raw: Variant, definition: FxParam = null) -> Variant:
	if raw is float or raw is int:
		var value := float(raw)
		if curve != null:
			var ranged := definition != null and definition.max_value > definition.min_value
			var low := definition.min_value if ranged else 0.0
			var high := definition.max_value if ranged else 1.0
			value = curve.sample_baked(clampf((value - low) / (high - low), 0.0, 1.0))
		return value * scale + offset
	if raw is Color:
		return Color(raw.r * scale, raw.g * scale, raw.b * scale, raw.a) if scale != 1.0 else raw
	if raw is Vector2:
		return raw * scale + Vector2(offset, offset)
	if raw is Vector3:
		return raw * scale + Vector3(offset, offset, offset)
	return raw


## Writes the bound parameter onto `target` when `params` has it. False when nothing was written.
func apply_to(target: Object, params: Dictionary, definition: FxDefinition) -> bool:
	if property == "" or not params.has(param) or target == null:
		return false
	var spec: FxParam = definition.param(param) if definition != null else null
	target.set_indexed(NodePath(property), value_for(params[param], spec))
	return true


## True when the first segment of `property` is a real property of `node` (ShaderMaterial's "shader_parameter/x" and
## nested paths are checked by their head only: the rest resolves at run time).
func resolves_on(node: Object) -> bool:
	return property_resolves(node, property)


static func property_resolves(node: Object, path: String) -> bool:
	if node == null or path == "":
		return false
	var head := path.split(":")[0].split("/")[0]
	for info in node.get_property_list():
		if info["name"] == head:
			return true
	return false
