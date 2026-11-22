## One-time builder for spec event-pass 3.2: the new events (10 general, 8 found, 3 per chapter), the event-only items
## (curses and boons) and their three abilities, the event-only encounters and the Reflection, and the event effects
## (hurt, heal, slay), written into res://content/demo/ through ResourceSaver like the other content builders, whose
## helpers it reuses.
##
## Same rules: it never overwrites (an existing file is skipped and used), it writes nowhere but content/demo/, and it
## never touches an existing file (the chapters' event queries, the nook's weight, the existing events' choice tags and
## the Collector's mirror_skip_tags are edited by hand, spec 3.1). Every choice gets the Choice.* tags its outcomes call
## for (ContentValidator.choice_tags_for, one page deep, plus a fight's rewards), so the validator agrees by
## construction. Values are the spec's starting proposals, typed as a designer would; tune them in the files.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_event_pass.tscn [-- --replace-own]
## Every choice ends on a page that tells what happened (user, 2026-11-22): see _story.
extends "res://game/tools/build_full_descent.gd"

const GENERAL := &"Event.Demo"
const EVENT_ENCOUNTER := &"Encounter.Event"
const CURSE := &"Item.Curse"
const BOON := &"Item.Boon"
const CLASS_TAG := &"Choice.Class"
const LEAVE_TAG := &"Choice.Leave"
const NOT_CONTROLLED := "res://content/demo/queries/not_controlled.tres"
const WEAPON := &"Equipment.Slot.Weapon"

## character name -> CharacterDefinition
var _chars := {}
## Event endings (user's one-off OK, 2026-11-22): `-- --replace-own` rewrites this builder's own event files.
var _replace_own := OS.get_cmdline_user_args().has("--replace-own")


