## Spec card-ui 3.2: how one pack type looks in the Shop and on Open packs (the foil wrapper's colours, its glyph, the band's
## label). A pack id with no look uses `CardStyle.default_pack`. Presentation only.
class_name CardPackLook
extends Resource

## The wrapper's gradient, top to bottom.
@export var color_light: Color = Color(0.42, 0.18, 0.55)
@export var color_dark: Color = Color(0.13, 0.06, 0.23)
## The band across the lower third and the glyph's tint.
@export var accent: Color = Color(0.97, 0.82, 0.42)
## A game-icons glyph in the middle (white SVG, tinted by `accent`).
@export var glyph: Texture2D
## The band's text; empty = the pack's name from the server.
@export var label: String = ""
## The burst's colour when the pack opens (spec 2.4 beat 2: the pack's own colour, never a rarity tell).
@export var burst_color: Color = Color(0.97, 0.82, 0.42)
