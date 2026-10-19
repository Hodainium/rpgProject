## One enemy slot of an encounter (spec game-skeleton, section 3.1). Slot n becomes unit id "E<n>".
@tool
class_name EncounterSlot
extends Resource

@export var enemy: UnitDefinition
## Optional override of the enemy's default loadout: a loadout file, or one created inline here
## (referenced as "<encounterId>#<n>").
@export var loadout: Loadout
## Optional: always use this elite variant (skips the elite roll).
@export var variant: EnemyVariant
