## A shader-drawn quad (spec vfx-framework 3.1): glows, auras, foil, rays, flashes, vignettes, dissolves. In UI space a
## ColorRect over the effect's rectangle (`grow` pixels bigger on every side so a glow bleeds past a card); in 3D space
## (set `space` to WORLD_3D) a quad that faces the camera. Both reach the shader material as `material`, so a binding or
## track writes "material:shader_parameter/<uniform>" in either. `progress` (0..1 over the layer) and `time` (seconds)
## are fed to the shader when `drive_progress` is on; the shaders in presentation/demo/fx/shaders declare both.
class_name FxShaderQuadLayer
extends FxLayer

@export var shader: Shader
## Fixed uniforms {name: value}; bindings and tracks override them per play.
@export var shader_params: Dictionary = {}
@export var drive_progress: bool = true
## UI: pixels; 3D: world units. Zero: fill the effect's rectangle (UI) or 1 x 1 (3D).
@export var size: Vector2 = Vector2.ZERO
## UI only: extra pixels on every side of the rectangle.
@export var grow: float = 0.0
## 3D only: turn to face the camera every frame.
@export var face_camera: bool = true
@export var default_size_when_empty: Vector2 = Vector2(160, 160)

## Spec vfx-stencil 3.3: does this 3D quad draw over the unit it sits on? AUTO: a camera-facing quad does (a hit glow), a flat one
## does not (a floor ring keeps the plain depth test, so its back half stays behind the unit's legs).
@export var over_own_unit: FxLayer.OverOwnUnit = FxLayer.OverOwnUnit.AUTO

const META_FADE: StringName = &"fx_quad_fade"
const META_TIME: StringName = &"fx_quad_time"


func kind() -> StringName:
	return &"shader_quad"


func native_space() -> int:
	return Space.WORLD_3D if space == Space.WORLD_3D else Space.UI


func build() -> Node:
	# Spec vfx-stencil 3.4: a shader material with a stencil setting; at stencil_unit 0 it is a plain ShaderMaterial of `shader`.
	var material := FxStencilMaterial.new()
	material.base_shader = shader
	for key in shader_params:
		material.set_shader_parameter(key, shader_params[key])
	if space == Space.WORLD_3D:
		var quad := FxQuad3D.new()
		var mesh := QuadMesh.new()
		mesh.size = size if size != Vector2.ZERO else Vector2.ONE
		quad.mesh = mesh
		quad.material = material
		quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		return quad
	var rect := ColorRect.new()
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.color = Color.WHITE
	rect.material = material
	return rect


func apply(node: Node, params: Dictionary, anchor: FxAnchor, quality: int, definition: FxDefinition) -> void:
	super(node, params, anchor, quality, definition)
	if node is FxQuad3D:
		var material := (node as FxQuad3D).material as FxStencilMaterial
		if material != null:
			material.stencil_unit = stencil_for(anchor)  # also re-checks a hot-reloaded shader and syncs the OWN pass


## The stencil value this layer draws with for `anchor` (3D quads only; see FxLayer.stencil_value).
func stencil_for(anchor: FxAnchor) -> int:
	return stencil_value(anchor, shader, over_own_unit) if space == Space.WORLD_3D else StencilIds.NONE


func over_own_default() -> bool:
	return face_camera


func stencil_shader() -> Shader:
	return shader if space == Space.WORLD_3D and draws_over_own_unit(over_own_unit) and FxStencilShaders.supports(shader) else null


func update(node: Node, local_time: float, length_seconds: float, params: Dictionary) -> void:
	if node is Control:
		_layout(node as Control)
	elif node is Node3D and face_camera and node.is_inside_tree():
		var camera := node.get_viewport().get_camera_3d()
		if camera != null:
			(node as Node3D).global_basis = camera.global_basis
	node.set_meta(META_TIME, local_time)
	var fading: Variant = FxLayer.meta_of(node, META_FADE)
	if fading != null and node.material != null:
		var left: float = 1.0 - (local_time - float(fading["from"])) / maxf(float(fading["seconds"]), 0.0001)
		node.material.set_shader_parameter(&"fade", clampf(left, 0.0, 1.0))
	if drive_progress and node.material != null:
		node.material.set_shader_parameter(&"progress", progress(local_time, length_seconds))
		node.material.set_shader_parameter(&"time", local_time)
		if node is Control:
			# Pixel-based shaders (glow, foil, outline) size their shapes from these.
			node.material.set_shader_parameter(&"rect_size", (node as Control).size)
			node.material.set_shader_parameter(&"margin", grow)
	super(node, local_time, length_seconds, params)
	if node is FxQuad3D and space == Space.WORLD_3D:
		follow_stencil(node, (node as FxQuad3D).material as FxStencilMaterial, shader, over_own_unit)


## Stopped: the shader's `fade` uniform runs from 1 to 0 over `fade_seconds` (see update).
func stop(node: Node, fade_seconds: float) -> void:
	var now: Variant = FxLayer.meta_of(node, META_TIME)
	node.set_meta(META_FADE, {"seconds": fade_seconds, "from": float(now) if now != null else 0.0})


func reset(node: Node) -> void:
	node.set_meta(META_FADE, null)
	if node.material != null:
		node.material.set_shader_parameter(&"fade", 1.0)
		if node.material is FxStencilMaterial:
			(node.material as FxStencilMaterial).sync_own_pass()  # the OWN pass too, so a recycled quad starts clean
	super(node)


func natural_length(_node: Node, _params: Dictionary) -> float:
	return 0.5


func extra_problems(_definition: FxDefinition, _probe: Node) -> PackedStringArray:
	var out := PackedStringArray()
	if shader == null:
		out.append("fx_shader_missing: layer '%s' has no shader" % id)
	elif drive_progress and not shader.code.contains("uniform float progress"):
		out.append("fx_shader_progress: layer '%s': %s declares no 'progress' uniform (drive_progress is on)" % [id, shader.resource_path.get_file()])
	if space == Space.WORLD_3D:
		var stencil := stencil_include_problem(shader, over_own_unit)
		if stencil != "":
			out.append(stencil)
	return out


## The ColorRect fills the holder (plus `grow`), centred on it; a projected holder has no size, so `size` is used.
func _layout(rect: Control) -> void:
	var holder := rect.get_parent() as Control
	var area := holder.size if holder != null else Vector2.ZERO
	var wanted := size if size != Vector2.ZERO else (area + Vector2(grow, grow) * 2.0 if area != Vector2.ZERO else default_size_when_empty)
	rect.size = wanted
	rect.pivot_offset = wanted * 0.5
	rect.position = area * 0.5 - wanted * 0.5


## The layer's time is up: the quad goes away now, whether or not its shader fades itself out (a quad that holds full strength, like a
## falling streak with no fade, must not linger until the rest of the effect ends).
func ended(node: Node) -> void:
	super(node)
	FxLayer.set_node_visible(node, false)
