## The card rules of a content set (spec card-collection 3.6): which room pools the core set must fill, and how far.
## One resource per content root, found by ContentIndex (`card_rules`). A content root without one has no card checks at all,
## so content written before the card system is untouched. Numbers are typed as plain whole numbers (counts, not x100).
@tool
class_name CardRules
extends Resource

@export var id: StringName = &""
## Room pool tag → how many core cards it must hold (a warning below it: `core_pool_short`). Spec: Treasure 30, Shop 30,
## Vault 15, Void 15. A pool in neither list (Food, Chest) has no minimum, but its cards are core so it is never empty.
@export var pool_targets: Dictionary = {}
## Pools whose every card is core (spec: Boss and Void), whatever their rarity.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var all_core_pools: Array[StringName] = []
## The starter characters every account owns: exactly these characters must carry the core set tag.
@export var starter_characters: Array[StringName] = []
