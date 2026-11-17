## Spec card-ui 3.2: how one card rarity looks (the frame metal, the colour shared with the pack tells and 5b2's floor
## outlines, the `tier` parameter of every card effect). Presentation only.
class_name CardRarityLook
extends Resource

## The rarity colour: the gem, the rarity word, the pack tell.
@export var color: Color = Color(0.81, 0.83, 0.86)
@export var frame_light: Color = Color(0.9, 0.9, 0.9)
@export var frame_dark: Color = Color(0.35, 0.35, 0.38)
## 0 Common .. 4 Mythic: the `tier` parameter of every card effect.
@export var tier: int = 0
## The crown crest above the art (Legendary, Mythic).
@export var crest: bool = false
## A looping effect on the card in the collection (Epic glow, foil for tiers 3 and 4); none = a plain card.
@export var face_effect: FxDefinition
@export var face_effect_params: Dictionary = {}
