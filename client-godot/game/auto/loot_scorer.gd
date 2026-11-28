## Spec bot-play 2.3, 2.4: how the smart run bot values an item, a gear piece or a purchase for a party member. Pure and
## static: every judgement is read from tags (`Unit.Role.*` on characters, `Item.Fit.*` / `Item.Grants.*` on items and
## pieces) and the numbers from a BotProfile. Scores are whole numbers (×100 shares); ties go to the lowest slot, then the
## id compared as String (never StringName order). Bot code, not game balance.
class_name LootScorer
extends RefCounted

const ROLE_PREFIX: String = "Unit.Role."
const FIT_PREFIX: String = "Item.Fit."
const GRANT_PREFIX: String = "Item.Grants."

const ROLE_DAMAGE: StringName = &"Unit.Role.Damage"
const ROLE_FOLLOW_UP: StringName = &"Unit.Role.FollowUp"
const ROLE_DOT: StringName = &"Unit.Role.Dot"
const ROLE_BREAK: StringName = &"Unit.Role.Break"
const ROLE_HEALER: StringName = &"Unit.Role.Healer"
const ROLE_SUPPORT: StringName = &"Unit.Role.Support"
const ROLE_TANK: StringName = &"Unit.Role.Tank"
const ROLE_CONTROL: StringName = &"Unit.Role.Control"
const ROLES: Array[StringName] = [ROLE_DAMAGE, ROLE_FOLLOW_UP, ROLE_DOT, ROLE_BREAK, ROLE_HEALER, ROLE_SUPPORT,
	ROLE_TANK, ROLE_CONTROL]

const FIT_DAMAGE: StringName = &"Item.Fit.Damage"
const FIT_FOLLOW_UP: StringName = &"Item.Fit.FollowUp"
const FIT_DOT: StringName = &"Item.Fit.Dot"
const FIT_BREAK: StringName = &"Item.Fit.Break"
const FIT_HEALING: StringName = &"Item.Fit.Healing"
const FIT_SURVIVAL: StringName = &"Item.Fit.Survival"
const FIT_SPEED: StringName = &"Item.Fit.Speed"
const FIT_SP: StringName = &"Item.Fit.Sp"
const FIT_ULT: StringName = &"Item.Fit.Ult"
const FIT_CONTROL: StringName = &"Item.Fit.Control"
const FIT_PARTY: StringName = &"Item.Fit.Party"
const FIT_RUN: StringName = &"Item.Fit.Run"
## Spec second-pack 2.7: Bleed chance and lifesteal add up per holder, so the bots gather them on one carrier (CARRY).
const FIT_BLEED: StringName = &"Item.Fit.Bleed"
const FIT_LIFESTEAL: StringName = &"Item.Fit.Lifesteal"
## Spec second-pack 2.7: crit items, worth more on a holder with a high base crit rate or Focus (BotProfile.crit_*), and items that
## pay off HP costs, worth little to a class with no HP-cost move.
const FIT_CRIT: StringName = &"Item.Fit.Crit"
const FIT_HP_COST: StringName = &"Item.Fit.HpCost"
## The base crit rate (×100) above which a class counts as a crit holder: the default 5%.
const DEFAULT_CRIT_RATE: int = 500
const FITS: Array[StringName] = [FIT_DAMAGE, FIT_FOLLOW_UP, FIT_DOT, FIT_BREAK, FIT_HEALING, FIT_SURVIVAL, FIT_SPEED,
	FIT_SP, FIT_ULT, FIT_CONTROL, FIT_PARTY, FIT_RUN, FIT_BLEED, FIT_LIFESTEAL, FIT_CRIT, FIT_HP_COST]
## The damage kinds: a carry is the member who piles these up (placement report, carry_seed).
const DAMAGE_FITS: Array[StringName] = [FIT_DAMAGE, FIT_FOLLOW_UP, FIT_DOT, FIT_BREAK]

