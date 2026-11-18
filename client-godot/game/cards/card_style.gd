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

@export_group("Card faces")
## Spec card-ui 7 q1: the face scenes by look name; each root extends CardFaceView. The user picked Look B "Grimoire"
## (2026-11-18) and Look A was removed, so the demo has one; a later look is another entry.
@export var face_scenes: Dictionary[StringName, PackedScene] = {}
## The look in use (console `cardui look [name]`).
@export var face: StringName = &"grimoire"
## Overrides frame and outline for Item.Corrupted cards (the rarity gem stays).
@export var corrupted: CardRarityLook
## physical, fire, ice, void, food, neutral.
@export var elements: Dictionary[StringName, CardElement] = {}
## First match wins, after `element_overrides`.
@export var element_rules: Array[CardElementRule] = []
@export var default_element: StringName = &"neutral"
## Card id → element, before the rules.
@export var element_overrides: Dictionary[StringName, StringName] = {}
## The glyph of a card with no icon (with the validator warning card_icon_missing).
@export var default_icon: Texture2D
## The icons and portraits: files the art builders create (CardArtSet.ICONS_PATH, PORTRAITS_PATH), by path, loaded the first time a
## face asks for art (the Shop, which needs only the rarity and pack looks, loads none of the ~100 textures); the first set that
## has a card wins.
@export_file("*.tres") var art_set_paths: Array[String] = []
## The loaded sets (from art_set_paths on first use; tests set them directly).
var art_sets: Array[CardArtSet] = []
## The set marks on a card: set id (core, descent) → glyph.
@export var set_marks: Dictionary[StringName, Texture2D] = {}

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


func element(name: StringName) -> CardElement:
	var look: CardElement = elements.get(name)
	if look == null:
		look = elements.get(default_element)
	return look if look != null else CardElement.new()


## A card's art (glyph or portrait) from the art sets, or null.
func art_for(id: StringName) -> Texture2D:
	if art_sets.is_empty() and not art_set_paths.is_empty():
		for path in art_set_paths:
			var loaded := load(path) as CardArtSet if ResourceLoader.exists(path) else null
			if loaded != null:
				art_sets.append(loaded)
	for art_set in art_sets:
		if art_set != null and art_set.textures.has(id):
			return art_set.textures[id]
	return null


## The face scene of `look` (the active one when empty), or null.
func face_scene(look: StringName = &"") -> PackedScene:
	return face_scenes.get(look if look != &"" else face)


func pack(pack_id: String) -> CardPackLook:
	var look: CardPackLook = pack_looks.get(StringName(pack_id))
	if look == null:
		look = default_pack
	return look if look != null else CardPackLook.new()