func _ready() -> void:
	if not ResourceLoader.exists(GENERATED_SET) or load(PERCENT_OF_MAX) == null:
		_quit("Needs %s and %s (run --import once first)." % [GENERATED_SET, PERCENT_OF_MAX])
		return
	_attributes = load(ATTRIBUTES)
	for name in ["damage", "burn", "slow", "haste", "weaken", "ward", "dispel", "sp_cost_19", "sp_cost_25", "sp_cost_33"]:
		_r["effects/" + name] = load(CONTENT + "effects/%s.tres" % name)
	for name in ["bite", "fire_bolt", "dispel"]:
		_r["animations/" + name] = load(CONTENT + "animations/%s.tres" % name)
	_r["abilities/vampire_fang"] = load(CONTENT + "abilities/vampire_fang.tscn")
	for name in ["knight", "bat", "smelter", "anvil_guard", "glass_saint", "penitent_knight", "tally_clerk", "hag_sister",
			"coven_familiar", "hollow_echo", "vein_weaver", "gutter_maw", "leech", "slime", "cinder_hound"]:
		_r["enemies/" + name] = load(CONTENT + "enemies/%s.tres" % name)
	for name in ["slime_pair"]:
		_r["encounters/" + name] = load(CONTENT + "encounters/%s.tres" % name)
	for name in ["wooden_chest", "gilded_chest"]:
		_r["chests/" + name] = load(CONTENT + "chests/%s.tres" % name)
	for name in ["warrior", "cleric", "arcanist", "bard", "ranger", "cryomancer", "pyromancer", "bulwark", "ember_knight",
			"shatterweaver", "plaguewright"]:
		_chars[name] = load(CONTENT + "characters/%s.tres" % name)
		if _chars[name] == null:
			_quit("Missing %scharacters/%s.tres" % [CONTENT, name])
			return
	_r["queries/not_controlled"] = load(NOT_CONTROLLED)
	for key in _r:
		if _r[key] == null:
			_quit("Missing %s%s" % [CONTENT, key])
			return
	_event_effects()
	_event_abilities()
	_event_items()
	_event_encounters()
	_general_events()
	_found_events()
	_chapter_events()
	print("build_event_pass: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _made:
		print("  made    ", path)
	for path in _skipped:
		print("  skipped ", path)
	for path in _failed:
		print("  FAILED  ", path)
	get_tree().quit(1 if not _failed.is_empty() else 0)


# --- Effects (spec 3.2: hurt_<n>, heal_<n>, slay; and the event items' lasting effects) ---------------------------------

func _event_effects() -> void:
	for percent in [10, 15, 20, 25, 30, 40]:
		_save("effects/events/hurt_%d" % percent, _percent_of_max(-percent))
	for percent in [15, 20, 30]:
		_save("effects/events/heal_%d" % percent, _percent_of_max(percent))
	_save("effects/events/heal_full", _percent_of_max(100))
	var slay := GameplayEffect.new()  # hp overridden to 0: the member dies (the validator reads it as a slay)
	var to_zero := GameplayEffectModifier.new()
	to_zero.attribute_name = "hp"
	to_zero.operation = GameplayEffectModifier.Operation.OVERRIDE
	to_zero.magnitude = 0.0
	slay.modifiers.append(to_zero)
	_save("effects/events/slay", slay)
	_save("effects/events/vampire_curse", _infinite({"max_hp": -15}, true))
	_save("effects/events/leech_bond", _infinite({"atk": 12, "def": -10}, true))
	_save("effects/events/void_mark", _infinite({"max_mp": -10}, true))


# --- Abilities (the event items' moves, on existing animations) -----------------------------------------------------------

## A party move on an existing animation (its execute keys name the rows), Battle only, with an SP cost.
func _move(name: String, title: String, tag: String, targeting: BattleAbility.Targeting, rows: Array, animation: String,
		cost: String, roles: Array, description: String) -> void:
	var path := CONTENT + "abilities/events/%s.tscn" % name
	if not _exists(path):
		var ability := BattleAbility.new()
		ability.name = name.to_pascal_case()
		ability.ability_name = title
		ability.ability_tag = StringName(tag)
		ability.targeting = targeting
		var typed_rows: Array[ExecutionRow] = []
		typed_rows.assign(rows)
		ability.executions = typed_rows
		ability.animation = _r["animations/" + animation]
		ability.cost_effect = _r["effects/" + cost]
		ability.activation_query = _r["queries/not_controlled"]
		ability.asset_tags.assign(roles + [&"Ability.Usage.Battle"])
		ability.description = description
		_pack(path, ability)
	_r["abilities/events/" + name] = load(path)


func _event_abilities() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	_move("blood_drain", "Blood Drain", "Ability.Blooddrain", B.SINGLE_ENEMY,
		[_row("bite", "damage", D.SCALED, 130, T.ALL, [&"Damage.Type.Physical"])], "bite", "sp_cost_25",
		[&"Ability.Role.Damage"], "Physical damage to one enemy. With the Vampire's curse, every hit heals.")
	_move("molten_strike", "Molten Strike", "Ability.Moltenstrike", B.SINGLE_ENEMY,
		[_toughness(_row("bolt", "damage", D.SCALED, 140, T.ALL, [&"Damage.Type.Fire"]), 20),
			_chance(_row("burn", "burn", D.FLAT, 30, T.ALL, [&"Damage.Type.Fire"]), 40)], "fire_bolt", "sp_cost_33",
		[&"Ability.Role.Damage", &"Ability.Role.Debuff"], "Fire damage to one enemy that breaks toughness well. 40% to Burn.")
	_move("unravel", "Unravel", "Ability.Unravel", B.SINGLE_ENEMY,
		[_chance(_row("dispel", "dispel", D.USE_EFFECT, 0, T.ALL), 100)], "dispel", "sp_cost_19",
		[&"Ability.Role.Dispel"], "Strips one enemy's buffs.")


func _toughness(row: ExecutionRow, typed: float) -> ExecutionRow:
	row.toughness_x100 = Fixed.from_typed(typed)
	return row


# --- Event-only items (spec 2.6: no Pool tag, so no pool offers them and they are not cards) ----------------------------

func _event_item(name: String, title: String, tag: StringName, grants: AbilitySet, description: String) -> void:
	_item(name, title, [tag], 0, grants, {"description": description})


func _set_of(abilities: Array, effects: Array, tags: Array = []) -> AbilitySet:
	var ability_set := AbilitySet.new()
	ability_set.abilities.assign(abilities)
	ability_set.effects.assign(effects)
	ability_set.tags.assign(tags)
	return ability_set


func _event_items() -> void:
	_event_item("vampire_curse", "Curse of the Vampire", CURSE, _set_of([_r["abilities/events/blood_drain"],
		_r["abilities/vampire_fang"]], [_r["effects/events/vampire_curse"]]),
		"Learn Blood Drain; every hit you deal heals you. -15% max HP.")
	_event_item("leech", "Leech", CURSE, _set_of([], [_r["effects/events/leech_bond"]]),
		"A fat leech feeds and gives back: +12% ATK, -10% DEF.")
	_event_item("smiths_brand", "Smith's Brand", BOON, _set_of([_r["abilities/events/molten_strike"]], [],
		[&"Weakness.Ice"]), "Learn Molten Strike. The brand never cools: weak to Ice.")
	_event_item("void_mark", "Void Mark", CURSE, _set_of([_r["abilities/events/unravel"]], [_r["effects/events/void_mark"]]),
		"Learn Unravel. Something is missing: -10% max SP.")


# --- Event-only encounters (spec 2.4: Encounter.Event, no Chapter tag; party_grants) -----------------------------------

## slot specs: [enemy name, level bonus]. extras: "grants" / "party_grants": effect names; "rewards": outcomes.
func _event_encounter(name: String, title: String, slot_specs: Array, extras: Dictionary = {}) -> void:
	var encounter := EncounterDefinition.new()
	encounter.id = StringName("demo.encounter." + name)
	encounter.display_name = title
	encounter.tags.assign([EVENT_ENCOUNTER])
	for spec in slot_specs:
		var slot := EncounterSlot.new()
		slot.enemy = _r["enemies/" + spec[0]]
		slot.level_bonus = spec[1]
		encounter.slots.append(slot)
	if extras.has("grants"):
		encounter.grants = _set_of([], extras["grants"].map(func(effect: String): return _r["effects/" + effect]))
	if extras.has("party_grants"):
		encounter.party_grants = _set_of([], extras["party_grants"].map(func(effect: String): return _r["effects/" + effect]))
	encounter.rewards.assign(extras.get("rewards", []))
	_save("encounters/events/" + name, encounter)


func _event_encounters() -> void:
	var reflection := (_r["enemies/hollow_echo"] as EnemyDefinition).duplicate(true) as EnemyDefinition
	reflection.id = &"demo.enemy.reflection"
	reflection.display_name = "Your Reflection"
	reflection.mirror_party_items = true
	var skip: Array[StringName] = [&"Item.Food", CURSE]
	reflection.mirror_skip_tags = skip
	_save("enemies/reflection", reflection)
	var boss_item := _give_pool(&"Pool.Boss", GiveItem.Recipient.FIRST)
	_event_encounter("event_ambush", "Ambush", [["knight", 0], ["bat", 0], ["bat", 0]],
		{"grants": ["haste"], "party_grants": ["slow"], "rewards": [_coins(25), _give_pool(&"Pool.Treasure", GiveItem.Recipient.FIRST)]})
	_event_encounter("event_ambush_spotted", "Ambush (spotted)", [["knight", 0], ["bat", 0], ["bat", 0]],
		{"grants": ["slow"], "party_grants": ["haste"], "rewards": [_coins(25), _give_pool(&"Pool.Treasure", GiveItem.Recipient.FIRST)]})
	_event_encounter("event_sparring", "Sparring Ring", [["knight", 0]], {"rewards": [_xp(100)]})
	_event_encounter("event_watchman", "Drunk Watchman", [["knight", 1]], {"rewards": [_keys(2)]})
	_event_encounter("event_vampire", "Vampire's Crypt", [["bat", 1], ["bat", 1], ["bat", 1]],
		{"grants": ["haste"], "rewards": [_give_pool(&"Pool.Treasure", GiveItem.Recipient.FIRST, &"Item.Rarity.Rare")]})
	_event_encounter("event_furnace", "Runaway Furnace", [["smelter", 1], ["anvil_guard", 1], ["cinder_hound", 0]],
		{"party_grants": ["burn"], "rewards": [_keys(3)]})
	_event_encounter("event_beast", "Slumbering Beast", [["gutter_maw", 3], ["vein_weaver", 2], ["leech", 2]],
		{"grants": ["weaken"], "rewards": [boss_item, _coins(30)]})
	_event_encounter("event_beast_awake", "Slumbering Beast (awake)", [["gutter_maw", 3], ["vein_weaver", 2], ["leech", 2]],
		{"party_grants": ["slow"], "rewards": [boss_item, _coins(30)]})
	_event_encounter("event_paladin", "Fallen Paladin", [["glass_saint", 2], ["penitent_knight", 2]],
		{"party_grants": ["ward"], "rewards": [boss_item]})
	_event_encounter("event_paladin_warrior", "Fallen Paladin (shield to shield)", [["glass_saint", 2], ["penitent_knight", 2]],
		{"party_grants": ["ward", "haste"], "rewards": [boss_item]})
	_event_encounter("event_tax", "Tax Collector", [["tally_clerk", 1], ["tally_clerk", 1], ["tally_clerk", 1]],
		{"rewards": [_coins(50)]})
	_event_encounter("event_hag", "Hag's Bargain", [["hag_sister", 2], ["coven_familiar", 1], ["coven_familiar", 1]],
		{"party_grants": ["weaken"], "rewards": [boss_item]})
	_r["enemies/reflection"] = load(CONTENT + "enemies/reflection.tres")
	_event_encounter("event_reflection", "Your Reflection", [["reflection", 2]], {"rewards": [boss_item]})
	_event_encounter("event_reflection_broken", "Your Reflection (broken)", [["reflection", 2]],
		{"grants": ["weaken"], "rewards": [boss_item]})


# --- Outcomes and conditions --------------------------------------------------------------------------------------------

func _effect(name: String) -> GameplayEffect:
	if not _r.has("effects/events/" + name):
		_r["effects/events/" + name] = load(CONTENT + "effects/events/%s.tres" % name)
	return _r["effects/events/" + name]


func _member(effect: String, target: int, slot: int = 1, character: String = "") -> ApplyMemberEffect:
	var outcome := ApplyMemberEffect.new()
	outcome.effect = _effect(effect)
	outcome.target = target
	outcome.slot = slot
	outcome.character = _chars[character] if character != "" else null
	return outcome


func _party(effect: String) -> ApplyPartyEffect:
	var outcome := ApplyPartyEffect.new()
	outcome.effect = _effect(effect)
	return outcome


func _give_pool(pool: StringName, recipient: int = GiveItem.Recipient.CHOOSE, rarity: StringName = &"") -> GiveItem:
	var outcome := GiveItem.new()
	outcome.item_query = _query([pool, rarity] if rarity != &"" else [pool])
	outcome.recipient = recipient
	return outcome


func _give_item(item: String, recipient: int, slot: int = 1, character: String = "") -> GiveItem:
	var outcome := GiveItem.new()
	outcome.item = load(CONTENT + "items/%s.tres" % item)
	outcome.recipient = recipient
	outcome.slot = slot
	outcome.character = _chars[character] if character != "" else null
	return outcome


func _give_slot(pool: StringName, slot: int) -> GiveItem:
	var outcome := _give_pool(pool, GiveItem.Recipient.SLOT)
	outcome.slot = slot
	return outcome


func _give_to_character(pool: StringName, character: String) -> GiveItem:
	var outcome := _give_pool(pool, GiveItem.Recipient.FIRST)
	outcome.character = _chars[character]
	return outcome


func _armor_gift(on_floor: bool = false, only_slot: StringName = &"") -> GiveEquipment:
	var outcome := GiveEquipment.new()
	outcome.query = _query([&"Pool.Treasure"])
	outcome.prefer_open_slot = true
	outcome.on_floor = on_floor
	outcome.only_slot = only_slot
	return outcome


func _pay(amount: int) -> LoseCoins:
	var outcome := LoseCoins.new()
	outcome.amount = amount
	return outcome


func _keys(amount: int) -> GainKeys:
	var outcome := GainKeys.new()
	outcome.amount = amount
	return outcome


func _pay_keys(amount: int) -> LoseKeys:
	var outcome := LoseKeys.new()
	outcome.amount = amount
	return outcome


func _xp(amount: int) -> GainXp:
	var outcome := GainXp.new()
	outcome.amount = amount
	return outcome


func _levels(count: int) -> GainLevel:
	var outcome := GainLevel.new()
	outcome.count = count
	return outcome


func _reveal() -> RevealRooms:
	var outcome := RevealRooms.new()
	outcome.mode = RevealRooms.Mode.ALL
	return outcome


func _chest(name: String) -> GiveChest:
	var outcome := GiveChest.new()
	outcome.chest = _r["chests/" + name]
	return outcome


func _start(name: String) -> StartEncounter:
	var outcome := StartEncounter.new()
	var path := CONTENT + ("encounters/%s.tres" % name if name == "slime_pair" else "encounters/events/%s.tres" % name)
	outcome.encounter = load(path)
	return outcome


func _go(page: int) -> GoToPage:
	var outcome := GoToPage.new()
	outcome.page = page
	return outcome


## pages and weights as typed (1 = normal).
func _roll(pages: Array, weights: Array) -> GoToRandomPage:
	var outcome := GoToRandomPage.new()
	outcome.pages.assign(pages)
	var typed: Array[float] = []
	for weight in weights:
		typed.append(float(weight))
	outcome.weights = typed
	return outcome


func _remove(pool: StringName, from: int, slot: int = 1) -> RemoveItem:
	var outcome := RemoveItem.new()
	outcome.item_query = _query([pool])
	outcome.from = from
	outcome.slot = slot
	return outcome


func _coins_at(amount: int) -> CoinsAtLeast:
	var condition := CoinsAtLeast.new()
	condition.amount = amount
	return condition


func _keys_at(amount: int) -> KeysAtLeast:
	var condition := KeysAtLeast.new()
	condition.amount = amount
	return condition


func _member_at(slot: int) -> MemberAt:
	var condition := MemberAt.new()
	condition.slot = slot
	return condition


func _party_hp(percent: float) -> PartyHpAtLeast:
	var condition := PartyHpAtLeast.new()
	condition.percent = percent
	return condition


func _holds(tag: StringName, slot: int = 0) -> HoldsItemTag:
	var condition := HoldsItemTag.new()
	condition.query = _query([tag])
	condition.slot = slot
	return condition


func _has(names: Array) -> RunCondition:
	var conditions: Array = []
	for name in names:
		var has := HasCharacter.new()
		has.character = _chars[name]
		conditions.append(has)
	if conditions.size() == 1:
		return conditions[0]
	var any := AnyOf.new()
	any.conditions.assign(conditions)
	return any


# --- Events (event endings, user 2026-11-22: every choice ends on a page that tells what happened) ----------------------
#
# An event is its first page's text and a list of options. Each option becomes a first-page choice that leads to its
# own page(s):
#   _end(label, text, outcomes)       one ending page; `outcomes` run when it shows (EventPage.on_enter), then Continue
#   _fight(label, intro, encounter)   a page that sets the fight up, then "Fight!" starts it
#   _gamble(label, branches)          a random page per branch ([weight, text, outcomes]); optional `again` re-rolls
# `pre` outcomes run on the choice itself (a cost paid before the roll), `conditions` gate it, `classes` make it a
# class choice (WHEN_MET, Choice.Class, badged).

const CONTINUE := "Continue"
const FIGHT := "Fight!"


func _end(label: String, text: String, outcomes: Array = [], conditions: Array = [], classes: Array = [],
		pre: Array = []) -> Dictionary:
	return {"kind": "end", "label": label, "text": text, "outcomes": outcomes, "conditions": conditions,
		"classes": classes, "pre": pre}


func _fight(label: String, intro: String, encounter: String, conditions: Array = [], classes: Array = [],
		pre: Array = []) -> Dictionary:
	return {"kind": "fight", "label": label, "intro": intro, "encounter": encounter, "conditions": conditions,
		"classes": classes, "pre": pre}


## branches: [weight, text, outcomes] or [weight, "fight", intro, encounter name].
func _gamble(label: String, branches: Array, pre: Array = [], conditions: Array = [], classes: Array = [],
		again: String = "") -> Dictionary:
	return {"kind": "gamble", "label": label, "branches": branches, "conditions": conditions, "classes": classes,
		"pre": pre, "again": again}


func _continue_choice(label: String = CONTINUE) -> EventChoice:
	return _choice(label, [], [])


func _fight_choice(encounter: String) -> EventChoice:
	return _choice(FIGHT, [], [_start(encounter)])


## Appends `page` to `pages` and returns its index.
func _add_page(pages: Array, page: EventPage) -> int:
	pages.append(page)
	return pages.size() - 1


func _ending_page(text: String, outcomes: Array, choices: Array) -> EventPage:
	var page := _page(text, choices)
	var entered: Array[RunOutcome] = []
	entered.assign(outcomes)
	page.on_enter = entered
	return page


func _story(name: String, title: String, tag: StringName, text: String, options: Array) -> void:
	var pages: Array = [null]  # page 0 is filled in last, once its choices know their pages
	var first: Array = []
	for option in options:
		var leads: Array = []
		match str(option["kind"]):
			"end":
				var index := _add_page(pages, _ending_page(option["text"], option["outcomes"], [_continue_choice()]))
				leads = [_go(index)]
			"fight":
				if option["label"] == "Fight":
					# User, 2026-11-22: a plain "Fight" needs no second page; the first page already sets the scene, so
					# its button is "Fight!" and starts the fight at once (an action such as "Steal his keys" keeps its page).
					option = option.duplicate()
					option["label"] = FIGHT
					leads = [_start(option["encounter"])]
				else:
					var index := _add_page(pages, _page(option["intro"], [_fight_choice(option["encounter"])]))
					leads = [_go(index)]
			"gamble":
				var indices: Array = []
				var weights: Array = []
				for branch in option["branches"]:
					var page: EventPage
					if str(branch[1]) == "fight":
						page = _page(branch[2], [_fight_choice(branch[3])])
					else:
						page = _ending_page(branch[1], branch[2], [])
					indices.append(_add_page(pages, page))
					weights.append(branch[0])
				for index in indices:
					var page: EventPage = pages[index]
					if not page.choices.is_empty():
						continue  # a fight page has its own choice
					var choices: Array = []
					if option["again"] != "":
						choices.append(_choice(option["again"], option["conditions"],
							option["pre"] + [_roll(indices, weights)]))
					choices.append(_continue_choice())
					page.choices.assign(choices)
				leads = [_roll(indices, weights)]
		var choice := _choice(option["label"], [], option["pre"] + leads)
		var conditions: Array = option["conditions"].duplicate()
		if not option["classes"].is_empty():
			conditions.push_front(_has(option["classes"]))
			choice.show = EventChoice.Show.WHEN_MET
			choice.tags.append(CLASS_TAG)
		choice.conditions.assign(conditions)
		first.append(choice)
	pages[0] = _page(text, first)
	var event := EventDefinition.new()
	event.id = StringName("demo.event." + name)
	event.display_name = title
	event.tags.assign([tag])
	var built: Array[EventPage] = []
	built.assign(pages)
	event.pages = built
	_tag_choices(event)
	_save_event(name, event)


## Writes events/<name>.tres; with --replace-own also over a file this builder made before (spec event-pass endings,
## the user's one-off OK 2026-11-22: only the builder's own event files, which nobody else edits).
func _save_event(name: String, event: EventDefinition) -> void:
	var path := CONTENT + "events/%s.tres" % name
	if _replace_own and FileAccess.file_exists(path):
		_write(path, event)
		_r["events/" + name] = load(path)
		return
	_save("events/" + name, event)


## Every choice gets the Choice.* tags its outcomes call for, one page deep (the page's own on_enter and its choices, what
## the validator checks), plus a fight's rewards and Leave for a choice that changes nothing. Choice.Class stays.
func _tag_choices(event: EventDefinition) -> void:
	for page in event.pages:
		for choice in page.choices:
			var tags: Array[StringName] = []
			for tag in choice.tags:
				tags.append(tag)
			var outcomes: Array = choice.outcomes.duplicate()
			for outcome in choice.outcomes:
				var pages: Array = [outcome.page] if outcome is GoToPage else (outcome.pages if outcome is GoToRandomPage else [])
				for index in pages:
					if index >= 0 and index < event.pages.size():
						outcomes.append_array(event.pages[index].on_enter)
						for next in event.pages[index].choices:
							if next != choice:
								outcomes.append_array(next.outcomes)
			var with_rewards: Array = outcomes.duplicate()
			for outcome in outcomes:
				if outcome is StartEncounter and outcome.encounter != null:
					with_rewards.append_array(outcome.encounter.rewards)
			for outcome in with_rewards:
				for tag in ContentValidator.choice_tags_for(outcome):
					if not tags.has(tag):
						tags.append(tag)
			if tags.filter(func(tag: StringName) -> bool: return tag != CLASS_TAG).is_empty():
				tags.append(LEAVE_TAG)
			choice.tags = tags


func _general_events() -> void:
	var M := ApplyMemberEffect.Target
	var R := GiveItem.Recipient
	_story("gambler", "Gambler's Table", GENERAL,
		"A grinning gambler shuffles a greasy deck. \"Fifteen coins. Double or nothing, near enough.\"", [
		_gamble("Bet 15 coins", [
			[1, "The card turns: the queen of skulls. You win! The gambler shoves the coins across, smile gone.", [_coins(35)]],
			[1, "The card turns: the two of rags. The gambler sweeps up your coins with a wink.", []]],
			[_pay(15)], [_coins_at(15)]),
		_end("Charm the dealer", "The Bard plays three bars of a tavern song the gambler's mother used to sing. Misty-eyed, he pays out without dealing a card.",
			[_coins(35)], [], ["bard"]),
		_end("Leave", "\"Cowards never win,\" the gambler calls after you. Cowards never lose either.")])
	_story("wishing_well", "Wishing Well", GENERAL, "A mossy well. Coins glint far below the dark water.", [
		_gamble("Throw in 5 coins", [
			[1, "The water churns, and something rises to the brim and settles at your feet.", [_give_pool(&"Pool.Treasure")]],
			[3, "The coin sinks out of sight. The well keeps its secrets.", []]],
			[_pay(5)], [_coins_at(5)], [], "Throw in another 5 coins"),
		_end("Freeze the water and climb down", "The Cryomancer turns the well to ice. The party climbs down the frozen column and pries a wish-worn treasure from the bottom.",
			[_give_pool(&"Pool.Treasure")], [], ["cryomancer"]),
		_end("Leave", "You keep your coins and your wishes to yourself.")])
	_story("blood_fountain", "Blood Fountain", GENERAL,
		"A fountain runs red. Those who drink are said to find what they seek.", [
		_end("{member:1} drinks", "{member:1} drinks deep. The blood burns all the way down, and something heavy settles into their pack.",
			[_member("hurt_30", M.SLOT, 1), _give_slot(&"Pool.Treasure", 1)], [_member_at(1)]),
		_end("Purify it", "The Cleric's prayer turns the blood to clear water. At the bottom of the basin lies an offering, free for the taking.",
			[_give_to_character(&"Pool.Treasure", "cleric")], [], ["cleric"]),
		_end("Leave", "The fountain gurgles behind you, disappointed.")])
	_story("weapon_rack", "Weapon Rack", GENERAL,
		"A rack of old arms leans against the wall, one good blade among the rust.", [
		_gamble("Take the good one", [
			[1, "As you pull the blade free the whole rack gives way and crashes onto {member:2}. At least the weapon is yours.",
				[_armor_gift(false, WEAPON), _member("hurt_25", M.SLOT, 2)]],
			[1, "The rack creaks but holds. You ease the blade out and step back carefully.", [_armor_gift(false, WEAPON)]]]),
		_end("Brace the rack and take it", "The Bulwark sets a shoulder against the rack while the others lift the weapon free. Nothing falls.",
			[_armor_gift(false, WEAPON)], [], ["bulwark"]),
		_end("Leave", "Old rust can bite. You leave the rack standing.")])
	_story("keyhole_wall", "Keyhole Wall", GENERAL, "A wall with a single keyhole. Something behind it rattles.", [
		_end("Use a key", "The key turns with a heavy clunk. A section of wall swings inward, and a chest slides out into the room.",
			[_chest("wooden_chest")], [], [], [_pay_keys(1)]),
		_end("Pick the lock", "The Ranger works the lock with a bent pin and a patient ear. Click. A chest slides out of the wall.",
			[_chest("wooden_chest")], [], ["ranger"]),
		_end("Leave", "Whatever rattles behind the wall can keep rattling.")])
	_story("idol_of_the_last", "Idol of the Last", GENERAL,
		"A stone idol with too many eyes. \"Give me the last of you,\" it whispers, \"and the rest grow strong.\"", [
		_end("Offer {member:4}", "{member:4} steps forward. The eyes close one by one, and {member:4} is gone. Power floods into the ones who remain.",
			[_member("slay", M.SLOT, 4), _levels(1)], [_member_at(4)]),
		_end("Melt the idol down", "The Ember Knight's flames turn the idol to slag. Its eyes were set with silver, which pools on the floor.",
			[_coins(40)], [], ["ember_knight"]),
		_end("Leave", "You back away. The eyes follow you all the way to the door.")])
	_story("ambush", "Ambush!", GENERAL, "Figures drop from the rafters. There is no way around them.", [
		_fight("Fight", "Blades flash in the dark and the ambushers close in from every side!", "event_ambush"),
		_fight("Spot them first", "The Ranger catches the glint of steel above and shouts a warning. The ambushers drop into a party that is ready for them!",
			"event_ambush_spotted", [], ["ranger"])])
	_story("sparring_ring", "Sparring Ring", GENERAL,
		"A chalk ring on the floor and a bored knight. \"One bout. Loser buys nothing, winner learns something.\"", [
		_fight("Spar", "The knight grins, rolls his shoulders and raises his blade. \"First to fall loses.\"", "event_sparring"),
		_end("Teach them a lesson", "The Warrior steps into the ring and disarms the knight in three moves. He laughs, bows, and spends an hour showing everyone his best tricks.",
			[_xp(100)], [], ["warrior"]),
		_end("Leave", "\"Another time, then,\" the knight shrugs, and goes back to being bored.")])
	_story("fortune_teller", "Fortune Teller", GENERAL,
		"A veiled woman taps a crystal ball. \"Ten coins for the floor. Twenty-five for the floor and a little more.\"", [
		_end("Pay 10 coins", "She peers into the glass and traces the floor's rooms in the air. The whole floor unfolds in your mind.",
			[_reveal()], [_coins_at(10)], [], [_pay(10)]),
		_end("Pay 25 coins", "She shows you the floor, then presses a golden key into your palm. \"You'll know the door.\"",
			[_reveal(), GiveGoldenKey.new()], [_coins_at(25)], [], [_pay(25)]),
		_end("Gaze through your own crystal", "The Shatterweaver holds up a shard of their own. The two crystals sing together, the floor shows itself, and the old woman hands over a golden key in awe.",
			[_reveal(), GiveGoldenKey.new()], [], ["shatterweaver"]),
		_end("Leave", "\"The future will find you anyway,\" she says to your back.")])
	_story("lost_satchel", "Lost Satchel", GENERAL, "A satchel lies under a bench. It moves, very slightly.", [
		_gamble("Open it", [
			[2, "Inside: food, still wrapped and still good.", [_give_pool(&"Pool.Food", R.LOWEST_HP)]],
			[2, "Inside: a handful of coins and a mouse, which flees.", [_coins(15)]],
			[1, "Inside: a snake! It bites before it slithers away.", [_member("hurt_20", M.RANDOM)]]]),
		_end("Check it for vermin first", "The Plaguewright shakes out a snake with practised hands and hands round what's left: food and coins.",
			[_give_pool(&"Pool.Food", R.LOWEST_HP), _coins(15)], [], ["plaguewright"]),
		_end("Leave", "Whatever is in the satchel stays in the satchel.")])


func _found_events() -> void:
	var R := GiveItem.Recipient
	_story("skeletons_keys", "Skeleton's Keys", GENERAL, "Two keys lie beside a skeleton.", [
		_end("Take them", "You ease the keys out of the bony fingers. The skeleton doesn't mind.", [_keys(2)]),
		_end("Leave", "Some things are better left with the dead.")])
	_story("golden_chest", "Golden Chest", GENERAL, "A gilded chest sits in the middle of the room.", [
		_end("Take a closer look", "Up close the chest is heavier than it looks and locked tight. It will need a key.",
			[_chest("gilded_chest")]),
		_end("Leave", "Too good to be true, probably. You leave it be.")])
	_story("wooden_chest", "Wooden Chest", GENERAL, "A plain wooden chest, unlocked.", [
		_end("Take a closer look", "Plain wood, plain hinges, no lock. You drag it into the light.", [_chest("wooden_chest")]),
		_end("Leave", "You leave the chest where it is.")])
	_story("abandoned_pack", "Abandoned Pack", GENERAL, "Someone left in a hurry.", [
		_end("Search it", "Under a torn cloak you find something worth keeping, and set it down to look at.",
			[_give_pool(&"Pool.Treasure", R.FLOOR)]),
		_end("Leave", "Whoever left it might come back for it.")])
	_story("armor_stand", "Armor Stand", GENERAL, "A dusty stand still holds its armor.", [
		_end("Take it down", "You lift the piece off its stand and blow away a cloud of dust. It's still sound.",
			[_armor_gift(true)]),
		_end("Leave", "The armor stays on its stand, watching the door.")])
	_story("picnic_remains", "Picnic Remains", GENERAL, "Not everything has gone bad.", [
		_end("Gather it up", "You pick through the crumbs and find something worth eating.",
			[_give_pool(&"Pool.Food", R.FLOOR)]),
		_end("Leave", "You're not that hungry.")])
	_story("coin_purse", "Coin Purse", GENERAL, "A torn purse, coins spilling out.", [
		_end("Pick them up", "You scoop up every coin, even the one that rolled under the door.", [_coins(25)]),
		_end("Leave", "Finders keepers, but not you.")])
	_story("scrawled_map", "Scrawled Map", GENERAL, "A map scratched into the wall.", [
		_end("Study it", "You trace the lines with a finger until the whole floor makes sense.", [_reveal()]),
		_end("Decipher the margins", "The Arcanist reads the tiny runes in the margin: a map of the floor, and directions to a hidden golden key.",
			[_reveal(), GiveGoldenKey.new()], [], ["arcanist"]),
		_end("Leave", "You trust your own sense of direction.")])


func _chapter_events() -> void:
	var M := ApplyMemberEffect.Target
	var R := GiveItem.Recipient
	var F := RemoveItem.From
	# The Cellar.
	_story("rat_nest", "Rat Nest", &"Event.Cellar", "A nest of rats squeaks over something shiny.", [
		_end("Reach in ({member:1})", "{member:1} plunges a hand into the nest. The rats bite, but the hand comes back full of coins.",
			[_member("hurt_15", M.SLOT, 1), _coins(20)], [_member_at(1)]),
		_end("Burn it", "A burst of flame and the rats scatter. The coins they were hoarding glow in the ashes.",
			[_coins(20)], [], ["pyromancer", "ember_knight"]),
		_end("Leave", "The rats can keep their treasure.")])
	_story("forgotten_pantry", "Forgotten Pantry", &"Event.Cellar", "Shelves of jars and sacks, most of them untouched.", [
		_end("Eat", "The party shares a cold meal from the shelves. The one who needed it most eats best.",
			[_give_pool(&"Pool.Food", R.LOWEST_HP)]),
		_gamble("Search deeper", [
			[1, "Behind the sacks, wrapped in oilcloth, is something worth having.", [_give_pool(&"Pool.Treasure")]],
			[1, "fight", "Behind the sacks something wet stirs. The slime has found you first!", "slime_pair"]]),
		_end("Keep it fresh", "The Cryomancer chills the shelves. The food that was about to spoil keeps, and you set two meals aside.",
			[_give_pool(&"Pool.Food", R.FLOOR), _give_pool(&"Pool.Food", R.FLOOR)], [], ["cryomancer"]),
		_end("Leave", "You leave the jars to their dust.")])
	_story("drunk_watchman", "Drunk Watchman", &"Event.Cellar", "A watchman snores on a barrel, a ring of keys on his belt.", [
		_end("Bribe him (10 coins)", "You nudge him awake and press ten coins into his hand. He bites one, grunts, and tosses you a key before nodding off again.",
			[_keys(1)], [_coins_at(10)], [], [_pay(10)]),
		_fight("Steal his keys", "Your hand closes on the ring, and his eyes snap open. He lurches up, red-faced, and raises his fists!",
			"event_watchman"),
		_end("Drink with him", "The Bard matches the watchman drink for drink and starts a song. By the third verse he is snoring again, and the party lifts the key ring from his belt.",
			[_keys(2)], [], ["bard"]),
		_end("Leave", "You tiptoe past. He mumbles something about his mother and keeps snoring.")])
	# The Crypt.
	_story("open_grave", "Open Grave", &"Event.Crypt", "A grave lies open. Something glints in the dirt.", [
		_end("{member:2} digs", "{member:2} digs until their hands bleed and pulls a piece of old armor from the dirt.",
			[_member("hurt_20", M.SLOT, 2), _armor_gift()], [_member_at(2)]),
		_end("Dig it out yourself", "The Warrior digs like a soldier, steady and without complaint, and hauls out a piece of armor with only a few scrapes.",
			[_member("hurt_10", M.CHARACTER, 1, "warrior"), _armor_gift()], [], ["warrior"]),
		_end("Leave", "Let the dead keep what they were buried with.")])
	_story("bone_dice", "Bone Dice", &"Event.Crypt", "Dice carved from finger bones sit on a slab. \"Roll,\" the slab seems to say.", [
		_gamble("Roll", [
			[1, "Sixes! Warmth spreads through the party, as if the dead were pleased.", [_party("heal_30")]],
			[1, "Ones. A chill goes through your bones, and the slab seems to laugh.", [_party("hurt_15")]]]),
		_end("Bless the dice", "The Cleric blesses the bones before they roll. They come up sixes, every one, and warmth fills the room.",
			[_party("heal_30")], [], ["cleric"]),
		_end("Leave", "You leave the dice unrolled. The slab seems disappointed.")])
	_story("vampires_crypt", "Vampire's Crypt", &"Event.Crypt", "A coffin, its lid ajar. Something inside is breathing.", [
		_fight("Stake it", "You heave the lid aside. A swarm of bats bursts from the coffin, shrieking!", "event_vampire"),
		_end("Let it bite {member:1}", "A pale hand pulls {member:1} close. The bite is cold, and when it's over {member:1} feels both weaker and hungrier than ever.",
			[_give_item("vampire_curse", R.SLOT, 1)], [_member_at(1)]),
		_end("Stake it in its sleep", "The Ranger slips the stake in before the thing can wake. In the coffin lies its hoard.",
			[_give_pool(&"Pool.Treasure", R.CHOOSE, &"Item.Rarity.Rare")], [], ["ranger"]),
		_end("Leave", "You ease the lid shut and walk away quietly.")])
	# The Ember Forge.
	_story("smiths_brand", "Smith's Brand", &"Event.Forge", "A brand glows in the coals, still hot after all these years.", [
		_end("{member:3} takes the brand", "{member:3} grips the brand. It sears the skin and leaves a mark that never cools, and a new way to strike.",
			[_give_item("smiths_brand", R.SLOT, 3)], [_member_at(3)]),
		_end("Take the brand yourself", "The Ember Knight takes the brand like an old friend. The fire knows its own.",
			[_give_item("smiths_brand", R.FIRST, 1, "ember_knight")], [], ["ember_knight"]),
		_end("Leave", "You leave the brand in the coals to cool for another hundred years.")])
	_story("slag_pit", "Slag Pit", &"Event.Forge", "A pit of cooling slag. Things thrown in come out... changed.", [
		_end("Throw in a treasure", "You toss a treasure into the slag. It sinks, bubbles, and something new rises from the glow.",
			[_remove(&"Pool.Treasure", F.RANDOM), _give_pool(&"Pool.Chest")], [_holds(&"Pool.Treasure")]),
		_end("Melt something out of the slag", "The Pyromancer heats the slag until it runs, and a forgotten treasure floats to the top.",
			[_give_pool(&"Pool.Chest")], [], ["pyromancer"]),
		_end("Leave", "The slag can keep its secrets.")])
	_story("runaway_furnace", "Runaway Furnace", &"Event.Forge", "A furnace roars out of control. Its keepers are not friendly.", [
		_fight("Shut it down", "You reach for the bellows. The keepers turn as one, molten tools in hand!", "event_furnace"),
		_end("Freeze the furnace", "The Cryomancer smothers the fire in frost. The keepers flee, dropping their keys.",
			[_keys(3)], [], ["cryomancer"]),
		_end("Run", "You run, but the heat follows you out and scorches everyone on the way.", [_party("hurt_10")])])
	# The Hollow.
	_story("heart_altar", "Heart Altar", &"Event.Hollow", "A heart beats on an altar of bone. It wants blood.", [
		_end("Offer blood", "The party bleeds into the altar's grooves. The heart beats faster and offers up something precious.",
			[_party("hurt_25"), _give_pool(&"Pool.Boss")], [_party_hp(40)]),
		_end("Feed it poison instead", "The Plaguewright's poison makes the heart seize. It coughs up its treasure and goes still.",
			[_party("hurt_10"), _give_pool(&"Pool.Boss")], [], ["plaguewright"]),
		_end("Leave", "The heart beats on, hungry, as you leave.")])
	_story("leech_pool", "Leech Pool", &"Event.Hollow", "A warm pool, thick with leeches. The water heals, they say.", [
		_end("{member:4} bathes", "The water heals the party's wounds, but when {member:4} climbs out a fat leech stays behind, and it won't let go.",
			[_give_item("leech", R.SLOT, 4), _party("heal_20")], [_member_at(4)]),
		_end("Wade in armoured", "The Bulwark wades in plated to the neck. The leeches find nothing to bite, and the water does its work.",
			[_party("heal_20")], [], ["bulwark"]),
		_end("Leave", "You leave the leeches to their pool.")])
	_story("slumbering_beast", "Slumbering Beast", &"Event.Hollow",
		"Something huge sleeps across the passage, a glint of treasure under its claws.", [
		_fight("Wake it", "You hit it with everything you have. It wakes, still groggy, and roars!", "event_beast"),
		_gamble("Sneak past", [
			[3, "You slip past and pry something from under a claw. The beast sleeps on.", [_give_pool(&"Pool.Treasure")]],
			[2, "fight", "A pebble rolls. An eye the size of a shield opens, and the beast rises, wide awake!", "event_beast_awake"]]),
		_end("Smoke it out", "The Ember Knight smokes the passage until the beast shuffles off, coughing. It leaves its treasure behind.",
			[_give_pool(&"Pool.Treasure")], [], ["ember_knight"]),
		_end("Leave", "You let sleeping beasts lie.")])
	# The Silent Cathedral.
	_story("confessional", "Confessional", &"Event.Cathedral", "A confessional booth. A voice behind the screen waits.", [
		_end("Donate 30 coins", "The coins clink into the box. The voice blesses you, and the party feels stronger for it.",
			[_levels(1)], [_coins_at(30)], [], [_pay(30)]),
		_end("Confess", "You speak your curse aloud. The voice lifts it from you and sends you out whole.",
			[_remove(CURSE, F.ANY), _party("heal_full")], [_holds(CURSE)]),
		_end("Absolve", "The Cleric takes the other side of the screen. The curse leaves, the wounds close, and everyone walks out stronger.",
			[_remove(CURSE, F.ANY), _party("heal_full"), _levels(1)], [_holds(CURSE)], ["cleric"]),
		_end("Leave", "The voice says nothing as you go.")])
	_story("choir_loft", "Choir Loft", &"Event.Cathedral", "An empty choir loft. The hymn sheets are still on their stands.", [
		_end("Listen", "You sit in the silence. Faintly, a hymn plays from nowhere, and old aches ease.", [_party("heal_15")]),
		_end("Sing along", "The Bard picks up a sheet and sings. Ghostly voices join in, and the party learns more from one hymn than a year of fighting.",
			[_xp(100)], [], ["bard"]),
		_end("Leave", "You leave the loft to its silence.")])
	_story("fallen_paladin", "Fallen Paladin", &"Event.Cathedral",
		"A paladin kneels in a ruined chapel, armour cracked, eyes burning. \"Kneel, or fall.\"", [
		_fight("Fight", "\"So be it.\" The paladin rises, and a saint of glass rises with him!", "event_paladin"),
		_end("{member:1} kneels", "{member:1} kneels. The paladin's gauntlet comes down hard, then lifts, and leaves a gift in the kneeling hands.",
			[_member("hurt_40", M.SLOT, 1), _give_pool(&"Pool.Treasure", R.CHOOSE, &"Item.Rarity.Rare")], [_member_at(1)]),
		_fight("Fight shield to shield", "The Warrior answers the challenge with a shield raised high. The party falls in behind, ready and quick!",
			"event_paladin_warrior", [], ["warrior"]),
		_end("Leave", "The paladin watches you go, still kneeling, still burning.")])
	# The Vault.
	_story("tax_collector", "Tax Collector", &"Event.Vault", "A clerk blocks the door with a ledger. \"Twenty-five coins. Tax.\"", [
		_end("Pay 25 coins", "The clerk stamps the ledger and waves you through without looking up.", [], [_coins_at(25)], [],
			[_pay(25)]),
		_fight("Refuse", "The clerk slams the ledger shut. Two more clerks step out from behind him, sharpening their quills!", "event_tax"),
		_end("Forge a receipt (and a refund)", "The Arcanist conjures a receipt so convincing the clerk apologises for the error and pays you a refund.",
			[_coins(25)], [], ["arcanist"])])
	_story("golden_idol", "Golden Idol", &"Event.Vault", "A golden idol on a pressure plate. Obviously a trap. Obviously worth it.", [
		_gamble("Take it", [
			[1, "You snatch the idol. Darts hiss from the walls, and nobody gets out unscathed.", [_give_pool(&"Pool.Boss"), _party("hurt_30")]],
			[1, "You snatch the idol and freeze. Nothing happens. You can hardly believe it.", [_give_pool(&"Pool.Boss")]]]),
		_end("Swap it for a sandbag", "The Ranger weighs a sandbag by hand and swaps it for the idol in one smooth motion. The plate doesn't even click.",
			[_give_pool(&"Pool.Boss")], [], ["ranger"]),
		_end("Leave", "Obviously a trap. You leave it.")])
	_story("appraiser", "Appraiser", &"Event.Vault", "An appraiser peers through a loupe. \"I buy treasures. Fair prices.\"", [
		_end("Sell {member:1}'s treasure", "The appraiser turns {member:1}'s treasure over twice, sniffs, and counts out forty coins.",
			[_remove(&"Pool.Treasure", F.SLOT, 1), _coins(40)], [_holds(&"Pool.Treasure", 1)]),
		_end("Haggle", "The Bard talks the appraiser up, then up again, and walks away sixty coins richer.",
			[_remove(&"Pool.Treasure", F.SLOT, 1), _coins(60)], [_holds(&"Pool.Treasure", 1)], ["bard"]),
		_end("Leave", "\"My prices won't be this fair tomorrow,\" he calls after you.")])
	# The Black Coven.
	_story("witchs_brew", "Witch's Brew", &"Event.Coven", "A cauldron bubbles, unattended. It smells like a good idea.", [
		_gamble("{member:1} drinks", [
			[1, "Warmth. {member:1} feels wonderful, better than in weeks.", [_member("heal_full", M.SLOT, 1)]],
			[1, "{member:1} doubles over, green to the gills. That was not a good idea.", [_member("hurt_40", M.SLOT, 1)]]],
			[], [_member_at(1)]),
		_end("Drink it safely", "The Plaguewright sniffs, adds a pinch of something, and drinks. Every wound closes.",
			[_member("heal_full", M.CHARACTER, 1, "plaguewright")], [], ["plaguewright"]),
		_end("Leave", "You leave the cauldron to whoever brewed it.")])
	_story("blood_effigy", "Blood Effigy", &"Event.Coven",
		"A straw effigy that looks exactly like {member:4}. A candle burns beside it.", [
		_end("Burn it", "The straw catches. {member:4} screams and falls, and in the ashes lies something terribly valuable.",
			[_member("slay", M.SLOT, 4), _give_pool(&"Pool.Boss")], [_member_at(4)]),
		_end("Shatter the effigy", "The Shatterweaver cracks the effigy apart. The curse breaks with it, leaving behind a sliver of the Void.",
			[_give_pool(&"Pool.Void")], [], ["shatterweaver"]),
		_end("Leave", "You blow out the candle and leave the effigy alone.")])
	_story("hags_bargain", "Hag's Bargain", &"Event.Coven",
		"A hag grins over a table of trinkets. \"Two keys and it's yours. Or take it from me.\"", [
		_fight("Fight", "\"Take it, then!\" The hag cackles, and her familiars hiss from the shadows!", "event_hag"),
		_end("Pay 2 keys", "The hag snatches the keys and pushes a trinket across. It hums with the Void.",
			[_give_pool(&"Pool.Void")], [_keys_at(2)], [], [_pay_keys(2)]),
		_end("Out-hex the hag", "The Arcanist answers her hex with a better one. The hag pays up to make it stop.",
			[_give_pool(&"Pool.Void")], [], ["arcanist"]),
		_end("Leave", "Her laughter follows you down the hall.")])
	# The Void.
	_story("your_reflection", "Your Reflection", &"Event.Void",
		"A mirror of black glass. Your party looks back, holding everything you hold.", [
		_fight("Face it", "The reflection smiles your smile and steps out of the glass!", "event_reflection"),
		_fight("Break the mirror first", "The Shatterweaver cracks the glass before it can wake. The reflection stumbles out, broken and slow!",
			"event_reflection_broken", [], ["shatterweaver"]),
		_end("Leave", "You turn away. In the glass, your reflection doesn't.")])
	_story("void_rift", "Void Rift", &"Event.Void", "A tear in the air. Through it, the whole floor, from above.", [
		_end("{member:1} steps in", "{member:1} steps through and comes back pale and shaking, but now you know the whole floor and hold a golden key.",
			[_member("hurt_25", M.SLOT, 1), _reveal(), GiveGoldenKey.new()], [_member_at(1)]),
		_end("Freeze the rift's edge", "The Cryomancer freezes the rift open. Everyone takes a careful look, and a golden key drifts out.",
			[_reveal(), GiveGoldenKey.new()], [], ["cryomancer"]),
		_end("Leave", "The rift closes behind you with a sound like a sigh.")])
	_story("nameless_gift", "Nameless Gift", &"Event.Void",
		"A voice with no mouth offers {member:3} a mark. \"Two keys, and a little of yourself.\"", [
		_end("Accept", "The keys vanish. The mark settles on {member:3}'s skin, cold and quiet, and something is missing.",
			[_give_item("void_mark", R.SLOT, 3)], [_member_at(3), _keys_at(2)], [], [_pay_keys(2)]),
		_end("Take the mark yourself", "The Bulwark takes the mark instead, and the voice is too surprised to ask for the keys.",
			[_give_item("void_mark", R.FIRST, 1, "bulwark")], [], ["bulwark"]),
		_end("Leave", "\"Another time,\" says the voice, from everywhere.")])
