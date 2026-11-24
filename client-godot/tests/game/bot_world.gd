## Spec bot-play 6: the run bot's fixture world, built in memory over the fixtures like FloorRoomsWorld (files on disk would
## change the fixtures every golden reads). The knight is a Tank, the medic a Healer, the rogue a Damage dealer; fixture
## items and pieces carry Item.Fit.* tags (the whetstone Damage, the crest Survival, the banner Party, the lucky coin Run,
## the chaser charm FollowUp and Grants.FollowUp, the blade and dagger Damage, the cap, helm and mail Survival; the hood
## stays untagged). Run "fixture.run.bot": floor 1 on chapter A (an item room and a shop: FULL), floor 2 on a chapter whose
## rules place only a challenge room (BOSS). A test profile values the fixture room tags.
class_name BotWorld
extends RefCounted

const RUN_ID: StringName = &"fixture.run.bot"
const BOSS_RUN_ID: StringName = &"fixture.run.bot_boss_first"
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]
const KNIGHT: int = 1
const MEDIC: int = 2
const ROGUE: int = 3
const TREASURE_TAG: StringName = &"Fixture.Room.Type.Treasure"
const SHOP_TAG: StringName = &"Fixture.Room.Type.Shop"
const ROLES: Dictionary = {
	&"fixture.character.knight": [&"Unit.Role.Tank"],
	&"fixture.character.medic": [&"Unit.Role.Healer"],
	&"fixture.character.rogue": [&"Unit.Role.Damage"],
}
const FITS: Dictionary = {
	&"fixture.item.whetstone": [&"Item.Fit.Damage"],
	&"fixture.item.crest": [&"Item.Fit.Survival"],
	&"fixture.item.frostguard": [&"Item.Fit.Survival"],
	&"fixture.item.banner": [&"Item.Fit.Party"],
	&"fixture.item.lucky_coin": [&"Item.Fit.Run"],
	&"fixture.item.chaser_charm": [&"Item.Fit.FollowUp", &"Item.Grants.FollowUp"],
	&"fixture.item.flask": [&"Item.Fit.Party"],
	&"fixture.item.feather": [&"Item.Fit.Party"],
	&"fixture.equipment.blade": [&"Item.Fit.Damage"],
	&"fixture.equipment.dagger": [&"Item.Fit.Damage"],
	&"fixture.equipment.cap": [&"Item.Fit.Survival"],
	&"fixture.equipment.helm": [&"Item.Fit.Survival"],
	&"fixture.equipment.mail": [&"Item.Fit.Survival"],
}


## The fixtures plus the tagged copies and the bot runs.
static func content() -> ContentIndex:
	var base := TestCase.fixtures()
	var parts: Array = []
	for id in ROLES:
		var character: CharacterDefinition = base.units[id].duplicate()
		var tags: Array[StringName] = character.tags.duplicate()
		tags.append_array(ROLES[id])
		character.tags = tags
		parts.append(character)
	for id in FITS:
		var thing: Resource = (base.items[id] if base.items.has(id) else base.equipment[id]).duplicate()
		var tags: Array[StringName] = thing.tags.duplicate()
		tags.append_array(FITS[id])
		thing.tags = tags
		parts.append(thing)
	var room_parts := FloorRoomsWorld.build(base)
	parts.append_array([room_parts["challenge"], room_parts["loot_pack"], room_parts["looter"]])
	var rules: FloorGenRules = base.floor_rules[&"fixture.rules.small"].duplicate()
	rules.id = &"fixture.rules.bot_boss"
	var special: Array[StringName] = [FloorRoomsWorld.CHALLENGE_TAG]
	rules.special_room_tags = special
	var boss_chapter: ChapterDefinition = base.chapters[&"fixture.chapter.a"].duplicate()
	boss_chapter.id = &"fixture.chapter.bot_boss"
	boss_chapter.floor_gen_rules = rules
	parts.append_array([rules, boss_chapter])
	var loot_chapter: ChapterDefinition = base.chapters[&"fixture.chapter.a"]
	for pair in [[RUN_ID, [loot_chapter, boss_chapter]], [BOSS_RUN_ID, [boss_chapter, loot_chapter]]]:
		var run: RunStructure = base.runs[&"fixture.run.two_floors"].duplicate()
		run.id = pair[0]
		var floors: Array[FloorSlot] = []
		for chapter in pair[1]:
			var floor_slot := FloorSlot.new()
			floor_slot.chapters.assign([chapter])
			floors.append(floor_slot)
		run.floors = floors
		parts.append(run)
	return base.overlay(parts)


## A bot run started under `host`.
static func start(host: Node, seed_text: String = "5", run_id: StringName = RUN_ID, party: Array = PARTY) -> RunController:
	var run := RunController.new()
	host.add_child(run)
	var error := run.start_run(content(), party, seed_text, run_id)
	if error != "":
		push_error("BotWorld.start: " + error)
	return run


## The test profile: the default numbers, the fixture room tags valued like the demo's.
static func profile(base: String = "res://game/auto/profiles/spread.tres") -> BotProfile:
	var made: BotProfile = (load(base) as BotProfile).duplicate(true)
	made.room_values = {TREASURE_TAG: 100, SHOP_TAG: 60, FloorRoomsWorld.CHALLENGE_TAG: 20}
	return made


## A scoring context with fixed max HP (slot -> ×100), so a test does not depend on the fixtures' stats.
static func context(run: RunController, bot: BotProfile, max_hp: Dictionary = {}) -> Dictionary:
	var ctx := LootScorer.context(run, bot)
	if max_hp.is_empty():
		for member in run.state.party:
			max_hp[member["slot"]] = 100000
	ctx["max_hp"] = max_hp
	return ctx


## Takes every member's items, use items and worn pieces away (a clean party to place things on).
static func strip(run: RunController) -> void:
	for member in run.state.party:
		member["items"] = []
		member["use_slots"] = []
		member["equipment"] = {}
	run.state.armor.clear()


## A synthetic floor map for exploration tests (index = y × 9 + x on a 9×8 grid). `rooms`: index -> role (FloorMap.ROLE_*)
## or [role, content kind] or [role, content kind, special tag]; the first ROLE_START is the start and the current room,
## visited.
static func map(run: RunController, rooms: Dictionary) -> FloorMap:
	var floor_map := FloorMap.new(Vector2i(9, 8))
	for index in rooms:
		var spec: Variant = rooms[index]
		var role: String = spec[0] if spec is Array else spec
		var kind: String = spec[1] if spec is Array else ("battle" if role == FloorMap.ROLE_NORMAL else "")
		var tag: StringName = spec[2] if spec is Array and spec.size() > 2 else &""
		floor_map.cells[index] = {"visited": false, "cleared": false, "role": role, "special_tag": tag,
			"content": {"kind": kind}, "pickups": [], "doors": 0, "opened": false}
		if role == FloorMap.ROLE_START:
			floor_map.start = index
	floor_map.cells[floor_map.start]["visited"] = true
	floor_map.cells[floor_map.start]["cleared"] = true
	run.state.map = floor_map
	run.state.current_cell = floor_map.start
	return floor_map


## Marks rooms visited and cleared, and makes `current` the room the party is in.
static func visit(run: RunController, indices: Array, current: int) -> void:
	for index in indices:
		run.state.map.cells[index]["visited"] = true
		run.state.map.cells[index]["cleared"] = true
	run.state.current_cell = current
