## Spec cube-style 3.1: a look for every unit whose definition tags match a GameplayTagQuery (GAS-first: archetypes come from the
## tags the content already has, e.g. Enemy.Boss). In a StyleRegistry the first matching rule fills what an exact look leaves unset.
class_name UnitLookRule
extends Resource

@export var query: GameplayTagQuery
@export var look: UnitLook


func matches(tags: Array) -> bool:
	return query != null and look != null and TagMatch.matches(query, tags)
