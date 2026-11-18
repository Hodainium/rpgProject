## Spec card-ui 3.5: card art kept in files of their own, so the art builders only ever create new files and never rewrite the
## user's style file: the icon pass writes card_icons.tres (item and armor card id → game-icons glyph), the portrait tool
## card_portraits.tres (character id → prerendered portrait). CardStyle.art_set_paths lists them. Presentation only.
class_name CardArtSet
extends Resource

const ICONS_PATH: String = "res://presentation/demo/cards/card_icons.tres"
const PORTRAITS_PATH: String = "res://presentation/demo/cards/card_portraits.tres"

## Card id → its art.
@export var textures: Dictionary[StringName, Texture2D] = {}
