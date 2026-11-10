## An effect asset (spec vfx-framework 3.1): the Niagara System. Layers (particles, shader quads, lights, sounds,
## shakes, tweens, sub-effects…) plus the exposed parameters that tune them. Register it in an FxRegistry and play it by
## id: FxManager.play(&"fx.glow_burst", anchor, {color = Color.GOLD}). New effects are data, never code.
## Presentation only: effects never touch combat or run state.
class_name FxDefinition
extends Resource

## WORLD_3D: made for 3D anchors; UI: for a Control (no 3D layers); SCREEN: over the whole window; HYBRID: layers pick
## their own space (a 3D burst plus a 2D flash).
enum Space { WORLD_3D, UI, SCREEN, HYBRID }

@export var id: StringName
@export var display_name: String = ""
@export var params: Array[FxParam] = []
@export var layers: Array[FxLayer] = []
@export var space: Space = Space.WORLD_3D
## Spec vfx-content-pass 3.6: where on a unit the effect attaches by default (an FxSocket role: Center, Hit, Top, Base). A play's
## anchor can name another; a layer can move itself to another (FxLayer.socket).
@export var socket: StringName = &"Center"
## Instances kept ready in the pool.
@export var pool_size: int = 4
## Playing at once; beyond it the oldest is recycled (a spam guard).
@export var max_instances: int = 16
## Asset tags (e.g. Fx.Kind.Burst) for search and filters.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var tags: Array[StringName] = []
@export_multiline var description: String = ""


func param(param_name: StringName) -> FxParam:
	for spec in params:
		if spec != null and spec.name == param_name:
			return spec
	return null


## {name: default} for every declared parameter.
func default_params() -> Dictionary:
	var out := {}
	for spec in params:
		if spec != null:
			out[spec.name] = spec.default()
	return out


## True when any layer loops: the effect plays until its handle is stopped.
func is_looping() -> bool:
	for layer in layers:
		if layer != null and layer.loop:
			return true
	return false


## Finds a layer by id (null when none).
func layer(layer_id: StringName) -> FxLayer:
	for candidate in layers:
		if candidate != null and candidate.id == layer_id:
			return candidate
	return null


## Everything an author should fix, one line each. Used by the validator and `fx check`.
func problems() -> PackedStringArray:
	var out := PackedStringArray()
	if id == &"":
		out.append("fx_no_id: the effect has no id")
	if layers.is_empty():
		out.append("fx_no_layers: %s has no layers" % id)
	var seen := {}
	for spec in params:
		if spec == null:
			out.append("fx_param_invalid: %s has an empty parameter slot" % id)
		elif spec.name == &"":
			out.append("fx_param_invalid: %s has a parameter with no name" % id)
		elif seen.has(spec.name):
			out.append("fx_param_duplicate: %s declares the parameter '%s' twice" % [id, spec.name])
		else:
			seen[spec.name] = true
			if not spec.accepts(spec.default_value):
				out.append("fx_param_default: %s: the default of '%s' is not a %s" % [id, spec.name, FxParam.Kind.keys()[spec.kind].to_lower()])
	var layer_ids := {}
	for layer in layers:
		if layer == null:
			out.append("fx_layer_empty: %s has an empty layer slot" % id)
			continue
		if layer.id != &"" and layer_ids.has(layer.id):
			out.append("fx_layer_duplicate: %s has two layers named '%s'" % [id, layer.id])
		layer_ids[layer.id] = true
		out.append_array(layer.problems(self))
		if space == Space.UI and layer.resolved_space(int(space)) == FxLayer.Space.WORLD_3D:
			out.append("fx_space_mismatch: %s is a UI effect but layer '%s' is 3D" % [id, layer.id])
	return out
