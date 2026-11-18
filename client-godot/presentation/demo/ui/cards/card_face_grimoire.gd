## Spec card-ui 3.3, the card face: Look B "Grimoire" as the user approved it (2026-11-18). A black border; a frame and an art
## backdrop in the rarity's colours (Mythic: an opal frame); rectangular parchment name and type bars, the set symbol in the
## rarity's colour; full-width art (a portrait, or the item's glyph in ivory); the rules box. Effects: Legendary a gold sheen and
## Mythic twinkling glitter (both sweep from the top left, starting out of step per card), corrupted cards a magenta glow and
## outline; Common, Rare and Epic none.
extends CardFaceView

## An item's glyph: ivory, at this share of the art window's smaller side.
@export var glyph_color: Color = Color("f3ead4")
@export var glyph_size: float = 0.6
## Legendary's gold sheen: its colour, how fast it crosses (card lengths a second), the pause off the card between passes, and the
## direction it travels (radians in the card's UV, y down: PI / 4 = top left to bottom right).
@export var legendary_sheen: Color = Color(1.0, 0.82, 0.42)
@export var legendary_sheen_speed: float = 0.35
@export var sweep_rest: float = 1.5
@export var sweep_angle: float = PI / 4.0
## A corrupted card's glow and frame outline.
@export var corrupted_glow: Color = Color(0.878, 0.251, 0.984)

var _frame_base: UIWindowStyle
var _glow_base: Array = []   # the scene's own glyph halo (colour, radius), kept before a Void card changes it


func _fill() -> void:
	var look := frame_look()  # the rarity's (or the corrupted look's) two metals
	var light := look.frame_light
	var dark := look.frame_dark
	var shown := shown_rarity()   # a Void card wears CardStyle.corrupted_as (Legendary)
	var mythic := shown == "mythic" and not corrupted_glow_look()
	if _frame_base == null:
		_frame_base = %Frame.get_theme_stylebox(&"panel") as UIWindowStyle  # the scene's own frame, kept before any card changes it
	var frame := _frame_base.duplicate() as UIWindowStyle  # never the last card's (a reused view)
	if mythic:
		# The opal shader draws the frame: the panel goes clear (its border and ring too, which it fills under the gradient).
		for part in ["top", "middle", "bottom", "border_color", "ring_color"]:
			frame.set(part, Color(0, 0, 0, 0))
	else:
		frame.top = light
		frame.middle = light.lerp(dark, 0.5)
		frame.bottom = dark
	if corrupted_glow_look():
		frame.border_color = corrupted_glow
		frame.border_width = 2
	%Frame.add_theme_stylebox_override(&"panel", frame)
	%Prism.visible = mythic
	%Name.text = face.name
	if style.name_font != null:
		var bold := FontVariation.new()
		bold.base_font = style.name_font
		bold.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 700}
		%Name.add_theme_font_override(&"font", bold)
	%SetSymbol.texture = style.set_marks.get(StringName(face.set_id))
	%SetSymbol.modulate = style.set_symbol_color(face.rarity)
	%Art.texture = art()
	var material := (%Art.material as ShaderMaterial)
	var portrait := face.kind == CardFace.KIND_CHARACTER and face.portrait != null
	material.set_shader_parameter(&"glyph", 0.0 if portrait else 1.0)
	material.set_shader_parameter(&"bg_center", light.lerp(Color.WHITE, 0.3))
	material.set_shader_parameter(&"bg_mid", dark)
	material.set_shader_parameter(&"bg_edge", Color("0c0c12"))
	material.set_shader_parameter(&"glyph_tint", style.corrupted_glyph if face.corrupted else glyph_color)
	if _glow_base.is_empty():
		_glow_base = [material.get_shader_parameter(&"glow_color"), material.get_shader_parameter(&"glow_radius")]
	material.set_shader_parameter(&"glow_color", style.corrupted_glyph_halo if face.corrupted else _glow_base[0])
	material.set_shader_parameter(&"glow_radius", style.corrupted_glyph_halo_radius if face.corrupted else _glow_base[1])
	material.set_shader_parameter(&"glyph_scale", glyph_size)
	%Type.text = face.type_line
	%Text.text = face.text
	%Mythic.visible = shown == "mythic"
	%Foil.visible = shown == "legendary"
	var foil := (%Foil.material as ShaderMaterial)
	foil.set_shader_parameter(&"rainbow", 0.0)
	foil.set_shader_parameter(&"tint", legendary_sheen)
	foil.set_shader_parameter(&"strength", 0.5)
	_sweep(foil, 0.14, legendary_sheen_speed)
	%Glow.visible = corrupted_glow_look()
	(%Glow.material as ShaderMaterial).set_shader_parameter(&"color", corrupted_glow)
	if not %Art.resized.is_connected(_size_art):
		%Art.resized.connect(_size_art)
	_size_art()
	_tick(_time)


## A sweep that starts and ends fully off the card (the band's soft edge included), travels at `travel` card-lengths a second and
## then rests off the card for sweep_rest seconds before the next pass (user, 2026-11-18: no snap back).
func _sweep(foil: ShaderMaterial, band: float, travel: float) -> void:
	var reach := 0.5 * (absf(cos(sweep_angle)) + absf(sin(sweep_angle)))  # the card's extent along the sweep, from its centre
	var from := 0.5 - reach - band * 2.8
	var to := 0.5 + reach + band * 2.8
	var cycle := (to - from) / maxf(travel, 0.01) + sweep_rest
	foil.set_shader_parameter(&"angle", sweep_angle)
	foil.set_shader_parameter(&"band_width", band)
	foil.set_shader_parameter(&"sweep_from", from)
	foil.set_shader_parameter(&"sweep_to", to)
	foil.set_shader_parameter(&"speed", 1.0 / cycle)
	foil.set_shader_parameter(&"rest", sweep_rest / cycle)


func has_loops() -> bool:
	return %Foil.visible or %Mythic.visible or %Prism.visible or %Glow.visible


func _tick(seconds: float) -> void:
	for layer in [%Prism, %Foil, %Glow, %Mythic]:
		if layer.visible:
			(layer.material as ShaderMaterial).set_shader_parameter(&"time", seconds)


## The art window's size comes from the layout (it fills what the bars and the text box leave).
func _size_art() -> void:
	if is_instance_valid(self):
		(%Art.material as ShaderMaterial).set_shader_parameter(&"rect_size", %Art.size)
