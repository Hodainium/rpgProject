## Spec second-pack B6 / B7: content-wide battle settings the kernel applies, so the kernel itself holds no effect and no number.
## One per content root (the first by id is used; none = the hooks that need it do nothing). Content decides what a Bleed stack
## is and how a lifesteal heal heals; the kernel only decides when they happen.
@tool
class_name BattleRules
extends Resource

@export var id: StringName = &""
## B6: the effect one Bleed stack applies (a stacking DoT). A unit whose `bleed_chance` is above 0 rolls once per damaging hit
## and on success applies this to the target, as the hit's source. Null: no Bleed on hit.
@export var bleed_effect: GameplayEffect
## B7: the instant heal a unit with `lifesteal` above 0 applies to itself after each damaging hit. The kernel sets
## `Data.Event.Amount` (SetByCaller) to the share of the damage, so the effect heals that amount (e.g. ExecCalcEventAmount on hp
## with target_bonus "heal_taken"). Null: no lifesteal.
@export var lifesteal_effect: GameplayEffect
## B5: the low-HP line (% of max HP, typed like every number; a unit's `health_low_at` attribute overrides it) and the critical
## line. With no battle rules, no unit carries the states.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var health_low: float:
	get:
		return Fixed.to_display(health_low_x100)
	set(typed):
		health_low_x100 = Fixed.from_typed(typed)
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var health_critical: float:
	get:
		return Fixed.to_display(health_critical_x100)
	set(typed):
		health_critical_x100 = Fixed.from_typed(typed)
@export_storage var health_low_x100: int = 0
@export_storage var health_critical_x100: int = 0
## Bleed's stack limit on one target, over every effect that grants Status.Debuff.Bleed; a source's `bleed_stacks` attribute
## adds to it (whole stacks, ×100). 0: no limit beyond each effect's own max_stacks. Give Bleed effects a max_stacks at least
## this high plus what items add, so GodotGAS never stops them first.
@export var bleed_stacks: int = 0
## Lifesteal past full HP becomes `shield` for a unit whose `overheal_shield` is above 0, through this instant effect (the kernel
## sets Data.Event.Amount to the shield to add, e.g. ExecCalcEventAmount on shield). Null: no overheal shield.
@export var overheal_effect: GameplayEffect
