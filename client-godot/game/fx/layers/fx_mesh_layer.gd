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


func kind() -> StringName:
	return &"mesh"


func native_space() -> int:
	return Space.WORLD_3D


func build() -> Node:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	if material != null:
		instance.material_override = material.duplicate()
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func natural_length(_node: Node, _params: Dictionary) -> float:
	return seconds


## The layer's time is up: the mesh goes away now, not when the rest of the effect ends.
func ended(node: Node) -> void:
	super(node)
	FxLayer.set_node_visible(node, false)


func extra_problems(_definition: FxDefinition, _probe: Node) -> PackedStringArray:
	var out := PackedStringArray()
	if mesh == null:
		out.append("fx_mesh_missing: mesh layer '%s' has no mesh" % id)
	return out
