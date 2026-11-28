## Project-specific GameplayAbility for battles (Lyra-style extension, client-godot/CLAUDE.md section 2).
##
## Adds targeting, the execution table and the animation that drives it. Activation runs the execution sequence
## read from the animation; before each execution it awaits the battle's presentation gate, which is the only thing
## a combat ability may await (spec "Zero-frame rule").
class_name BattleAbility
extends GameplayAbility

enum Targeting {
	SINGLE_ENEMY,  ## One opposing unit.
	ALL_ENEMIES,   ## Every living opposing unit.
	BLAST_ENEMY,   ## One opposing unit plus its living neighbours by slot.
	SINGLE_ALLY,   ## One unit on the actor's side (may be the actor).
	ALL_ALLIES,    ## Every living unit on the actor's side.
	SELF,          ## The actor.
	SINGLE_DEAD_ALLY,  ## One dead unit on the actor's side (revives). v2 battles and the field only.
	ALL_DEAD_ALLIES,   ## Every dead unit on the actor's side.
	RANDOM_ENEMY,        ## Spec item-power K4: one opposing unit that is up, drawn on the battle RNG at activation.
	RANDOM_OTHER_ENEMY,  ## The same draw among the opposing units other than the one the triggering event is about.
	OTHER_ENEMIES,       ## Every opposing unit other than the one the triggering event is about (no draw).
	LOWEST_ALLY,         ## Spec second-pack: the living ally (the actor included) with the lowest HP share; ties to the lowest slot.
}

## A triggered ability with this asset tag is a follow-up attack (spec item-pass 3.1): its hits carry Hit.FollowUp and
## the battle sends Event.Attack.FollowUp when it fires. It is still a passive: never an action, never logged.
const FOLLOW_UP_TAG: StringName = &"Ability.Type.FollowUp"
## Spec item-power K7: a triggered ability with this asset tag re-runs the triggering ability's rows at echo_scale.
const ECHO_TAG: StringName = &"Ability.Type.Echo"
## Spec item-power: a triggered attack that is not a follow-up (its hits feed follow-ups) but plays on screen like one.
## Presentation only: the kernel never reads it.
const STRIKE_TAG: StringName = &"Ability.Type.Strike"
## A basic attack (spec skill-points): never a skill (Event.Ability.Used.Skill).
const BASIC_TAG: StringName = &"Ability.Type.Basic"
## An ability with this asset tag is an ult (spec ult-interrupts): never a turn action, cast only as an interrupt at an
## ult window. Its cost effect (ult charge) decides when it can fire.
const ULTIMATE_TAG: StringName = &"Ability.Type.Ultimate"
## Spec keys-and-gear 2.6: where an ability works. Both tags (or, untagged, today's rule) = field and battles.
const USAGE_FIELD_TAG: StringName = &"Ability.Usage.Field"
const USAGE_BATTLE_TAG: StringName = &"Ability.Usage.Battle"
const USAGE_FIELD: int = 1
const USAGE_BATTLE: int = 2
const USAGE_BOTH: int = 3

@export var targeting: Targeting = Targeting.SINGLE_ENEMY
## Tags describing the ability itself (UE GAS's AbilityTags, which GodotGAS lacks), e.g. Ability.Type.FollowUp.
## Unlike activation_owned_tags they are never added to the unit.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var asset_tags: Array[StringName] = []
## Spec vfx-content-pass: GameplayCue tags the ability executes on its caster the moment it activates (a cast flourish, an ult's
## signature look). Plain GAS cue tags (the kernel names no effect and a headless run suppresses cues), so a cue entry decides what
## plays; never read by the log, the trace or the hash. The cue's payload carries `target_ids`: every unit the ability reaches.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var cast_cue_tags: Array[StringName] = []
## Spec item-power K3: the chance (typed %, e.g. 30) that a queued trigger of this ability fires: one battle-RNG roll per
## queued trigger, in queue order. 0 (unset) and 100 always fire and draw nothing. Triggered abilities only.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var trigger_chance: float:
	get:
		return Fixed.to_display(trigger_chance_x100)
	set(typed):
		trigger_chance_x100 = Fixed.from_typed(typed)
