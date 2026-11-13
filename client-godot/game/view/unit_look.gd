## Spec cube-style 3.2: how one unit's cube looks. A field left unset (a negative number, a colour with alpha 0) is filled from the
## first matching tag rule, then the registry's default look (StyleRegistry.look_for). Presentation only: a unit's view reads it,
## combat never does (UnitDefinition lives in combat/ and the verifier loads it, so the look is keyed by id instead).
## Size and animation set come with a later round (spec cube-style 2).
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
## Spec cube-style 3.3: what the cube wears. Empty = unset; a list is not merged: the nearest non-empty one wins whole.
@export var attachments: Array[UnitAttachment] = []
## Spec cube-style 3.4: the cube's own surface (a stone, a bark…) as a material template; null = unset (a plain colour). A
## StandardMaterial3D, so the unit still takes its stencil stamp; its textures and bumps are tinted by the unit's colour.
@export var surface: StandardMaterial3D
## Spec cube-style 3.2: a looping effect the cube carries (the Ember Knight's fire ring); null = unset. The view plays it on itself
## while the unit lives. Presentation only.
@export var effect: FxDefinition
## Parameters for `effect` (name -> value), e.g. {"color": Color.RED}; used with the effect they come with.
@export var effect_params: Dictionary = {}


## A new look: this one's set fields, the rest from `fallback` (either may be null).
func merged_over(fallback: UnitLook) -> UnitLook:
	var merged := UnitLook.new()
	var own_colour := use_color_override or fallback == null
	merged.use_color_override = use_color_override or (fallback != null and fallback.use_color_override)
	merged.color_override = color_override if own_colour else fallback.color_override
	merged.rim = rim if rim >= 0.0 else (fallback.rim if fallback != null else UNSET)
	merged.rim_tint = rim_tint if rim_tint >= 0.0 else (fallback.rim_tint if fallback != null else UNSET)
	merged.roughness = roughness if roughness >= 0.0 else (fallback.roughness if fallback != null else UNSET)
	merged.attachments = attachments if not attachments.is_empty() else (fallback.attachments if fallback != null else attachments)
	merged.surface = surface if surface != null else (fallback.surface if fallback != null else null)
	var own_effect := effect != null or fallback == null
	merged.effect = effect if own_effect else fallback.effect
	merged.effect_params = effect_params if own_effect else fallback.effect_params
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
	if roughness >= 0.0 and surface == null:  # a surface keeps its own roughness
		material.roughness = roughness


## One line for the console (`style show`).
func describe() -> String:
	var worn := PackedStringArray()
	for attachment in attachments:
		if attachment != null and attachment.shape != null:
			worn.append("%s@%s%s" % [attachment.shape.display_name if attachment.shape.display_name != "" else "?", attachment.socket,
				" x2" if attachment.mirror else ""])
	return "colour %s, rim %s, rim tint %s, roughness %s, wears %s, effect %s" % [
		"#" + color_override.to_html(false) if use_color_override else "-",
		"%.2f" % rim if rim >= 0.0 else "-", "%.2f" % rim_tint if rim_tint >= 0.0 else "-",
		"%.2f" % roughness if roughness >= 0.0 else "-", ", ".join(worn) if not worn.is_empty() else "nothing",
		effect.id if effect != null else "-"]
