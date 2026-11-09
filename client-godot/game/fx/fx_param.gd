## One exposed, tunable parameter of an FxDefinition (spec vfx-framework 3.1): the Niagara "user parameter".
## Layers bind their own properties to parameters (FxBinding), so one effect serves many uses with different values.
## Presentation only.
class_name FxParam
extends Resource

enum Kind { FLOAT, INT, BOOL, COLOR, VECTOR2, VECTOR3, TEXTURE, CURVE, GRADIENT }

@export var name: StringName
@export var kind: Kind = Kind.FLOAT
@export var default_value: Variant = 0.0
## FLOAT / INT / VECTOR clamp. Ignored while max_value <= min_value.
@export var min_value: float = 0.0
@export var max_value: float = 0.0
@export_multiline var description: String = ""


## The default, converted to the parameter's type.
func default() -> Variant:
	return clamp_value(default_value) if accepts(default_value) else _zero()


## True when `value` can be turned into this parameter's type (a Color may come as "#ff9a00" text).
func accepts(value: Variant) -> bool:
	match kind:
		Kind.FLOAT, Kind.INT:
			return typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT
		Kind.BOOL:
			return typeof(value) == TYPE_BOOL
		Kind.COLOR:
			return value is Color or ((value is String or value is StringName) and _color_of(String(value)).a >= 0.0)
		Kind.VECTOR2:
			return value is Vector2
		Kind.VECTOR3:
			return value is Vector3
		Kind.TEXTURE:
			return value == null or value is Texture2D
		Kind.CURVE:
			return value == null or value is Curve
		Kind.GRADIENT:
			return value == null or value is Gradient
	return false


## `value` (already accepted) converted to the type and clamped to the range.
func clamp_value(value: Variant) -> Variant:
	var ranged := max_value > min_value
	match kind:
		Kind.FLOAT:
			return clampf(float(value), min_value, max_value) if ranged else float(value)
		Kind.INT:
			return clampi(int(roundf(float(value))), int(min_value), int(max_value)) if ranged else int(roundf(float(value)))
		Kind.COLOR:
			return value if value is Color else _color_of(String(value))
		Kind.VECTOR2:
			if ranged:
				return Vector2(clampf(value.x, min_value, max_value), clampf(value.y, min_value, max_value))
		Kind.VECTOR3:
			if ranged:
				return Vector3(clampf(value.x, min_value, max_value), clampf(value.y, min_value, max_value),
					clampf(value.z, min_value, max_value))
	return value


## Console text ("1.5", "#ff9a00", "1,2", "true", a res:// path) -> {ok, value}.
func parse_text(text: String) -> Dictionary:
	var value: Variant = null
	match kind:
		Kind.FLOAT:
			if not text.is_valid_float():
				return {"ok": false}
			value = text.to_float()
		Kind.INT:
			if not text.is_valid_int():
				return {"ok": false}
			value = text.to_int()
		Kind.BOOL:
			var lower := text.to_lower()
			if not lower in ["true", "false", "on", "off", "1", "0", "yes", "no"]:
				return {"ok": false}
			value = lower in ["true", "on", "1", "yes"]
		Kind.COLOR:
			var color := _color_of(text)
			if color.a < 0.0:
				return {"ok": false}
			value = color
		Kind.VECTOR2, Kind.VECTOR3:
			var parts := text.split(",")
			var size := 2 if kind == Kind.VECTOR2 else 3
			if parts.size() != size:
				return {"ok": false}
			for part in parts:
				if not part.strip_edges().is_valid_float():
					return {"ok": false}
			value = Vector2(parts[0].to_float(), parts[1].to_float()) if size == 2 \
				else Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
		_:
			if text == "" or text == "none":
				value = null
			elif ResourceLoader.exists(text):
				value = load(text)
			else:
				return {"ok": false}
	if not accepts(value):
		return {"ok": false}
	return {"ok": true, "value": clamp_value(value)}


func describe() -> String:
	var range_text := " [%s..%s]" % [min_value, max_value] if max_value > min_value else ""
	return "%s: %s = %s%s%s" % [name, Kind.keys()[kind].to_lower(), default(), range_text,
		"  " + description if description != "" else ""]


func _zero() -> Variant:
	match kind:
		Kind.FLOAT:
			return 0.0
		Kind.INT:
			return 0
		Kind.BOOL:
			return false
		Kind.COLOR:
			return Color.WHITE
		Kind.VECTOR2:
			return Vector2.ZERO
		Kind.VECTOR3:
			return Vector3.ZERO
	return null


## A Color from text, or alpha -1 when the text is no color.
static func _color_of(text: String) -> Color:
	return Color.from_string(text, Color(0, 0, 0, -1))
