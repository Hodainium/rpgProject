## Spec card-ui 3.2: a card element's colours (fire, ice, ...). The approved face (Look B, 2026-11-18) colours cards by rarity and
## does not draw the element; it stays in the face data (CardFace.element) for later screens and effects. Presentation only.
class_name CardElement
extends Resource

@export var color: Color = Color(0.9, 0.83, 0.65)
## A frame gradient for this element (top-left to bottom-right), for a face that colours by element.
@export var frame_light: Color = Color(0.85, 0.78, 0.61)
@export var frame_dark: Color = Color(0.54, 0.45, 0.28)
