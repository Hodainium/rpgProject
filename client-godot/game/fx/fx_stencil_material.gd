## A shader material with a stencil setting (spec vfx-stencil 3.4), used like `stencil_reference` on a StandardMaterial3D: set
## `stencil_unit` and the material draws over that unit's stamped pixels. Godot takes the reference only as a literal in shader code
## (the probe's K5), so behind the setting the material swaps its shader for a cached copy (FxStencilShaders) and adds the OWN pass
## as its next_pass. 0 puts `base_shader` back, one pass, exactly today's material. Parameter values carry over every swap.
## The OWN pass mirrors this material's parameters through sync_own_pass(): effect bindings write the material through the engine
## (`material:shader_parameter/x`), which a script cannot intercept, so the owner calls it after writing (the layer, every tick).
## A shader that does not include fx_depth_bias.gdshaderinc has no stencil lines, so it stays one pass whatever the setting.
## Presentation only.
class_name FxStencilMaterial
extends ShaderMaterial

## The shader the material draws with when `stencil_unit` is 0, and the one its copies are made from.
var base_shader: Shader:
	set(value):
		base_shader = value
		_refresh()

## The unit whose stamped pixels the material draws over (StencilIds unit range); 0 = none.
var stencil_unit: int = 0:
	set(value):
		stencil_unit = value
		_refresh()

## The uniform names the OWN pass mirrors (read once per shader swap, never per frame).
var _names: Array[StringName] = []


## The value the material actually draws with: stencil_unit when its shader supports it, else 0.
func effective_unit() -> int:
	return stencil_unit if StencilIds.is_unit(stencil_unit) and FxStencilShaders.supports(base_shader) else StencilIds.NONE


## Re-checks the shader (a hot-reloaded base shader gets fresh copies) and brings the OWN pass up to date.
func refresh() -> void:
	_refresh()


## Copies this material's parameters to the OWN pass (after bindings or tracks wrote them).
func sync_own_pass() -> void:
	var own := next_pass as ShaderMaterial
	if own == null:
		return
	own.render_priority = render_priority  # both halves of one effect sort the same against other transparents
	for key in _names:
		var value: Variant = get_shader_parameter(key)
		if value != null:
			own.set_shader_parameter(key, value)


func _refresh() -> void:
	if base_shader == null:
		return
	var unit := effective_unit()
	var wanted := base_shader if unit == StencilIds.NONE else FxStencilShaders.variant(base_shader, unit, FxStencilShaders.Pass.OTHER)
	var own_wanted: Shader = null if unit == StencilIds.NONE else FxStencilShaders.variant(base_shader, unit, FxStencilShaders.Pass.OWN)
	var own := next_pass as ShaderMaterial
	if shader == wanted and (own.shader if own != null else null) == own_wanted:
		sync_own_pass()
		return
	var saved := {}
	if shader != null:
		for key in FxStencilShaders.uniform_names(shader):
			var value: Variant = get_shader_parameter(key)
			if value != null:
				saved[key] = value
	shader = wanted
	if own_wanted == null:
		next_pass = null
	else:
		if own == null:
			own = ShaderMaterial.new()
		own.shader = own_wanted
		own.render_priority = render_priority
		next_pass = own
	for key in saved:
		set_shader_parameter(key, saved[key])
	_names = FxStencilShaders.uniform_names(shader)
	sync_own_pass()