## Spec item-power K7: the share (typed %, e.g. 60) an echo re-runs the triggering ability at (with Ability.Type.Echo).
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var echo_scale: float:
	get:
		return Fixed.to_display(echo_scale_x100)
	set(typed):
		echo_scale_x100 = Fixed.from_typed(typed)
## Spec second-pack B3: a meter ability. While its owner's `meter_attribute` is at or above the threshold, the battle takes the
## threshold off and fires the ability (a passive: never an action, never logged; at most Battle.METER_FIRES_PER_CHECK times per
## check). The threshold is a flat value (`meter_threshold`), or a percent (`meter_threshold_percent`) of an attribute of the
## owner (`meter_threshold_of`, e.g. "max_hp"). Its heals carry Hit.Meter and never fill a meter.
@export var meter_attribute: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var meter_threshold: float:
	get:
		return Fixed.to_display(meter_threshold_x100)
	set(typed):
		meter_threshold_x100 = Fixed.from_typed(typed)
@export var meter_threshold_of: String = ""
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var meter_threshold_percent: float:
	get:
		return Fixed.to_display(meter_threshold_percent_x100)
	set(typed):
		meter_threshold_percent_x100 = Fixed.from_typed(typed)
## Saved forms (×100 whole numbers).
@export_storage var trigger_chance_x100: int = 0
@export_storage var echo_scale_x100: int = 0
@export_storage var meter_threshold_x100: int = 0
@export_storage var meter_threshold_percent_x100: int = 0
## What each hit does. The animation decides which rows run, how often and when.
@export var executions: Array[ExecutionRow] = []
## Required. Its `execute(&"<row id>")` method-track keys are the source of truth for the execution sequence.
@export var animation: Animation
## Spec ff7-ui 2.6: what the ability does, for the player (battle hints, the Status screen). Text only: never read by
## combat, never in a log or the state hash.
@export_multiline var description: String = ""
## Spec second-pack: a triggered ability fires only when the other unit its event is about (the hit target, the attacker,
## what an action was aimed at) matches this query, e.g. "a Bleeding enemy". Null = any.
@export var subject_query: GameplayTagQuery


## True when this targeting needs a target unit id in the action.
func needs_target() -> bool:
	return targeting in [Targeting.SINGLE_ENEMY, Targeting.BLAST_ENEMY, Targeting.SINGLE_ALLY, Targeting.SINGLE_DEAD_ALLY]


## True for SINGLE_DEAD_ALLY / ALL_DEAD_ALLIES: the ability reaches only dead allies.
func targets_dead() -> bool:
	return targeting in [Targeting.SINGLE_DEAD_ALLY, Targeting.ALL_DEAD_ALLIES]


## True for enemy targeting (not usable in the field, where there are no enemies).
func targets_enemies() -> bool:
	return targeting in [Targeting.SINGLE_ENEMY, Targeting.BLAST_ENEMY, Targeting.ALL_ENEMIES, Targeting.RANDOM_ENEMY,
		Targeting.RANDOM_OTHER_ENEMY, Targeting.OTHER_ENEMIES]


## Spec item-power K4: the battle picks the targets itself (a draw, or every enemy but one).
func picks_own_targets() -> bool:
	return targeting in [Targeting.RANDOM_ENEMY, Targeting.RANDOM_OTHER_ENEMY, Targeting.OTHER_ENEMIES, Targeting.LOWEST_ALLY]


## Spec item-power K4: never the unit the triggering event is about.
func spares_event_target() -> bool:
	return targeting in [Targeting.RANDOM_OTHER_ENEMY, Targeting.OTHER_ENEMIES]


## A passive that fires from a gameplay event (GodotGAS trigger_event_tag) or a full meter (spec second-pack B3). Never chosen
## as an action.
func is_triggered() -> bool:
	return trigger_event_tag != &"" or is_meter()


## Spec second-pack B3: fired by a meter.
func is_meter() -> bool:
	return meter_attribute != ""