const GRANT_FOLLOW_UP: StringName = &"Item.Grants.FollowUp"
const GRANT_DOT: StringName = &"Item.Grants.Dot"
const GRANT_HEALER: StringName = &"Item.Grants.Healer"
const GRANT_TANK: StringName = &"Item.Grants.Tank"
const GRANT_BREAK: StringName = &"Item.Grants.Break"
const GRANT_CONTROL: StringName = &"Item.Grants.Control"
const GRANT_DAMAGE: StringName = &"Item.Grants.Damage"
const GRANT_SUPPORT: StringName = &"Item.Grants.Support"
const GRANTS: Array[StringName] = [GRANT_DAMAGE, GRANT_FOLLOW_UP, GRANT_DOT, GRANT_BREAK, GRANT_HEALER, GRANT_SUPPORT,
	GRANT_TANK, GRANT_CONTROL]

const CURSE_TAG: StringName = &"Item.Curse"
## Every tag the bots read (spec bot-play 2.3), for sync_tags' system-tag check: a typo in content or code fails it.
const ALL_TAGS: Array[StringName] = [
	ROLE_DAMAGE, ROLE_FOLLOW_UP, ROLE_DOT, ROLE_BREAK, ROLE_HEALER, ROLE_SUPPORT, ROLE_TANK, ROLE_CONTROL,
	FIT_DAMAGE, FIT_FOLLOW_UP, FIT_DOT, FIT_BREAK, FIT_HEALING, FIT_SURVIVAL, FIT_SPEED, FIT_SP, FIT_ULT, FIT_CONTROL,
	FIT_PARTY, FIT_RUN, FIT_BLEED, FIT_LIFESTEAL, FIT_CRIT, FIT_HP_COST,
	GRANT_DAMAGE, GRANT_FOLLOW_UP, GRANT_DOT, GRANT_BREAK, GRANT_HEALER, GRANT_SUPPORT, GRANT_TANK, GRANT_CONTROL,
]
## The weight key a role-less member (or one whose roles a fit does not name) is scored with.
const ANY_ROLE: String = "*"
const SURVIVAL_CAP: int = 200
const SPREAD_FLOOR: int = 25
const CARRY_CAP: int = 200
## A context's max_hp that says nothing about anyone (everyone counts as equally sturdy).
const NO_MAX_HP: Dictionary = {0: 0}


## A scoring context for one decision: the run, the profile and the members' max HP (read once, lazily: party_stats builds
## a field battle). Pass the same context to every call of one decision so the stats are read once.
static func context(run: RunController, profile: BotProfile) -> Dictionary:
	return {"run": run, "profile": profile, "max_hp": {}}


## The member's live roles (spec 2.3): the class's Unit.Role.* tags plus every Item.Grants.* of the member's held
## items, use items and worn pieces (as Unit.Role.<suffix>), sorted by name.
static func roles_of(run: RunController, slot: int, without: StringName = &"") -> Array[StringName]:
	var member := run.state.member(slot)
	var found := {}
	if member.is_empty():
		return []
	var character: UnitDefinition = run.content.units.get(member["character"])
	if character != null:
		for tag in character.tags:
			if String(tag).begins_with(ROLE_PREFIX):
				found[String(tag)] = true
	for tags in held_tags(run, member, without):
		for tag in tags:
			if String(tag).begins_with(GRANT_PREFIX):
				found[ROLE_PREFIX + String(tag).trim_prefix(GRANT_PREFIX)] = true
	var names: Array[String] = []
	names.assign(found.keys())
	names.sort()
	var roles: Array[StringName] = []
	for name in names:
		roles.append(StringName(name))
	return roles


## The tag lists of everything the member holds and wears (items, use items, worn pieces); `without` leaves one copy of
## that id out (the thing being valued, when the member already has it).
static func held_tags(run: RunController, member: Dictionary, without: StringName = &"") -> Array:
	var lists: Array = []
	var skipped := without == &""
	for item_id in member["items"]:
		if not skipped and item_id == without:
			skipped = true
			continue
		var item: ItemDefinition = run.content.items.get(item_id)
		if item != null:
			lists.append(item.tags)
	for use_slot in member["use_slots"]:
		if not skipped and use_slot["item"] == without:
			skipped = true
			continue
		var used: ItemDefinition = run.content.items.get(use_slot["item"])
		if used != null:
			lists.append(used.tags)
	for slot_tag in _sorted_names(member["equipment"].keys()):
		var piece_id: StringName = member["equipment"][slot_tag]
		if not skipped and piece_id == without:
			skipped = true
			continue
		var piece: EquipmentDefinition = run.content.equipment.get(piece_id)
		if piece != null:
			lists.append(piece.tags)
	return lists


