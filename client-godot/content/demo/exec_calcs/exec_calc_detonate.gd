## Spec second-pack: a DoT's remaining ticks at once (the Bloodletter's Siphon and Red River, Burst Vein), on x100 whole numbers:
##   damage = share x sum over the target's turn-based effects granting status_tag of
##            stacks x remaining turns x (each ExecCalcPercentOfMax on hp in the effect: target.max_hp x |percent|)
##            x source.<source_bonus>
## It only reads the DoT; the ability's next row clears it (an effect with remove_effects_with_tags: GodotGAS purges before
## it evaluates, so one effect cannot do both). No RNG, no crit, no defence: a DoT's ticks ignore them too. The hit carries
## Hit.Detonate, so the battle sends Event.Damage.Dealt.Detonate (the Siphon's party heal listens to it).
@tool
class_name ExecCalcDetonate
extends GameplayExecutionCalculation

@export_custom(PROPERTY_HINT_NONE, "gas::tag") var status_tag: StringName = &"Status.Debuff.Bleed"
## The share of the remaining ticks dealt (typed %, 100 = all of them).
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var share: float:
	get:
		return Fixed.to_display(share_x100)
	set(typed):
		share_x100 = Fixed.from_typed(typed)
@export_storage var share_x100: int = 10000
## Optional multiplier attribute of the source ("bleed_dmg"; "" = none), as the DoT's own ticks read it.
@export var source_bonus: String = "bleed_dmg"
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var detonate_hit_tag: StringName = &"Hit.Detonate"


func execute(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	var total := remaining_of(target_asc)
	if total <= 0:
		return {}
	total = Fixed.pct(total, share_x100)
	if source_bonus != "":
		total = ExecCalcRestore.bonused(total, BattleContext.source_asc(spec), target_asc, source_bonus, "")
	spec.inject_tag(detonate_hit_tag)
	return {"hp": float(-total)}


## The damage every remaining tick of the status would still deal on `target_asc` (before the share and the bonus).
func remaining_of(target_asc: AbilitySystemComponent) -> int:
	var maximum := target_asc.get_attribute("max_hp")
	if maximum == null:
		return 0
	var total := 0
	for active_effect in target_asc._active_effects:
		var effect := active_effect.get_effect_def()
		if effect == null or not effect.granted_tags.has(status_tag) \
				or effect.policy != GameplayEffect.DurationPolicy.TURN_BASED:
			continue
		var tick := 0
		for execution in effect.executions:
			if execution is ExecCalcPercentOfMax and execution.attribute == "hp" and execution.percent_x100 < 0:
				tick += Fixed.pct(int(maximum.current_value), -execution.percent_x100)
		total += tick * active_effect.stack_count * maxi(active_effect.spec.remaining_turns, 0)
	return total
