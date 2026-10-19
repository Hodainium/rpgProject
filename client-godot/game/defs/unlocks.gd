## Unlock check for pools (spec game-skeleton, decision 7). A stub that always says yes until gacha exists.
class_name Unlocks
extends RefCounted


static func is_unlocked(_item: ItemDefinition) -> bool:
	return true
