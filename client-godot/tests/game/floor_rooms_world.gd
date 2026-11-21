## Spec floor-rooms 8.1: the floor-rooms fixture run, built in memory over the fixtures like KeysWorld (files on disk would
## join chapter A's room queries and move every fixture golden). Chapter A's rooms plus a challenge room (three waves: a
## fixed looter pack that drops an item every time and grants 50 coins as its encounter reward, then two picks from
## chapter A's encounters) and an armory (crate gear only), on bigger rules that also lock the armory like the shop and the
## item room (keys from every cleared battle room). The item room's pedestal offers items only.
class_name FloorRoomsWorld
extends RefCounted

const RUN_ID: StringName = &"fixture.run.floor_rooms"
const CHALLENGE_TAG: StringName = &"Room.Type.Challenge"
const ARMORY_TAG: StringName = &"Room.Type.Armory"
const TREASURE_TAG: StringName = &"Fixture.Room.Type.Treasure"
const SHOP_TAG: StringName = &"Fixture.Room.Type.Shop"
const REWARD_COINS: int = 50


## The fixtures plus the floor-rooms run; `tweak(parts)` may change the parts ({"rules", "challenge", "armory", "vault",
## "run", "looter", "loot_pack"}, and may add more) before they are indexed.
static func content(tweak: Callable = Callable()) -> ContentIndex:
	var base := TestCase.fixtures()
	var parts := build(base)
	if tweak.is_valid():
		tweak.call(parts)
	return base.overlay(parts.values())  # a tweak may add more parts (a replaced encounter or room)


static func build(base: ContentIndex) -> Dictionary:
	var chapter_tag := &"Fixture.Chapter.A"
	# An enemy that always drops, in an encounter whose reward is 50 coins: a challenge room must give neither.
	var looter: EnemyDefinition = base.units[&"fixture.enemy.grunt"].duplicate()
	looter.id = &"fixture.enemy.looter"
	looter.drop_item = base.items[&"fixture.item.whetstone"]
	looter.drop_chance_x100 = 10000
	var loot_pack := EncounterDefinition.new()
	loot_pack.id = &"fixture.encounter.loot_pack"
	loot_pack.display_name = "Loot pack"
	var slot := EncounterSlot.new()
	slot.enemy = looter
	var slots: Array[EncounterSlot] = [slot]
	loot_pack.slots = slots
	var coins := GainCoins.new()
	coins.amount = REWARD_COINS
	var rewards: Array[RunOutcome] = [coins]
	loot_pack.rewards = rewards

	var challenge := RoomDefinition.new()
	challenge.id = &"fixture.room.challenge"
	challenge.display_name = "Challenge"
	challenge.tags.assign([CHALLENGE_TAG, chapter_tag])
	challenge.doors = 15
	challenge.content_mode = RoomDefinition.ContentMode.WAVES
	var first := RoomWave.new()
	first.encounter = loot_pack
	var waves: Array[RoomWave] = [first, RoomWave.new(), RoomWave.new()]
	challenge.waves = waves
	var reward := _placement(Vector2i(6, 1), RoomPlacement.Kind.ITEM_PEDESTAL)
	reward.item_query = _query(&"Fixture.Pool.Treasure")
	challenge.placements.assign([_placement(Vector2i(3, 3), RoomPlacement.Kind.PLAYER_SPAWN),
		_placement(Vector2i(9, 3), RoomPlacement.Kind.ENEMY_SPAWN), reward])

	var armory := RoomDefinition.new()
	armory.id = &"fixture.room.armory_gear"
	armory.display_name = "Armory"
	armory.tags.assign([ARMORY_TAG, chapter_tag])
	armory.doors = 15
	var gear := _placement(Vector2i(6, 3), RoomPlacement.Kind.ITEM_PEDESTAL)
	gear.item_query = _query(&"Fixture.Pool.Crate")
	gear.offers = RoomPlacement.Offers.EQUIPMENT
	armory.placements.assign([gear])

	# Chapter A's item room, offering items only (spec floor-rooms D5).
	var vault: RoomDefinition = base.rooms[&"fixture.room.vault"].duplicate(true)
	vault.placements[0].offers = RoomPlacement.Offers.ITEMS

	var rules: FloorGenRules = base.floor_rules[&"fixture.rules.small"].duplicate()
	rules.id = &"fixture.rules.floor_rooms"
	rules.base_rooms = 9
	rules.max_rooms = 14
	var special: Array[StringName] = [TREASURE_TAG, SHOP_TAG, ARMORY_TAG, CHALLENGE_TAG]
	rules.special_room_tags = special
	var locked: Array[StringName] = [TREASURE_TAG, SHOP_TAG, ARMORY_TAG]
	rules.locked_room_tags = locked
	var chapter: ChapterDefinition = base.chapters[&"fixture.chapter.a"].duplicate()
	chapter.id = &"fixture.chapter.floor_rooms"
	chapter.floor_gen_rules = rules
	var run: RunStructure = base.runs[&"fixture.run.two_floors"].duplicate()
	run.id = RUN_ID
	var floors: Array[FloorSlot] = []
	for index in 2:
		var floor_slot := FloorSlot.new()
		floor_slot.chapters.assign([chapter])
		floors.append(floor_slot)
	run.floors = floors
	run.key_drop_chance_x100 = 10000  # a key from every cleared battle room, so the locks are on and countable
	run.golden_key_chance_x100 = 0
	run.xp_per_enemy = 10  # XP is counted, so a test can see when it arrives (levels far away)
	run.xp_per_boss = 30
	var levels: Array[int] = [100000]
	run.xp_to_level = levels
	return {"looter": looter, "loot_pack": loot_pack, "challenge": challenge, "armory": armory, "vault": vault,
		"rules": rules, "chapter": chapter, "run": run}


## A floor-rooms run started under `host` (knight, medic, rogue), or another party.
static func start(host: Node, seed_text: String = "7", tweak: Callable = Callable(),
		party: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]) -> RunController:
	var run := RunController.new()
	host.add_child(run)
	var error := run.start_run(content(tweak), party, seed_text, RUN_ID)
	if error != "":
		push_error("FloorRoomsWorld.start: " + error)
	return run


## The first cell with this special tag on the floor, or -1.
static func special(run: RunController, tag: StringName) -> int:
	for index in run.state.map.sorted_indices():
		if run.state.map.cells[index]["special_tag"] == tag:
			return index
	return -1


static func _placement(cell: Vector2i, kind: RoomPlacement.Kind) -> RoomPlacement:
	var placement := RoomPlacement.new()
	placement.cell = cell
	placement.kind = kind
	placement.slot = 1
	return placement


static func _query(tag: StringName) -> GameplayTagQuery:
	var query := GameplayTagQuery.new()
	query.require_all_tags.assign([tag])
	return query
