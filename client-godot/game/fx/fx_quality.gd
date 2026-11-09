## Quality tiers and shared helpers for the effects system (spec vfx-framework F4): off / low / medium / high, like
## Niagara's scalability levels. A layer declares the lowest tier it plays at (FxLayer.min_quality); particle layers
## also scale their amount by the tier.
class_name FxQuality
extends RefCounted

const OFF: int = 0
const LOW: int = 1
const MEDIUM: int = 2
const HIGH: int = 3
const NAMES: Array[String] = ["off", "low", "medium", "high"]

static var _soft_dot: Texture2D


## A tier from text ("low"), high when the text is no tier.
static func from_text(text: String) -> int:
	var index := NAMES.find(text.to_lower())
	return index if index >= 0 else HIGH


## How many of a particle layer's particles a tier keeps.
static func amount_factor(quality: int) -> float:
	match quality:
		LOW:
			return 0.4
		MEDIUM:
			return 0.7
	return 1.0


## A white dot that fades to nothing at its edge (the default particle sprite), made once.
static func soft_dot() -> Texture2D:
	if _soft_dot == null:
		var gradient := Gradient.new()
		gradient.set_color(0, Color(1, 1, 1, 1))
		gradient.set_color(1, Color(1, 1, 1, 0))
		var texture := GradientTexture2D.new()
		texture.gradient = gradient
		texture.fill = GradientTexture2D.FILL_RADIAL
		texture.fill_from = Vector2(0.5, 0.5)
		texture.fill_to = Vector2(1.0, 0.5)
		texture.width = 64
		texture.height = 64
		_soft_dot = texture
	return _soft_dot
