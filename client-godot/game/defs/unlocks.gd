## Unlock check for pools (spec game-skeleton, decision 7). A stub that always says yes until gacha exists.
class_name Unlocks
extends RefCounted


## An ItemDefinition or (spec item-pass 3.5) an EquipmentDefinition.
static func is_unlocked(_pickup: Resource) -> bool:
	return true
