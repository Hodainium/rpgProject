## One line of an ability's execution table (Dark Souls-style; spec "Execution table and animation events").
##
## The ability's animation fires rows by id with `execute(&"<id>")` method-track keys. A row says what one hit does:
## which effect it applies, an optional flat or scaled damage override, and which of the ability's targets it hits.
@tool
class_name ExecutionRow
extends Resource

enum DamageMode {
	USE_EFFECT,  ## No override: the effect's own math decides.
	FLAT,        ## Fixed damage: flat_damage.
	SCALED,      ## Percentage of the attacker's ATK: multiplier.
}

enum Targets {
	ALL,       ## The ability's full target list.
	PRIMARY,   ## Only the primary target (or the first target when the ability has none).
	ADJACENT,  ## Everyone in the target list except the primary (blast neighbours).
}

## SetByCaller tags the damage ExecCalc reads (values stored ×100).
const DAMAGE_FLAT_TAG: StringName = &"Data.Damage.Flat"
const DAMAGE_MULTIPLIER_TAG: StringName = &"Data.Damage.Multiplier"
## Spec item-pass 3.1: the toughness a weakness hit removes, read by the damage ExecCalc.
const TOUGHNESS_TAG: StringName = &"Data.Toughness"

## Name the animation's execute keys refer to. Unique within the ability.
@export var id: StringName = &""
## The effect this row applies (a damage effect, a buff, a DoT...).
@export var effect: GameplayEffect
@export var damage_mode: DamageMode = DamageMode.USE_EFFECT
@export var targets: Targets = Targets.ALL
## Spec game-skeleton 3.4: e.g. Damage.Type.Ice. A damaging hit also sends Event.Damage.Dealt.Ice /
## Event.Damage.Taken.Ice, so triggered passives can react to a damage type with no code.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var tags: Array[StringName] = []

## Flat damage as typed (e.g. 80.5), used when damage_mode is FLAT. Editor-only view of flat_damage_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var flat_damage: float:
	get:
		return Fixed.to_display(flat_damage_x100)
	set(typed):
		_warn_decimals("flat_damage", typed)
		flat_damage_x100 = Fixed.from_typed(typed)

## Percentage of the attacker's ATK as typed (150 = 150%), used when damage_mode is SCALED.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var multiplier: float:
	get:
		return Fixed.to_display(multiplier_x100)
	set(typed):
		_warn_decimals("multiplier", typed)
		multiplier_x100 = Fixed.from_typed(typed)

## Toughness damage as typed (e.g. 30), dealt only by a hit on the target's weakness (spec item-pass 3.3).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var toughness: float:
	get:
		return Fixed.to_display(toughness_x100)
	set(typed):
		_warn_decimals("toughness", typed)
		toughness_x100 = Fixed.from_typed(typed)

## Saved forms (×100 whole numbers).
@export_storage var flat_damage_x100: int = 0
@export_storage var multiplier_x100: int = 10000
@export_storage var toughness_x100: int = 0


## Puts this row's damage override and toughness damage on a spec through GodotGAS's SetByCaller mechanism, and its
## tags (damage types) on the spec as dynamic tags, so an ExecCalc can read them with spec.has_tag().
func apply_override(spec: GameplayEffectSpec) -> void:
	match damage_mode:
		DamageMode.FLAT:
			spec.set_set_by_caller_magnitude(DAMAGE_FLAT_TAG, float(flat_damage_x100))
		DamageMode.SCALED:
			spec.set_set_by_caller_magnitude(DAMAGE_MULTIPLIER_TAG, float(multiplier_x100))
	if toughness_x100 > 0:
		spec.set_set_by_caller_magnitude(TOUGHNESS_TAG, float(toughness_x100))
	for tag in tags:
		spec.inject_tag(tag)


func _warn_decimals(field: String, typed: float) -> void:
	if Fixed.has_extra_decimals(typed):
		push_warning("ExecutionRow '%s': %s keeps only 2 decimals (%s)." % [id, field, typed])
