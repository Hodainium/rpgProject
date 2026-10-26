## One-time builder for the playable demo's run (spec playable-demo 3.3): The Crypt (chapter, floor rules, the Lich's
## sanctum, four encounters), three events for both floors, and the two-floor run "The Descent", written into
## res://content/demo/ through ResourceSaver like build_content_pass.
##
## Same rules as build_demo, whose helpers it reuses: it never overwrites (an existing file is skipped and used), it
## writes nowhere but content/demo/, and it never touches an existing file. The retags of existing files (the Golem,
## the Lich, the Golem's den, the Cellar's queries) are made by hand with your approval (spec 3.4), not here.
## Values are starting values, typed as a designer would; tune them in the files.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_demo_run.tscn
extends "res://game/tools/build_content_pass.gd"

const CRYPT := &"Chapter.Crypt"


func _ready() -> void:
	if not ResourceLoader.exists(GENERATED_SET) or load(PERCENT_OF_MAX) == null:
		_quit("Needs %s and %s (run --import once first)." % [GENERATED_SET, PERCENT_OF_MAX])
		return
	_attributes = load(ATTRIBUTES)
	for key in ["rooms/boss", "floor_rules/small", "scaling/basic", "chapters/cellar", "enemies/knight", "enemies/shaman",
			"enemies/wisp", "enemies/imp", "enemies/toad", "variants/elite", "items/stale_bread", "items/scholars_tome",
			"items/hourglass", "equipment/warden_helm", "runs/one_floor", "effects/damage", "effects/entangle"]:
		_r[key] = load(CONTENT + key + ".tres")
		if _r[key] == null:
			_quit("Missing %s%s.tres" % [CONTENT, key])
			return
	_crypt()
	_events_for_both_floors()
	_descent()
	print("build_demo_run: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _made:
		print("  made    ", path)
	for path in _skipped:
		print("  skipped ", path)
	for path in _failed:
		print("  FAILED  ", path)
	get_tree().quit(1 if not _failed.is_empty() else 0)


# --- The Crypt (spec 3.3) ------------------------------------------------------------------------------------------------

func _crypt() -> void:
	var small: FloorGenRules = _r["floor_rules/small"]
	var rules: FloorGenRules = small.duplicate()
	rules.id = &"demo.rules.crypt"
	rules.base_rooms = 6       # one more room than the Cellar
	rules.max_rooms = 9
	_save("floor_rules/crypt", rules)
	# The Lich's sanctum: the Golem's den's placements, tagged for the Crypt.
	var sanctum: RoomDefinition = _r["rooms/boss"].duplicate(true)
	sanctum.id = &"demo.room.sanctum"
	sanctum.display_name = "Lich's sanctum"
	sanctum.tags.assign([&"Room.Type.Boss", CRYPT])
	_save("rooms/sanctum", sanctum)
	_encounter("crypt_guard", "Crypt guard", [CRYPT], [["knight", null], ["shaman", null]])
	_elite_encounter("ember_watch", "Ember watch", [CRYPT], [["imp", false], ["knight", true]])
	# Spec 3.7 (amendment C2): encounter grants, a slot brain, victory rewards.
	var choir := _built_encounter("wisp_choir", "Wisp choir", [CRYPT], [["wisp", false], ["wisp", false], ["wisp", false]])
	choir.grants = _granting_set([&"Drain.Ice"], [])  # the whole choir drains Ice
	_save("encounters/wisp_choir", choir)
	# Entangle Lash: the row delay (content-pass H6) on demo content, on Bound dead's first Toad through its slot.
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var snare := _chance(_row("snare", "entangle", D.USE_EFFECT, 0, T.ALL), 100)
	snare.delay_x100 = Fixed.from_typed(30)                       # the target's next turn 30% later
	_ability("entangle_lash", "Ability.Entanglelash", BattleAbility.Targeting.SINGLE_ENEMY,
		[_row("lash", "damage", D.SCALED, 60, T.ALL, [&"Damage.Type.Physical"]), snare], _jump(0.6),
		[[0.3, "lash"], [0.35, "snare"]], {"sound": ["Attack1", 0.2, -8.0]})
	var bound := _built_encounter("bound_dead", "Bound dead", [CRYPT], [["toad", false], ["shaman", false], ["toad", false]])
	bound.slots[0].grants = _granting_set([], [_r["abilities/entangle_lash"]])
	var lasher := PatternBrain.new()
	lasher.pattern.assign([&"Ability.Entanglelash", &"Ability.Spit"])
	bound.slots[0].brain = lasher
	_save("encounters/bound_dead", bound)
	# The wounded knight's challenge: an elite Knight alone, in no pool (no Chapter tag); beating him drops his helm.
	var duel := _built_encounter("knight_duel", "Wounded knight", [], [["knight", true]])
	var helm := GiveEquipment.new()
	helm.equipment = _r["equipment/warden_helm"]
	duel.rewards.assign([helm])
	_save("encounters/knight_duel", duel)
	var chapter := ChapterDefinition.new()
	chapter.id = &"demo.chapter.crypt"
	chapter.display_name = "The Crypt"
	chapter.tags.assign([CRYPT])
	var rooms := GameplayTagQuery.new()
	rooms.require_any_tags.assign([&"Chapter.Demo", CRYPT])  # the shared demo rooms plus the sanctum
	chapter.room_query = rooms
	chapter.encounter_query = _query([CRYPT], [&"Encounter.Boss"])
	chapter.boss_encounter_query = _query([&"Encounter.Boss", CRYPT])
	chapter.event_query = _query([&"Event.Demo"])
	chapter.floor_gen_rules = _r["floor_rules/crypt"]
	chapter.scaling = _r["scaling/basic"]  # its depth-2 effect applies on the second floor
	_save("chapters/crypt", chapter)


## Like _encounter, with [enemy name, elite?] slots (the elite variant on the flagged ones).
func _elite_encounter(name: String, title: String, tags: Array, slot_specs: Array) -> void:
	_save("encounters/" + name, _built_encounter(name, title, tags, slot_specs))


func _built_encounter(name: String, title: String, tags: Array, slot_specs: Array) -> EncounterDefinition:
	var encounter := EncounterDefinition.new()
	encounter.id = StringName("demo.encounter." + name)
	encounter.display_name = title
	encounter.tags.assign(tags)
	for spec in slot_specs:
		var slot := EncounterSlot.new()
		slot.enemy = _r["enemies/" + spec[0]]
		slot.variant = _r["variants/elite"] if spec[1] else null
		encounter.slots.append(slot)
	return encounter


func _granting_set(tags: Array, abilities: Array) -> AbilitySet:
	var ability_set := AbilitySet.new()
	ability_set.tags.assign(tags)
	ability_set.abilities.assign(abilities)
	return ability_set


# --- Events (spec 3.3; Event.Demo, so both floors draw them) -------------------------------------------------------------

func _events_for_both_floors() -> void:
	_save("effects/curse_wound", _percent_of_max(-20))  # 20% of max HP lost
	var treasure := GiveItem.new()
	treasure.item_query = _query([&"Pool.Treasure"])
	var wound := ApplyPartyEffect.new()
	wound.effect = _r["effects/curse_wound"]
	var chest := EventDefinition.new()
	chest.id = &"demo.event.cursed_chest"
	chest.display_name = "Cursed chest"
	chest.tags.assign([&"Event.Demo"])
	chest.pages.assign([_page("A chest bound in black chains. Something inside is worth having; the chains want blood.",
		[_choice("Open it (an item; everyone loses 20% max HP)", [], [treasure, wound]), _choice("Leave it", [], [])])])
	_save("events/cursed_chest", chest)

	var afford := CoinsAtLeast.new()
	afford.amount = 15
	var pay := LoseCoins.new()
	pay.amount = 15
	var helm := GiveEquipment.new()
	helm.equipment = _r["equipment/warden_helm"]
	var thanks := GoToPage.new()
	thanks.page = 1
	var duel := StartEncounter.new()
	duel.encounter = _r["encounters/knight_duel"]
	var knight := EventDefinition.new()
	knight.id = &"demo.event.wounded_knight"
	knight.display_name = "Wounded knight"
	knight.tags.assign([&"Event.Demo"])
	knight.pages.assign([
		_page("A wounded knight blocks the way. \"Fifteen coins for a healer, and my helm is yours.\"",
			[_choice("Pay 15 coins", [afford], [pay, helm, thanks]), _choice("Challenge him", [], [duel]),
			_choice("Walk past", [], [])]),
		_page("He presses the helm into your hands and limps away.", [_choice("Continue", [], [])]),
	])
	_save("events/wounded_knight", knight)

	var read := GoToPage.new()
	read.page = 1
	var tome := GiveItem.new()
	tome.item = _r["items/scholars_tome"]
	var hourglass := GiveItem.new()
	hourglass.item = _r["items/hourglass"]
	var librarian := EventDefinition.new()
	librarian.id = &"demo.event.librarian"
	librarian.display_name = "Librarian"
	librarian.tags.assign([&"Event.Demo"])
	librarian.pages.assign([
		_page("An old librarian looks up from a pile of books. \"Take one. Only one.\"",
			[_choice("Look at the books", [], [read]), _choice("Leave", [], [])]),
		_page("Two books are left on the desk.", [_choice("Take the Scholar's Tome", [], [tome]),
			_choice("Take the Hourglass", [], [hourglass])]),
	])
	_save("events/librarian", librarian)


# --- The run ---------------------------------------------------------------------------------------------------------------

func _descent() -> void:
	var one_floor: RunStructure = _r["runs/one_floor"]
	var run := RunStructure.new()
	run.id = &"demo.run.descent"
	run.display_name = "The Descent"
	run.default_run = true
	run.rarity_weights_x100 = {&"Item.Rarity.Common": 6000, &"Item.Rarity.Rare": 2500, &"Item.Rarity.Epic": 1200,
		&"Item.Rarity.Legendary": 300}
	run.fallback_item = _r["items/stale_bread"]
	run.equipment_slots.assign(one_floor.equipment_slots)
	var floors: Array[FloorSlot] = []
	for chapter in [_r["chapters/cellar"], _r["chapters/crypt"]]:
		var slot := FloorSlot.new()
		slot.chapters.assign([chapter])
		floors.append(slot)
	run.floors = floors
	_save("runs/descent", run)
