## Spec card-ui 3.2: how every card and pack looks, one per content set (the demo's is DEFAULT_PATH, outside the ruleset
## roots). Loaded by the card screens only: never by `combat/`, the run or the verifier. The face fields (face scenes, elements,
## icons, portraits) arrive with the card faces; the Shop needs the rarities, the pack looks and the name font.
class_name CardStyle
extends Resource

const DEFAULT_PATH: String = "res://presentation/demo/cards/card_style.tres"
## The catalog's rarity names, lowest first (Rpg.Contracts CardRarities.Order).
const RARITY_ORDER: Array[String] = ["common", "rare", "epic", "legendary", "mythic"]

## common, rare, epic, legendary, mythic (the catalog's names).
@export var rarities: Dictionary[StringName, CardRarityLook] = {}
## Pack id (the server's) → its look.
@export var pack_looks: Dictionary[StringName, CardPackLook] = {}
## The look of a pack id with no entry in `pack_looks`.
@export var default_pack: CardPackLook
## Card and pack names (Cinzel); the chrome stays on the theme's font.
@export var name_font: Font

static var _loaded: CardStyle


## The demo's style, loaded once; a new empty style (with a warning) when the file is missing.
static func current() -> CardStyle:
	if _loaded == null:
		if ResourceLoader.exists(DEFAULT_PATH):
			_loaded = load(DEFAULT_PATH)
		if _loaded == null:
			push_warning("CardStyle: %s is missing; cards use plain looks" % DEFAULT_PATH)
			_loaded = CardStyle.new()
	return _loaded


## Use `style` instead of the file (tests, a dev preview); null goes back to the file.
static func use(style: CardStyle) -> void:
	_loaded = style


func rarity(name: String) -> CardRarityLook:
	var look: CardRarityLook = rarities.get(StringName(name))
	return look if look != null else CardRarityLook.new()


func pack(pack_id: String) -> CardPackLook:
	var look: CardPackLook = pack_looks.get(StringName(pack_id))
	if look == null:
		look = default_pack
	return look if look != null else CardPackLook.new()
