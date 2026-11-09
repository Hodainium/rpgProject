## A plain Node that carries named values, so a layer with no engine node of its own (a shake, a tween, a sub-effect)
## can still be driven by bindings and tracks: `set_indexed("strength_px", 3.0)` writes the value, `get` reads it.
## Layer kinds you write yourself can reuse it: `FxValueNode.new().declare({"my_value": 1.0})`.
class_name FxValueNode
extends Node

var _values: Dictionary = {}


## Declares the values (name → default). Returns self.
func declare(defaults: Dictionary) -> FxValueNode:
	_values = defaults.duplicate()
	return self


func value(value_name: StringName, fallback: Variant = null) -> Variant:
	return _values.get(value_name, fallback)


func _get(property: StringName) -> Variant:
	if _values.has(property):
		return _values[property]
	return null


func _set(property: StringName, new_value: Variant) -> bool:
	if _values.has(property):
		_values[property] = new_value
		return true
	return false


func _get_property_list() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	for key in _values:
		list.append({"name": key, "type": typeof(_values[key]), "usage": PROPERTY_USAGE_SCRIPT_VARIABLE})
	return list
