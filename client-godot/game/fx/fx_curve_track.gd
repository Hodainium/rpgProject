## A property animated by a curve over a layer's time (spec vfx-framework 3.1): the Niagara "over life" module in one
## resource. x of the curve is the layer's normalised time (0..1; a looping layer repeats it every `loop_period`),
## y is the value. Mode SET writes it, ADD adds it to the value the property had at start, MULTIPLY multiplies. A
## Color property takes the value on `color_channel`; a vector property applies it per axis (`axes`).
## Presentation only: it touches the layer's own node (or, for FxTweenLayer, the anchor's visuals) and is restored.
class_name FxCurveTrack
extends Resource

enum Mode { SET, ADD, MULTIPLY }
enum ColorChannel { ALPHA, RGB, ALL }

## NodePath-style path on the target (e.g. "scale", "modulate", "light_energy", "material:shader_parameter/strength").
@export var property: String
@export var curve: Curve
@export var mode: Mode = Mode.SET
@export var scale: float = 1.0
## A float parameter that also multiplies the value (an "intensity" knob).
@export var scale_param: StringName
@export var offset: float = 0.0
@export var color_channel: ColorChannel = ColorChannel.ALPHA
## Per-axis weight for Vector2 / Vector3 properties; a zero axis is left alone.
@export var axes: Vector3 = Vector3.ONE


## The curve at normalised time `t` (1.0 without a curve).
func sample(t: float) -> float:
	return curve.sample_baked(clampf(t, 0.0, 1.0)) if curve != null else 1.0


## The value to write at time `t`, given the value the property had at the start.
func evaluate(original: Variant, t: float, params: Dictionary) -> Variant:
	var amount := sample(t) * scale
	if scale_param != &"" and params.has(scale_param) and (params[scale_param] is float or params[scale_param] is int):
		amount *= float(params[scale_param])
	amount += offset
	if original is float or original is int:
		return _combine(float(original), amount)
	if original is Color:
		var color: Color = original
		var out := color
		if color_channel != ColorChannel.ALPHA:
			out.r = _combine(color.r, amount)
			out.g = _combine(color.g, amount)
			out.b = _combine(color.b, amount)
		if color_channel != ColorChannel.RGB:
			out.a = _combine(color.a, amount)
		return out
	if original is Vector2:
		var v2: Vector2 = original
		return Vector2(_axis(v2.x, amount, axes.x), _axis(v2.y, amount, axes.y))
	if original is Vector3:
		var v3: Vector3 = original
		return Vector3(_axis(v3.x, amount, axes.x), _axis(v3.y, amount, axes.y), _axis(v3.z, amount, axes.z))
	return original


func _combine(original: float, amount: float) -> float:
	match mode:
		Mode.ADD:
			return original + amount
		Mode.MULTIPLY:
			return original * amount
	return amount


func _axis(original: float, amount: float, weight: float) -> float:
	if weight == 0.0:
		return original
	return _combine(original, amount * weight) if mode != Mode.MULTIPLY else original * lerpf(1.0, amount, weight)
