## Spec card-ui 3.3: the root of a card face scene (Look A "Tavern", Look B "Grimoire"). A face is drawn at SIZE in design pixels
## and scaled by whoever shows it; show_face() fills it from a CardFace and the style. Its looping layers (the Legendary and
## Mythic foil, the Epic glow, the Mythic prism) follow `animate`. Presentation only: never read by combat/, the run or the
## verifier.
class_name CardFaceView
extends Control

## A card face's design size (5:7).
const SIZE := Vector2(300, 420)

## The looping layers move (false for a still, e.g. a cached texture).
@export var animate: bool = true
## Each face starts its loops this many seconds apart at most, so cards side by side (a pack's five) never sweep in step (user,
## 2026-11-18). Taken from a hash of the card and this view, not from an RNG: presentation only, nothing random is drawn.
@export var phase_spread: float = 6.0

var face: CardFace
var style: CardStyle
var _time: float = 0.0


## Fills the face. Subclasses draw it; this keeps what they need.
func show_face(card: CardFace, card_style: CardStyle) -> void:
	face = card
	style = card_style
	_time = float(absi(hash(card.id + ":" + str(get_instance_id()))) % 10007) / 10007.0 * phase_spread
	_fill()
	set_process(animate and has_loops())  # a plain card (Common, Rare, Epic) does no work per frame


## Whether this face has a looping layer showing (subclasses).
func has_loops() -> bool:
	return false


## Draws `face` with `style` (subclasses).
func _fill() -> void:
	pass


func _process(delta: float) -> void:
	if not animate or not is_visible_in_tree():
		return
	_time += delta
	_tick(_time)


## Moves the looping layers to `time` seconds (subclasses).
func _tick(_seconds: float) -> void:
	pass


## The rarity's look, or the corrupted look for a corrupted card when the style has one.
func frame_look() -> CardRarityLook:
	if face.corrupted and style.corrupted != null:
		return style.corrupted
	return style.rarity(face.rarity)


## The card's art: a portrait, its icon, or the style's default glyph.
func art() -> Texture2D:
	if face.kind == CardFace.KIND_CHARACTER and face.portrait != null:
		return face.portrait
	if face.icon != null:
		return face.icon
	return style.default_icon


## A label's text set and its font, size and colour applied (the faces carry their own type, outside the UI theme).
static func dress(label: Label, text: String, font: Font, size: int, colour: Color) -> void:
	label.text = text
	if font != null:
		label.add_theme_font_override(&"font", font)
	label.add_theme_font_size_override(&"font_size", size)
	label.add_theme_color_override(&"font_color", colour)
