## Spec card-ui 3.2: "a card whose tags (or its abilities' tags) match → this element". CardStyle.element_rules are tried in
## order, after the per-card override; the first match wins. Presentation only.
class_name CardElementRule
extends Resource

## Matched with TagMatch against the card's own tags (and, with look_in_abilities, the tags found in what it grants).
@export var query: GameplayTagQuery
## Also match the tags inside the abilities and effects the card grants or uses (Damage.Type.*).
@export var look_in_abilities: bool = false
## The element's key in CardStyle.elements.
@export var element: StringName = &""
