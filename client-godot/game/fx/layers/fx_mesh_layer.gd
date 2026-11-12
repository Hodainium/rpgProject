## A real mesh in the effect (spec vfx-content-pass): a rock, a spike, a blade, a shield plate, with its own material. It is placed at its
## socket like any layer and animated by curve tracks (position, rotation, scale: a meteor falling and tumbling, a spike rising). Bind the
## material's parameters with "material_override:shader_parameter/<uniform>". The mesh and material are resources you set in the inspector;
## each play gets its own copy of the material, so one play's colour never leaks into another. The node goes away when the layer's time is up.
## Presentation only.
class_name FxMeshLayer
extends FxLayer

@export var mesh: Mesh
@export var material: Material
## How long the layer lives (a mesh has no natural length).
@export var seconds: float = 1.0
@export var cast_shadow: bool = false
## Spec vfx-stencil 3.3: does the mesh draw over the unit it sits on? AUTO: no, a solid mesh (a rock, a spike) keeps the plain depth
## test; set ON for a see-through shell around the unit (a shield). Only a ShaderMaterial whose shader includes the stencil lines
## (fx_stencil_depth.gdshaderinc) can.
@export var over_own_unit: FxLayer.OverOwnUnit = FxLayer.OverOwnUnit.AUTO


func kind() -> StringName:
	return &"mesh"


func native_space() -> int:
	return Space.WORLD_3D


func build() -> Node:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	if material is ShaderMaterial and FxStencilShaders.supports((material as ShaderMaterial).shader):
		instance.material_override = _stencil_copy(material as ShaderMaterial)
	elif material != null:
		instance.material_override = material.duplicate()
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func natural_length(_node: Node, _params: Dictionary) -> float:
	return seconds


func stencil_shader() -> Shader:
	var source := material as ShaderMaterial
	return source.shader if source != null and draws_over_own_unit(over_own_unit) and FxStencilShaders.supports(source.shader) else null


func apply(node: Node, params: Dictionary, anchor: FxAnchor, quality: int, definition: FxDefinition) -> void:
	super(node, params, anchor, quality, definition)
	var stencil := (node as MeshInstance3D).material_override as FxStencilMaterial
	if stencil != null:
		stencil.stencil_unit = stencil_value(anchor, stencil.base_shader, over_own_unit)


func update(node: Node, local_time: float, length_seconds: float, params: Dictionary) -> void:
	super(node, local_time, length_seconds, params)
	var stencil := (node as MeshInstance3D).material_override as FxStencilMaterial
	if stencil != null:
		follow_stencil(node, stencil, stencil.base_shader, over_own_unit)


## Spec vfx-stencil 3.4: the layer's material as a material with a stencil setting (its own copy, every value carried over).
static func _stencil_copy(source: ShaderMaterial) -> FxStencilMaterial:
	var copy := FxStencilMaterial.new()
	copy.base_shader = source.shader
	copy.render_priority = source.render_priority
	for key in FxStencilShaders.uniform_names(source.shader):
		var value: Variant = source.get_shader_parameter(key)
		if value != null:
			copy.set_shader_parameter(key, value)
	return copy


## The layer's time is up: the mesh goes away now, not when the rest of the effect ends.
func ended(node: Node) -> void:
	super(node)
	FxLayer.set_node_visible(node, false)


func extra_problems(_definition: FxDefinition, _probe: Node) -> PackedStringArray:
	var out := PackedStringArray()
	if mesh == null:
		out.append("fx_mesh_missing: mesh layer '%s' has no mesh" % id)
	if over_own_unit == OverOwnUnit.ON and not (material is ShaderMaterial and FxStencilShaders.supports((material as ShaderMaterial).shader)):
		out.append("fx_stencil_include_missing: mesh layer '%s' draws over its unit, but only a ShaderMaterial whose shader includes %s can"
			% [id, FxStencilShaders.INCLUDE])
	return out
