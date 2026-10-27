## Spec keys-and-gear 6: the keyed fixture run, built in memory over the fixtures (a second RunStructure on disk would
## put a "run" field in every fixture run's log). Chapter A's rooms with treasure rooms and shops locked from floor 1,
## a key and a chest on every room cleared after a battle (crate or strongbox), no golden keys unless a test sets them.
class_name KeysWorld
extends RefCounted

const RUN_ID: StringName = &"fixture.run.keyed"


## The fixtures plus the keyed run; `tweak(run_structure)` may change the run before it is indexed.
static func content(tweak: Callable = Callable()) -> ContentIndex:
	var base := TestCase.fixtures()
	var rules: FloorGenRules = base.floor_rules[&"fixture.rules.small"].duplicate()
	rules.id = &"fixture.rules.locked"
	var locked: Array[StringName] = [&"Fixture.Room.Type.Treasure", &"Fixture.Room.Type.Shop"]
	rules.locked_room_tags = locked  # a new array: duplicate() shares the original's
	var chapter: ChapterDefinition = base.chapters[&"fixture.chapter.a"].duplicate()
	chapter.id = &"fixture.chapter.keyed"
	chapter.floor_gen_rules = rules
	var run: RunStructure = base.runs[&"fixture.run.two_floors"].duplicate()
	run.id = RUN_ID
	var floors: Array[FloorSlot] = []
	for index in 2:
		var slot := FloorSlot.new()
		slot.chapters.assign([chapter])
		floors.append(slot)
	run.floors = floors
	run.key_drop_chance_x100 = 10000
	run.golden_key_chance_x100 = 0
	run.chest_drop_chance_x100 = 10000
	var crate := ChestDrop.new()
	crate.chest = base.chests[&"fixture.chest.crate"]
	var strongbox := ChestDrop.new()
	strongbox.chest = base.chests[&"fixture.chest.strongbox"]
	var drops: Array[ChestDrop] = [crate, strongbox]
	run.chest_drops = drops
	if tweak.is_valid():
		tweak.call(run)
	return base.overlay([rules, chapter, run])


## A keyed run started under `host` (knight, medic, rogue).
static func start(host: Node, seed_text: String = "7", tweak: Callable = Callable(),
		party: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]) -> RunController:
	var run := RunController.new()
	host.add_child(run)
	var error := run.start_run(content(tweak), party, seed_text, RUN_ID)
	if error != "":
		push_error("KeysWorld.start: " + error)
	return run


## The first special room with this tag on the floor, or -1.
static func special(run: RunController, tag: StringName) -> int:
	for index in run.state.map.sorted_indices():
		if run.state.map.cells[index]["special_tag"] == tag:
			return index
	return -1


## A normal room of the floor (not the start), or -1.
static func normal(run: RunController) -> int:
	for index in run.state.map.sorted_indices():
		if run.state.map.cells[index]["role"] == FloorMap.ROLE_NORMAL:
			return index
	return -1
