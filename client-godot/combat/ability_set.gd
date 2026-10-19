## Lyra-style ability set (spec game-skeleton, section 3.1): abilities, effects and tags granted to a unit together.
##
## Loadouts, items, equipment and elite variants each carry one. Everything in it is granted at battle start (or when a
## field context is built) and is gone when the battle ends, so losing an item removes its set from the next battle.
@tool
class_name AbilitySet
extends Resource

## Each a scene whose root is a BattleAbility. An ability tag the unit already has is skipped with a content warning.
@export var abilities: Array[PackedScene] = []
## Infinite effects applied at battle start. Must be saved .tres files: the state hash identifies effects by path.
@export var effects: Array[GameplayEffect] = []
## Loose tags added to the unit's ASC.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var tags: Array[StringName] = []