## Spec second-pack B3: the meter value that fires this ability for `unit` (×100; 0 = never).
func meter_threshold_for(unit: BattleUnit) -> int:
	if meter_threshold_of != "":
		return Fixed.pct(unit.stat(meter_threshold_of), meter_threshold_percent_x100)
	return meter_threshold_x100


## A triggered passive tagged Ability.Type.FollowUp.
func is_follow_up() -> bool:
	return is_triggered() and asset_tags.has(FOLLOW_UP_TAG)


## Spec item-power K7: a triggered ability tagged Ability.Type.Echo.
func is_echo() -> bool:
	return is_triggered() and asset_tags.has(ECHO_TAG)


## Presentation: a triggered ability that plays its animation like an attack (a follow-up, or an Ability.Type.Strike proc).
func plays_like_attack() -> bool:
	return is_follow_up() or (is_triggered() and asset_tags.has(STRIKE_TAG))


## An action ability tagged Ability.Type.Ultimate.
func is_ultimate() -> bool:
	return not is_triggered() and asset_tags.has(ULTIMATE_TAG)


## Spec keys-and-gear 2.6: where it may be used, from its Ability.Usage.* asset tags: USAGE_FIELD, USAGE_BATTLE or
## USAGE_BOTH. Untagged: today's rule (no enemy target and an activation query that allows State.Infield: both; else
## battle), which only labels it; untagged abilities are never refused by usage (CombatASC.usage_allows).
func usage() -> int:
	var field := asset_tags.has(USAGE_FIELD_TAG)
	var battle := asset_tags.has(USAGE_BATTLE_TAG)
	if field and battle:
		return USAGE_BOTH
	if field:
		return USAGE_FIELD
	if battle:
		return USAGE_BATTLE
	var query := activation_query
	var forbids_field := query != null and (query.ignore_tags.has(Battle.IN_FIELD_TAG)
		or query.ignore_exact_tags.has(Battle.IN_FIELD_TAG))
	return USAGE_BATTLE if targets_enemies() or forbids_field else USAGE_BOTH


## True when the ability carries an Ability.Usage.* tag (the validator warns about action abilities without one).
func has_usage_tag() -> bool:
	return asset_tags.has(USAGE_FIELD_TAG) or asset_tags.has(USAGE_BATTLE_TAG)


func row_by_id(row_id: StringName) -> ExecutionRow:
	for row in executions:
		if row != null and row.id == row_id:
			return row
	return null


## Payload (set by Battle via try_activate): {"battle": Battle, "unit": BattleUnit, "primary": BattleUnit or null,
## "targets": Array[BattleUnit] in canonical order}.
func _activate_ability() -> bool:
	var action: Dictionary = current_event_payload
	var battle: Battle = action["battle"]
	var unit: BattleUnit = action["unit"]
	var hp_before := unit.stat(BattleUnit.HP)
	commit_ability()
	# Spec second-pack B1: an HP cost is announced (the Blood Pool and Bloodstone read it; it never sends Damage.Taken).
	var paid := hp_before - unit.stat(BattleUnit.HP)
	if paid > 0:
		battle.on_hp_cost(unit, paid)
	# Spec item-power K7: an echo plays and resolves the ability it repeats.
	var played: BattleAbility = action.get("echo", self)
	if not played.cast_cue_tags.is_empty() and owner_asc != null:
		# The cue's payload says which units the ability reaches (GameplayCue parameters, as in Unreal), so a cue can play an effect on each.
		var reached: Array[StringName] = []
		for reached_unit in action.get("targets", []):
			reached.append(reached_unit.unit_id)
		for cue_tag in played.cast_cue_tags:
			owner_asc.execute_cue(cue_tag, {"target_ids": reached})
	var sequence := ExecutionReader.sequence_for(played.animation)
	battle.gate.chained = is_triggered() and battle.triggers.attacks > 0
	if is_triggered() and (plays_like_attack() or played != self):
		battle.triggers.attacks += 1
	battle.gate.begin_ability(unit.unit_id, played, sequence)
	for row_id in sequence:
		await battle.gate.next_execution()
		battle.resolve_execution(unit, played, played.row_by_id(row_id), action)
	await battle.gate.finished()
	return true
