## Spec cube-style 3.2: how one unit's cube looks. A field left unset (a negative number, a colour with alpha 0) is filled from the
## first matching tag rule, then the registry's default look (StyleRegistry.look_for). Presentation only: a unit's view reads it,
## combat never does (UnitDefinition lives in combat/ and the verifier loads it, so the look is keyed by id instead).
## Attachments, size and animation set come with round 2 (spec cube-style 2).
class_name UnitLook
extends Resource

const UNSET: float = -1.0

## Whether color_override replaces the definition's display_color (off = unset: a rule's or the default look's applies).
## A switch rather than "alpha 0 = unset": the inspector's colour picker keeps alpha 0 when only the colour is changed.
@export var use_color_override: bool = false
@export var color_override: Color = Color.WHITE
## StandardMaterial3D.rim (0 = off); negative = unset.
@export_range(-1.0, 1.0) var rim: float = UNSET
## StandardMaterial3D.rim_tint (0 = white rim, 1 = the body's colour); negative = unset.
@export_range(-1.0, 1.0) var rim_tint: float = UNSET
## StandardMaterial3D.roughness; negative = unset (the material's default, 1).
@export_range(-1.0, 1.0) var roughness: float = UNSET


## A new look: this one's set fields, the rest from `fallback` (either may be null).
func merged_over(fallback: UnitLook) -> UnitLook:
	var merged := UnitLook.new()
	var own_colour := use_color_override or fallback == null
	merged.use_color_override = use_color_override or (fallback != null and fallback.use_color_override)
	merged.color_override = color_override if own_colour else fallback.color_override
	merged.rim = rim if rim >= 0.0 else (fallback.rim if fallback != null else UNSET)
	merged.rim_tint = rim_tint if rim_tint >= 0.0 else (fallback.rim_tint if fallback != null else UNSET)
	merged.roughness = roughness if roughness >= 0.0 else (fallback.roughness if fallback != null else UNSET)
	return merged


## The body colour: the override when set, else `display_color`.
func body_color(display_color: Color) -> Color:
	return color_override if use_color_override else display_color


## Sets the look's material fields on `material` (the colour stays the caller's: a dead unit is grey whatever its look).
func paint(material: StandardMaterial3D) -> void:
	if rim > 0.0:
		material.rim_enabled = true
		material.rim = rim
		if rim_tint >= 0.0:
			material.rim_tint = rim_tint
	if roughness >= 0.0:
		material.roughness = roughness


## One line for the console (`style show`).
func describe() -> String:
	return "colour %s, rim %s, rim tint %s, roughness %s" % [
		"#" + color_override.to_html(false) if use_color_override else "-",
		"%.2f" % rim if rim >= 0.0 else "-", "%.2f" % rim_tint if rim_tint >= 0.0 else "-",
		"%.2f" % roughness if roughness >= 0.0 else "-"]
