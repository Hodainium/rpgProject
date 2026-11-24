## Spec bot-play 2.3: proposes an item's or a gear piece's Item.Fit.* and Item.Grants.* tags from its GAS data, the
## build_role_pass pattern. Read by game/tools/build_fit_pass.tscn (the pass) and the content validator (fit_mismatch).
## Modifiers on attack and damage attributes → Damage, on HP / DEF / damage taken → Survival, SPD → Speed, SP → Sp, ult
## charge → Ult, toughness and broken damage → Break, healing given → Healing, debuff length → Control; a granted
## follow-up → FollowUp and Grants.FollowUp, another damaging passive → FollowUp (an on-hit proc), a DoT status →
## Dot and Grants.Dot, a control status → Control, a taunt or a hit back on damage taken → Survival and Grants.Tank,
## a granted move healing allies → Healing and Grants.Healer; immunities, resists, drains and Ward → Survival; a
## passive covering the party, applies_to PARTY or a party hook → Party; a use item by its use ability's Ability.Role.*
## tags; a run hook, a Run.* tag or more use slots (coins, keys, chests, the map) → Run. Only gains count (a corrupted
## item's downside is no fit).
class_name FitProposal
extends RefCounted

const DAMAGE_ATTRIBUTES: Array[String] = ["atk", "dmg_mult", "crit_rate", "crit_dmg", "weakness_dmg", "def_pen"]
const SURVIVAL_ATTRIBUTES: Array[String] = ["max_hp", "def", "hp", "heal_taken", "resist_dmg"]
const SP_ATTRIBUTES: Array[String] = ["mp", "max_mp", "sp_gain", "sp_basic"]
const ULT_ATTRIBUTES: Array[String] = ["energy", "energy_regen", "max_energy"]
const BREAK_ATTRIBUTES: Array[String] = ["toughness_dmg", "broken_dmg"]
## Lower is better on these.
const LOWER_SURVIVAL: Array[String] = ["dmg_taken"]
const LOWER_SP: Array[String] = ["sp_cost"]
const DOT_STATUSES: Array[String] = ["Status.Debuff.Burn", "Status.Debuff.Poison", "Status.Debuff.Bleed"]
const CONTROL_STATUSES: Array[String] = ["Status.Debuff.Stun", "Status.Debuff.Freeze", "Status.Debuff.Entangle",
	"Status.Debuff.Slow"]
const DAMAGE_DEBUFFS: Array[String] = ["Status.Debuff.DefenseDown", "Status.Debuff.Vulnerable", "Status.Debuff.Exposed"]
const SURVIVAL_DEBUFFS: Array[String] = ["Status.Debuff.AttackDown", "Status.Debuff.Weaken"]
const TAUNT_TAGS: Array[String] = ["Status.Buff.Taunt", "State.Taunting"]
## Granted or loose tags that keep the holder alive: immunities, resists, drains, Ward.
const SURVIVAL_TAG_PREFIXES: Array[String] = ["Immune.", "Resist.", "Drain."]
const SURVIVAL_TAGS: Array[String] = ["Status.Buff.Ward"]
const DAMAGE_TAKEN_EVENT: String = "Event.Damage.Taken"
const FOLLOW_UP_TAG: StringName = &"Ability.Type.FollowUp"
const RUN_TAG_PREFIX: String = "Run."
## Hooks that act on members (a food heal) are not run hooks.
const MEMBER_OUTCOMES: Array[String] = ["ApplyHolderEffect", "ApplyPartyEffect", "ApplyMemberEffect"]
const HEAL_WORDS: Array[String] = ["heal", "regen", "mend", "sanctuary", "salve", "holy", "potion", "restore"]


## The proposed Item.Fit.* and Item.Grants.* tags of an ItemDefinition or EquipmentDefinition, in LootScorer order.
static func propose(thing: Resource) -> Array[StringName]:
	var found := {}
	var grants: AbilitySet = thing.get("grants")
	if grants != null:
		for effect in grants.effects:
			_effect(effect, found)
		for scene in grants.abilities:
			_ability(scene, found, false)
		for tag in grants.tags:
			_status(String(tag), found, false)
	if thing is ItemDefinition:
		var item: ItemDefinition = thing
		if item.is_usable() and item.use_ability != null:
			_ability(item.use_ability, found, true)
		if item.applies_to == ItemDefinition.AppliesTo.PARTY:
			found[LootScorer.FIT_PARTY] = true
		if item.extra_use_slots > 0:
			found[LootScorer.FIT_RUN] = true  # more use slots: who carries it hardly matters
		for hook in ["on_pickup", "on_floor_start", "on_room_cleared"]:
			for outcome in item.get(hook):
				if outcome == null:
					continue
				var script_name := str(outcome.get_script().get_global_name()) if outcome.get_script() != null else ""
				if MEMBER_OUTCOMES.has(script_name):
					var effect: GameplayEffect = outcome.get("effect")
					if effect != null:
						_effect(effect, found)
					if script_name == "ApplyPartyEffect":
						found[LootScorer.FIT_PARTY] = true
				else:
					found[LootScorer.FIT_RUN] = true
	var tags: Array = thing.get("tags")
	if tags.any(func(tag) -> bool: return String(tag).begins_with(RUN_TAG_PREFIX)):
		found[LootScorer.FIT_RUN] = true
	var ordered: Array[StringName] = []
	for tag in LootScorer.FITS + LootScorer.GRANTS:
		if found.has(tag):
			ordered.append(tag)
	return ordered


