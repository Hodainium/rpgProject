## An enemy (spec game-skeleton, section 3.1). A UnitDefinition, so encounters and battles use it directly.
## A boss is an ordinary enemy tagged Enemy.Boss; boss rooms pick boss encounters by tag.
@tool
class_name EnemyDefinition
extends UnitDefinition

## Elite variants this enemy can roll (chance from the chapter's ScalingRules).
@export var variants: Array[EnemyVariant] = []
## Spec content-pass H5: boss phases, in order of strictly decreasing hp_below. Empty for ordinary enemies.
@export var phases: Array[BossPhase] = []
