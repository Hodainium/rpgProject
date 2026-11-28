## Screen / camera / control shake (spec vfx-framework 3.1). What shakes depends on the anchor: a control is nudged
## (`strength_px`), the whole window shifts for a screen anchor (canvas offset, and the 3D camera by `strength_world`),
## a 3D anchor shakes the camera that sees it, a stage anchor the stage's camera. Everything is restored at the end.
## Deterministic (sines, no random). Bind "strength_px", "strength_world", "frequency".
class_name FxShakeLayer
extends FxLayer

@export var strength_px: float = 10.0
@export var strength_world: float = 0.15
## Shakes per second.
@export var frequency: float = 22.0
## Strength over the layer's 0..1 time; none = linear decay.
@export var decay: Curve
@export var seconds: float = 0.4

const TARGETS: StringName = &"fx_shake_targets"


func kind() -> StringName:
	return &"shake"


func build() -> Node:
	return FxValueNode.new().declare({"strength_px": strength_px, "strength_world": strength_world, "frequency": frequency})


func start(node: Node) -> void:
	super(node)
	var anchor: FxAnchor = node.get_meta(META_ANCHOR)
	var targets := {}
	match anchor.kind:
		FxAnchor.Kind.CONTROL:
			targets["control"] = anchor.node
			targets["control_origin"] = FxLayer.acquire_original(anchor.node, "shake:position", (anchor.node as Control).position)
		FxAnchor.Kind.SCREEN:
			var viewport := node.get_viewport()
			targets["viewport"] = viewport
			targets["canvas_origin"] = FxLayer.acquire_original(viewport, "shake:canvas", viewport.canvas_transform)
			# A CanvasLayer ignores the viewport's canvas transform and the game's UI sits under one: shake each layer's
			# own offset too (the effects' overlay included).
			var layers: Array = []
			for layer in _canvas_layers(viewport):
				layers.append([layer, FxLayer.acquire_original(layer, "shake:layer", layer.offset)])
			targets["layers"] = layers
			targets["camera"] = viewport.get_camera_3d()
		FxAnchor.Kind.STAGE:
			targets["camera"] = anchor.stage.camera
		_:
			var holder: Node = anchor.node if anchor.node != null else node
			targets["camera"] = holder.get_viewport().get_camera_3d() if holder.is_inside_tree() else null
	var camera := _live(targets, "camera") as Camera3D
	if camera != null:
		targets["camera_origin"] = FxLayer.acquire_original(camera, "shake:camera", Vector2(camera.h_offset, camera.v_offset))
	node.set_meta(TARGETS, targets)


func update(node: Node, local_time: float, length_seconds: float, params: Dictionary) -> void:
	var targets: Dictionary = node.get_meta(TARGETS, {})
	var u := progress(local_time, length_seconds)
	var amount: float = decay.sample_baked(u) if decay != null else 1.0 - u
	var rate: float = float(node.get(&"frequency")) * TAU
	var wobble := Vector2(sin(local_time * rate + 1.3), cos(local_time * rate * 1.17)) * amount
	var px: float = float(node.get(&"strength_px"))
	var world: float = float(node.get(&"strength_world"))
	var control := _live(targets, "control") as Control
	if control != null:
		control.position = targets["control_origin"] + wobble * px
	var viewport := _live(targets, "viewport") as Viewport
	if viewport != null:
		viewport.canvas_transform = Transform2D(0.0, wobble * px) * (targets["canvas_origin"] as Transform2D)
	for entry in targets.get("layers", []):
		if is_instance_valid(entry[0]):
			entry[0].offset = entry[1] + wobble * px
	var camera := _live(targets, "camera") as Camera3D
	if camera != null:
		var origin: Vector2 = targets["camera_origin"]
		camera.h_offset = origin.x + wobble.x * world
		camera.v_offset = origin.y + wobble.y * world
	super(node, local_time, length_seconds, params)


func ended(node: Node) -> void:
	var targets: Dictionary = FxLayer.meta_of(node, TARGETS) if node.has_meta(TARGETS) else {}
	var control := _live(targets, "control") as Control
	if control != null and FxLayer.release_original(control, "shake:position")["last"]:
		control.position = targets["control_origin"]
	var viewport := _live(targets, "viewport") as Viewport
	if viewport != null and FxLayer.release_original(viewport, "shake:canvas")["last"]:
		viewport.canvas_transform = targets["canvas_origin"]
	for entry in targets.get("layers", []):
		if is_instance_valid(entry[0]) and FxLayer.release_original(entry[0], "shake:layer")["last"]:
			entry[0].offset = entry[1]
	var camera := _live(targets, "camera") as Camera3D
	if camera != null and FxLayer.release_original(camera, "shake:camera")["last"]:
		var origin: Vector2 = targets["camera_origin"]
		camera.h_offset = origin.x
		camera.v_offset = origin.y
	node.set_meta(TARGETS, null)
	super(node)


## A target that is still alive, else null. Read untyped first: a freed node (the window closed while the shake ran) cannot be
## assigned to a typed variable ("Trying to assign invalid previously freed instance").
static func _live(targets: Dictionary, key: String) -> Object:
	var value: Variant = targets.get(key)
	return value if value != null and is_instance_valid(value) else null


## Every CanvasLayer in the viewport's tree (not inside other viewports).
static func _canvas_layers(viewport: Viewport) -> Array:
	var found: Array = []
	var queue: Array[Node] = [viewport]
	while not queue.is_empty():
		var current: Node = queue.pop_front()
		for child in current.get_children():
			if child is SubViewport:
				continue
			if child is CanvasLayer:
				found.append(child)
			queue.append(child)
	return found


func natural_length(_node: Node, _params: Dictionary) -> float:
	return seconds
