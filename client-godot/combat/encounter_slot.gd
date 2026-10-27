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
## Spec playable-demo 3.7: granted to this enemy only, after the encounter's grants. Run battles (v2 snapshots) only.
@export var grants: AbilitySet
## Spec playable-demo 3.7: replaces the enemy definition's brain for this slot (e.g. a PatternBrain that uses a granted
## skill). Run battles (v2 snapshots) only.
@export var brain: EnemyBrain
## Spec skill-points D19: added to this enemy's level. Run battles (v2 snapshots) only.
@export var level_bonus: int = 0
