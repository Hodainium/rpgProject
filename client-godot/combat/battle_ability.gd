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
}

## A triggered ability with this asset tag is a follow-up attack (spec item-pass 3.1): its hits carry Hit.FollowUp and
## the battle sends Event.Attack.FollowUp when it fires. It is still a passive: never an action, never logged.
const FOLLOW_UP_TAG: StringName = &"Ability.Type.FollowUp"
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
## What each hit does. The animation decides which rows run, how often and when.
@export var executions: Array[ExecutionRow] = []
## Required. Its `execute(&"<row id>")` method-track keys are the source of truth for the execution sequence.
@export var animation: Animation
## Spec ff7-ui 2.6: what the ability does, for the player (battle hints, the Status screen). Text only: never read by
## combat, never in a log or the state hash.
@export_multiline var description: String = ""


## True when this targeting needs a target unit id in the action.
func needs_target() -> bool:
	return targeting in [Targeting.SINGLE_ENEMY, Targeting.BLAST_ENEMY, Targeting.SINGLE_ALLY, Targeting.SINGLE_DEAD_ALLY]


## True for SINGLE_DEAD_ALLY / ALL_DEAD_ALLIES: the ability reaches only dead allies.
func targets_dead() -> bool:
	return targeting in [Targeting.SINGLE_DEAD_ALLY, Targeting.ALL_DEAD_ALLIES]


## True for enemy targeting (not usable in the field, where there are no enemies).
func targets_enemies() -> bool:
	return targeting in [Targeting.SINGLE_ENEMY, Targeting.BLAST_ENEMY, Targeting.ALL_ENEMIES]


## A passive that fires from a gameplay event (GodotGAS trigger_event_tag). Never chosen as an action.
func is_triggered() -> bool:
	return trigger_event_tag != &""


## A triggered passive tagged Ability.Type.FollowUp.
func is_follow_up() -> bool:
	return is_triggered() and asset_tags.has(FOLLOW_UP_TAG)


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
	commit_ability()
	if not cast_cue_tags.is_empty() and owner_asc != null:
		# The cue's payload says which units the ability reaches (GameplayCue parameters, as in Unreal), so a cue can play an effect on each.
		var reached: Array[StringName] = []
		for reached_unit in action.get("targets", []):
			reached.append(reached_unit.unit_id)
		for cue_tag in cast_cue_tags:
			owner_asc.execute_cue(cue_tag, {"target_ids": reached})
	var sequence := ExecutionReader.sequence_for(animation)
	battle.gate.begin_ability(unit.unit_id, self, sequence)
	for row_id in sequence:
		await battle.gate.next_execution()
		battle.resolve_execution(unit, self, row_by_id(row_id), action)
	await battle.gate.finished()
	return true