## The proposal's tags the thing lacks.
static func missing(thing: Resource) -> Array[StringName]:
	var tags: Array = thing.get("tags")
	var result: Array[StringName] = []
	for tag in propose(thing):
		if not tags.has(tag):
			result.append(tag)
	return result


## An effect's gains on the unit it lands on: modifiers and attribute ExecCalcs by attribute, the tags it grants.
static func _effect(effect: GameplayEffect, found: Dictionary) -> void:
	if effect == null:
		return
	for modifier in effect.modifiers:
		_modifier(modifier, found)
	_calcs(effect, found)
	for tag in effect.granted_tags:
		_status(String(tag), found, false)


## ExecCalcs that add to an attribute (`attribute` with a positive `amount_x100` or `percent_x100`: the ult-charge and
## percent-restore calcs).
static func _calcs(effect: GameplayEffect, found: Dictionary) -> void:
	for calc in effect.executions:
		if calc == null or not calc.get("attribute") is String:
			continue
		for field in ["amount_x100", "percent_x100"]:
			var amount: Variant = calc.get(field)
			if amount != null and int(amount) > 0:
				_attribute(str(calc.get("attribute")), found)
				break


static func _modifier(modifier: GameplayEffectModifier, found: Dictionary) -> void:
	if modifier == null:
		return
	var attribute := str(modifier.attribute_name)
	var raw: Variant = modifier.get("value_x100")
	var amount := int(raw) if raw != null else 0
	# Whether the modifier raises or lowers the attribute (MULTIPLY / DIVIDE factors are ×100: 100 changes nothing).
	var raises := amount > 0
	var lowers := amount < 0
	match modifier.operation:
		GameplayEffectModifier.Operation.MULTIPLY:
			raises = amount > 100
			lowers = amount > 0 and amount < 100
		GameplayEffectModifier.Operation.DIVIDE:
			raises = amount > 0 and amount < 100
			lowers = amount > 100
		GameplayEffectModifier.Operation.OVERRIDE:
			lowers = false
	var gain := lowers if LOWER_SURVIVAL.has(attribute) or LOWER_SP.has(attribute) else raises
	if not gain:
		return
	_attribute(attribute, found)


## The fit a gain on `attribute` shows.
static func _attribute(attribute: String, found: Dictionary) -> void:
	if DAMAGE_ATTRIBUTES.has(attribute):
		found[LootScorer.FIT_DAMAGE] = true
	elif SURVIVAL_ATTRIBUTES.has(attribute) or LOWER_SURVIVAL.has(attribute):
		found[LootScorer.FIT_SURVIVAL] = true
	elif attribute == "spd":
		found[LootScorer.FIT_SPEED] = true
	elif SP_ATTRIBUTES.has(attribute) or LOWER_SP.has(attribute):
		found[LootScorer.FIT_SP] = true
	elif ULT_ATTRIBUTES.has(attribute):
		found[LootScorer.FIT_ULT] = true
	elif BREAK_ATTRIBUTES.has(attribute):
		found[LootScorer.FIT_BREAK] = true
	elif attribute == "heal_mult":
		found[LootScorer.FIT_HEALING] = true
	elif attribute == "debuff_turns":
		found[LootScorer.FIT_CONTROL] = true


## A status an effect grants. `on_enemy`: applied by a move or passive to its target (a debuff the holder deals).
static func _status(tag: String, found: Dictionary, on_enemy: bool) -> void:
	if DOT_STATUSES.has(tag) and on_enemy:
		found[LootScorer.FIT_DOT] = true
		found[LootScorer.GRANT_DOT] = true
	elif CONTROL_STATUSES.has(tag) and on_enemy:
		found[LootScorer.FIT_CONTROL] = true
	elif DAMAGE_DEBUFFS.has(tag) and on_enemy:
		found[LootScorer.FIT_DAMAGE] = true
	elif SURVIVAL_DEBUFFS.has(tag) and on_enemy:
		found[LootScorer.FIT_SURVIVAL] = true
	elif TAUNT_TAGS.has(tag) and not on_enemy:
		found[LootScorer.FIT_SURVIVAL] = true
		found[LootScorer.GRANT_TANK] = true
	elif not on_enemy and (SURVIVAL_TAGS.has(tag) or SURVIVAL_TAG_PREFIXES.any(func(prefix: String) -> bool:
			return tag.begins_with(prefix))):
		found[LootScorer.FIT_SURVIVAL] = true


