## What the 2D and 3D particle layers share (spec vfx-framework 3.1): the emission counts, the quality scaling of a bound
## `amount`, the lifecycle, and the colour ramp / size curve setup. GPUParticles2D and GPUParticles3D have the same
## properties for all of this, so one body serves both. The kinds (FxParticles3DLayer, FxParticles2DLayer) add their node,
## their sizes in world units or pixels, and their drawing.
class_name FxParticlesLayer
extends FxLayer

@export var amount: int = 24
@export var lifetime: float = 0.8
@export_range(0.0, 1.0) var explosiveness: float = 1.0
@export var color: Color = Color.WHITE
## Over the particle's life (fade out, colour shift).
@export var color_ramp: Gradient
## Size over life (x 0..1, y multiplier).
@export var size_curve: Curve
@export var texture: Texture2D
## Flipbook (spec vfx-content-pass 3.5): when the texture is a sprite sheet, its grid (columns x rows) and the number of
## times the whole sheet plays during a particle's life (0 = the sheet is not animated, the first frame shows). The grid
## belongs to the sheet: a different texture comes with its own columns and rows.
@export var h_frames: int = 1
@export var v_frames: int = 1
@export var anim_cycles: float = 1.0
## Each particle starts on a random frame (a sheet of different shards or bubbles rather than an animation).
@export var random_frame: bool = false
@export var additive: bool = true
@export var local_coords: bool = false
## Fewer particles on low quality (low 40 %, medium 70 %).
@export var scale_amount_with_quality: bool = true
## A random head start of 0..start_jitter seconds for each copy of the effect (the particles' preprocess), so copies started on
## the same frame (several statuses landing at once) do not emit in step. 0 = every copy starts from nothing, in step.
@export_range(0.0, 10.0) var start_jitter: float = 0.0

## Presentation-only randomness for start_jitter (never a battle or run stream; like the sound layer's pitch).
static var _jitter_rng: RandomNumberGenerator


func apply(node: Node, params: Dictionary, anchor: FxAnchor, quality: int, definition: FxDefinition) -> void:
	node.amount = amount
	super(node, params, anchor, quality, definition)  # binds (and scales a bound amount, see rebind)
	if scale_amount_with_quality and not _binds_amount():
		node.amount = maxi(1, roundi(node.amount * FxQuality.amount_factor(quality)))


## A live retune of a bound `amount` keeps the quality tier's scaling.
func rebind(node: Node, params: Dictionary, definition: FxDefinition) -> void:
	super(node, params, definition)
	if scale_amount_with_quality and node.has_meta(META_QUALITY) and _binds_amount():
		node.amount = maxi(1, roundi(node.amount * FxQuality.amount_factor(int(node.get_meta(META_QUALITY)))))


func start(node: Node) -> void:
	super(node)
	node.preprocess = _jitter() if start_jitter > 0.0 else 0.0
	node.restart()
	node.emitting = true


## A head start in [0, start_jitter] seconds.
func _jitter() -> float:
	if _jitter_rng == null:
		_jitter_rng = RandomNumberGenerator.new()
		_jitter_rng.randomize()
	return _jitter_rng.randf_range(0.0, start_jitter)


func stop(node: Node, _fade: float) -> void:
	node.emitting = false


func reset(node: Node) -> void:
	node.restart()
	node.emitting = false
	super(node)


func tail(node: Node) -> float:
	return node.lifetime


func natural_length(node: Node, _params: Dictionary) -> float:
	return node.lifetime * (1.0 + (1.0 - node.explosiveness))


func _binds_amount() -> bool:
	for binding in bindings:
		if binding.property == "amount":
			return true
	return false


## Sets the colour ramp and size curve on a generated process material.
func _style(material: ParticleProcessMaterial) -> void:
	material.color = color
	if h_frames * v_frames > 1:
		material.anim_speed_min = anim_cycles
		material.anim_speed_max = anim_cycles
		if random_frame:
			material.anim_offset_min = 0.0
			material.anim_offset_max = 1.0
	if color_ramp != null:
		var ramp := GradientTexture1D.new()
		ramp.gradient = color_ramp
		material.color_ramp = ramp
	if size_curve != null:
		var curve := CurveTexture.new()
		curve.curve = size_curve
		material.scale_curve = curve


## True when the texture is a sprite sheet.
func _is_flipbook() -> bool:
	return h_frames * v_frames > 1