## The fits of a thing (its Item.Fit.* tags, in FITS order).
static func fits_of(tags: Array) -> Array[StringName]:
	var fits: Array[StringName] = []
	for fit in FITS:
		if tags.has(fit):
			fits.append(fit)
	return fits


static func is_bad(tags: Array) -> bool:
	return tags.has(CURSE_TAG)


## The value (×100 points) of a thing with `tags` and id `thing_id` for the member in `slot` (spec 2.4). A dead member
## values everything at 0. `thing_id`: when the member already has that id (a worn piece being compared, a use item
## being moved), one copy of it is left out of the member's counts and roles.
static func value(ctx: Dictionary, tags: Array, slot: int, thing_id: StringName = &"") -> int:
	var run: RunController = ctx["run"]
	var profile: BotProfile = ctx["profile"]
	var member := run.state.member(slot)
	if member.is_empty() or not member["alive"]:
		return 0
	var fits := fits_of(tags)
	if fits.is_empty():
		return 0
	var roles := roles_of(run, slot, thing_id)
	var held := held_tags(run, member, thing_id)
	var total := 0
	for fit in fits:
		if fit == FIT_PARTY:
			total += _party_value(ctx, slot, roles, held)
			continue
		if fit == FIT_RUN:
			total += profile.weight(fit, roles)
			continue
		var part := profile.weight(fit, roles) * stack_factor(profile, fit, held) / 100
		if fit == FIT_SURVIVAL:
			part = part * frailty(ctx, slot) / 100
		elif fit == FIT_CRIT and crit_holder(run, slot, profile):
			part = part * profile.crit_holder_percent / 100
		elif fit == FIT_HP_COST and not pays_hp(run, slot):
			part = part * profile.hp_cost_other_percent / 100
		total += part
	for tag in tags:
		if String(tag).begins_with(GRANT_PREFIX):
			var role := StringName(ROLE_PREFIX + String(tag).trim_prefix(GRANT_PREFIX))
			if not roles.has(role):
				total += profile.new_role_value
	return total


## The stack factor (percent) of `fit` given the member's held tag lists (spec 2.4): SPREAD falls by the step per held
## thing of that fit (floor 25), FLAT stays 100, CARRY grows by the step (cap 200). With carry_seed, a CARRY fit counts
## every held thing of any CARRY fit, so one member becomes the party's carry across damage kinds.
static func stack_factor(profile: BotProfile, fit: StringName, held: Array) -> int:
	var mode := profile.stack_mode(fit)
	if mode == BotProfile.FLAT:
		return 100
	var count := 0
	for tags in held:
		if tags.has(fit):
			count += 1
		elif mode == BotProfile.CARRY and profile.carry_seed and tags.any(
				func(tag) -> bool: return profile.stack_mode(tag) == BotProfile.CARRY and FITS.has(tag)):
			count += 1
	var step := profile.stack_step(fit)
	if mode == BotProfile.SPREAD:
		return maxi(SPREAD_FLOOR, 100 - step * count)
	return mini(CARRY_CAP, 100 + step * count)


## Spec second-pack 2.7: whether the member's class is a crit holder: a base crit rate above the default 5% (the Hunter, the
## Ranger), or one of the profile's crit_holder_abilities among its class abilities (Focus).
static func crit_holder(run: RunController, slot: int, profile: BotProfile) -> bool:
	var member := run.state.member(slot)
	var character: UnitDefinition = run.content.units.get(member.get("character", &"")) if not member.is_empty() else null
	if character == null:
		return false
	if int(character.stats_x100.get("crit_rate", 0)) > DEFAULT_CRIT_RATE:
		return true
	return _class_abilities(character).any(func(tag: StringName) -> bool: return profile.crit_holder_abilities.has(tag))