## A granted or use ability. `use`: a use item's ability, read by its Ability.Role.* tags.
static func _ability(scene: PackedScene, found: Dictionary, use: bool) -> void:
	if scene == null:
		return
	var node := scene.instantiate()
	var ability := node as BattleAbility
	if ability == null:
		if node != null:
			node.free()
		return
	if use:
		for role in ability.asset_tags:
			match role:
				AutoPolicy.ROLE_DAMAGE, AutoPolicy.ROLE_DEBUFF, AutoPolicy.ROLE_DISPEL:
					found[LootScorer.FIT_DAMAGE] = true
				AutoPolicy.ROLE_HEAL, AutoPolicy.ROLE_REVIVE, AutoPolicy.ROLE_CLEANSE, AutoPolicy.ROLE_BUFF:
					found[LootScorer.FIT_PARTY] = true
				AutoPolicy.ROLE_RESTORE_MP:
					found[LootScorer.FIT_SP] = true
				AutoPolicy.ROLE_GUARD:
					found[LootScorer.FIT_SURVIVAL] = true
		ability.free()
		return
	var triggered := ability.is_triggered()
	var deals := false
	for row in ability.executions:
		if row == null:
			continue
		var effect := row.effect
		# A row that sets a DoT is the DoT, not a hit.
		var dot := effect != null and effect.granted_tags.any(func(tag) -> bool: return DOT_STATUSES.has(String(tag)))
		if not dot and (row.damage_mode != ExecutionRow.DamageMode.USE_EFFECT
				or effect != null and effect.policy == GameplayEffect.DurationPolicy.INSTANT and not effect.executions.is_empty()):
			deals = deals or ability.targets_enemies()
		if row.toughness_x100 > 0 and ability.targets_enemies():
			found[LootScorer.FIT_BREAK] = true
		if effect == null:
			continue
		for tag in effect.granted_tags:
			_status(String(tag), found, ability.targets_enemies())
		if not ability.targets_enemies():
			if _heals(effect):
				if ability.targeting == BattleAbility.Targeting.SELF:
					found[LootScorer.FIT_SURVIVAL] = true
				else:
					found[LootScorer.FIT_HEALING] = true
					if not triggered:
						found[LootScorer.GRANT_HEALER] = true
			else:
				for modifier in effect.modifiers:
					_modifier(modifier, found)
				_calcs(effect, found)
	if ability.targets_dead():
		found[LootScorer.FIT_SURVIVAL] = true
	if triggered and ability.targeting == BattleAbility.Targeting.ALL_ALLIES:
		found[LootScorer.FIT_PARTY] = true  # a passive that covers the party: the holder matters only for staying alive
	if triggered and ability.targets_enemies() and String(ability.trigger_event_tag).begins_with(DAMAGE_TAKEN_EVENT):
		found[LootScorer.FIT_SURVIVAL] = true
		found[LootScorer.GRANT_TANK] = true
	if deals:
		if ability.asset_tags.has(FOLLOW_UP_TAG):
			found[LootScorer.FIT_FOLLOW_UP] = true
			found[LootScorer.GRANT_FOLLOW_UP] = true
		elif triggered and String(ability.trigger_event_tag).begins_with(DAMAGE_TAKEN_EVENT):
			pass  # a hit back: Survival and Tank above
		elif triggered:
			found[LootScorer.FIT_FOLLOW_UP] = true
		else:
			found[LootScorer.FIT_DAMAGE] = true
	ability.free()


static func _heals(effect: GameplayEffect) -> bool:
	if effect.granted_tags.has(&"Status.Buff.Regen"):
		return true
	for modifier in effect.modifiers:
		if modifier != null and str(modifier.attribute_name) == "hp" and modifier.get("value_x100") != null \
				and int(modifier.get("value_x100")) > 0:
			return true
	for calc in effect.executions:
		if calc == null or calc.get("attribute") != "hp":
			continue
		for field in ["percent_x100", "amount_x100"]:
			if calc.get(field) != null and int(calc.get(field)) > 0:
				return true
	var file := effect.resource_path.get_file().to_lower()
	return HEAL_WORDS.any(func(word: String) -> bool: return file.contains(word))