## Spec second-pack 2.7: whether the member's class has a move that costs HP (CostReader names an hp cost).
static func pays_hp(run: RunController, slot: int) -> bool:
	var member := run.state.member(slot)
	var character: UnitDefinition = run.content.units.get(member.get("character", &"")) if not member.is_empty() else null
	if character == null:
		return false
	if not _hp_payers.has(character.id):
		var pays := false
		for scene in character.abilities:
			var ability := scene.instantiate() as BattleAbility if scene != null else null
			if ability != null:
				pays = pays or CostReader.cost_of(ability, null).has(BattleUnit.HP)
				ability.free()
		_hp_payers[character.id] = pays
	return _hp_payers[character.id]


## A class's ability tags, read once per definition (the scenes are instantiated only here).
static func _class_abilities(character: UnitDefinition) -> Array[StringName]:
	if not _ability_tags.has(character.id):
		var tags: Array[StringName] = []
		for scene in character.abilities:
			var ability := scene.instantiate() as BattleAbility if scene != null else null
			if ability != null:
				tags.append(ability.ability_tag)
				ability.free()
		_ability_tags[character.id] = tags
	return _ability_tags[character.id]


static var _hp_payers: Dictionary = {}
static var _ability_tags: Dictionary = {}


## Item.Fit.Survival's extra (percent): the party's highest max HP × 100 / the member's, capped at 200; the frailest first.
static func frailty(ctx: Dictionary, slot: int) -> int:
	var max_hp := max_hp_of(ctx)
	var highest := 0
	for key in max_hp:
		highest = maxi(highest, int(max_hp[key]))
	var own := int(max_hp.get(slot, 0))
	if own <= 0 or highest <= 0:
		return 100
	return mini(SURVIVAL_CAP, highest * 100 / own)


## Item.Fit.Party (spec 2.4): only staying alive matters, so the holder is the sturdiest: the weight scaled by the
## member's share of the party's highest max HP, plus the survival step per Survival-fit thing held and the Tank bonus.
static func _party_value(ctx: Dictionary, slot: int, roles: Array[StringName], held: Array) -> int:
	var profile: BotProfile = ctx["profile"]
	var max_hp := max_hp_of(ctx)
	var highest := 0
	for key in max_hp:
		highest = maxi(highest, int(max_hp[key]))
	var share := int(max_hp.get(slot, 0)) * 100 / highest if highest > 0 else 100
	var survival := 0
	for tags in held:
		if tags.has(FIT_SURVIVAL):
			survival += 1
	var tank := profile.party_tank_bonus if roles.has(ROLE_TANK) else 0
	return profile.weight(FIT_PARTY, roles) * share / 100 + profile.party_survival_step * survival + tank


## slot -> max HP (×100), read once per context through BotCache.party_stats.
static func max_hp_of(ctx: Dictionary) -> Dictionary:
	if ctx["max_hp"].is_empty():
		var run: RunController = ctx["run"]
		var stats := BotCache.party_stats(run)
		for slot in stats:
			ctx["max_hp"][slot] = int(stats[slot].get(BattleUnit.MAX_HP, 0))
		if ctx["max_hp"].is_empty():
			ctx["max_hp"][0] = 0  # nothing to read; keeps the context from asking again
	return ctx["max_hp"]


## The living member who should get an item (spec 2.4): the highest value among those who can hold it, ties to the lowest
## slot (an untagged item scores 0 for everyone, so it goes to the first who can hold it, today's rule). 0 = nobody.
static func best_holder(ctx: Dictionary, item: ItemDefinition) -> int:
	var run: RunController = ctx["run"]
	var best := 0
	var best_value := -1
	for member in run.state.party:
		if run.can_hold(member["slot"], item) != "":
			continue
		var score := value(ctx, item.tags, member["slot"])
		if score > best_value:
			best = member["slot"]
			best_value = score
	return best


## The best value of a thing over the living members (and who), ties to the lowest slot: [value, slot] (slot 0: nobody).
static func best_value(ctx: Dictionary, tags: Array, item: ItemDefinition = null) -> Array:
	var run: RunController = ctx["run"]
	var best := 0
	var best_value := -1
	for member in run.state.party:
		if not member["alive"] or item != null and run.can_hold(member["slot"], item) != "":
			continue
		var score := value(ctx, tags, member["slot"])
		if score > best_value:
			best = member["slot"]
			best_value = score
	return [maxi(best_value, 0), best]


static func _sorted_names(keys: Array) -> Array:
	var names := keys.duplicate()
	names.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	return names
