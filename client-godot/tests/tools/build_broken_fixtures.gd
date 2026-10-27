## Builds the broken content root res://tests/broken_fixtures/ (spec dev-tools 6, "Fixtures"): one file per
## ContentValidator code, each named after it. A separate root, because ContentIndex scans tests/fixtures/ recursively.
## Reuses fixture abilities and the fixture attribute set; never references res://content/. Run once, then commit:
##   godot --headless --path client-godot --quit-after 600 res://tests/tools/build_broken_fixtures.tscn [-- --rebuild]
## Existing files are loaded, not rewritten (so adding a case keeps the others' uids); --rebuild rewrites everything.
extends Node

const ROOT := "res://tests/broken_fixtures/"
const FIXTURES := "res://tests/fixtures/"
const ATTRIBUTE_SET := preload("res://tests/fixtures/attributes/fixture_run_attribute_set.gd")
const DIRECTORIES: Array[String] = ["characters", "enemies", "encounters", "items", "events", "rooms", "chapters",
	"scaling", "floor_rules", "runs", "layouts", "equipment", "abilities"]

var _saved := {}
var _rebuild := false


func _ready() -> void:
	_rebuild = OS.get_cmdline_user_args().has("--rebuild")
	for directory in DIRECTORIES:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + directory))
	var strike: PackedScene = load(FIXTURES + "abilities/strike.tscn")
	var sweep: PackedScene = load(FIXTURES + "abilities/sweep.tscn")

	# Items: duplicate id (content_index), no id (missing_id), usable without an ability (bad_item), reserved tag,
	# and a valid fallback item for the run structure.
	_save("items", "content_index_a", _item("broken.item.dup", []))
	_save("items", "content_index_b", _item("broken.item.dup", []))
	_save("items", "missing_id", _item("", []))
	var usable := _item("broken.item.bad_item", [])
	usable.kind = ItemDefinition.Kind.USABLE
	_save("items", "bad_item", usable)
	_save("items", "reserved_tag", _item("broken.item.reserved_tag", [&"Dev.Kill"]))
	var fallback: ItemDefinition = _save("items", "fallback", _item("broken.item.fallback", []))

	# Units.
	var grunt := EnemyDefinition.new()
	_unit(grunt, "broken.enemy.grunt", [strike])
	grunt = _save("enemies", "grunt", grunt)
	var character := CharacterDefinition.new()
	_unit(character, "broken.character.bad_skill", [strike])
	character.default_loadout = Loadout.new()
	character.default_loadout.skills.append(sweep)  # not in its abilities or learnable_skills
	_save("characters", "bad_skill", character)

	# Encounters.
	var two := _encounter("broken.encounter.two_grunts", [grunt, grunt])
	two = _save("encounters", "two_grunts", two)
	_save("encounters", "dangling_ref", _encounter("broken.encounter.dangling_ref", [null]))
	var outside_loadout := _encounter("broken.encounter.bad_loadout_ref", [grunt])
	outside_loadout.slots[0].loadout = load(FIXTURES + "loadouts/tough.tres")  # a loadout file outside this root
	_save("encounters", "bad_loadout_ref", outside_loadout)
	_save("encounters", "incomplete", _encounter("broken.encounter.incomplete", []))

	# Rooms that break one rule each (tagged Broken.Room, so no chapter uses them).
	var P := RoomPlacement.Kind
	var unsatisfiable := _room("doors_unsatisfiable", [&"Broken.Room"], [])
	unsatisfiable.doors = RoomDefinition.DOOR_N
	unsatisfiable.min_doors = 3
	_save("rooms", "doors_unsatisfiable", unsatisfiable)
	_save("rooms", "placement_outside", _room("placement_outside", [&"Broken.Room"], [_placement(Vector2i(20, 3), P.PLAYER_SPAWN)]))
	_save("rooms", "placement_overlap", _room("placement_overlap", [&"Broken.Room"],
		[_placement(Vector2i(1, 1), P.PLAYER_SPAWN), _placement(Vector2i(1, 1), P.EVENT_PROP)]))
	var mismatch := _room("spawn_mismatch", [&"Broken.Room"],
		[_placement(Vector2i(1, 3), P.PLAYER_SPAWN), _placement(Vector2i(10, 3), P.ENEMY_SPAWN)])
	mismatch.content_mode = RoomDefinition.ContentMode.ENCOUNTER
	mismatch.encounter = two
	_save("rooms", "spawn_mismatch", mismatch)
	var priced := _placement(Vector2i(1, 3), P.PLAYER_SPAWN)
	priced.price = 5
	_save("rooms", "placement_kind", _room("placement_kind", [&"Broken.Room"], [priced]))
	var pedestal := _placement(Vector2i(6, 3), P.ITEM_PEDESTAL)
	pedestal.item_query = _query([&"Broken.Pool.Nothing"])
	_save("rooms", "empty_item_pool", _room("empty_item_pool", [&"Broken.Room"], [pedestal]))

	# Rooms for the chapters: generation rooms and weight-0 rooms.
	var rooms := {}
	for role in [["start", &"Room.Type.Start"], ["normal", &"Room.Type.Normal"], ["boss", &"Room.Type.Boss"]]:
		rooms["gen_" + role[0]] = _save("rooms", "gen_" + role[0], _room("gen_" + role[0], [&"Broken.Gen", role[1]], []))
		var zero := _room("zero_" + role[0], [&"Broken.Zero", role[1]], [])
		zero.weight_x100 = 0
		_save("rooms", "zero_" + role[0], zero)

	# Event: GoToPage past the last page.
	var event := EventDefinition.new()
	event.id = &"broken.event.bad_event"
	var page := EventPage.new()
	var choice := EventChoice.new()
	choice.label = "Go"
	var go := GoToPage.new()
	go.page = 5
	choice.outcomes.append(go)
	page.choices.append(choice)
	event.pages.append(page)
	_save("events", "bad_event", event)

	# Layout with two starts.
	var layout := FloorLayout.new()
	layout.id = &"broken.layout.bad_layout"
	for entry in [[Vector2i(0, 0), FloorLayoutCell.Role.START], [Vector2i(1, 0), FloorLayoutCell.Role.START],
			[Vector2i(2, 0), FloorLayoutCell.Role.BOSS]]:
		var cell := FloorLayoutCell.new()
		cell.cell = entry[0]
		cell.room = rooms["gen_normal"]
		cell.role = entry[1]
		layout.cells.append(cell)
	layout = _save("layouts", "bad_layout", layout)

	# Chapters: one whose room query matches nothing, one whose rooms all weigh 0, one whose rules can't be met.
	var scaling := ScalingRules.new()
	scaling.id = &"broken.scaling.basic"
	scaling = _save("scaling", "basic", scaling)
	var ok_rules := FloorGenRules.new()
	ok_rules.id = &"broken.rules.ok"
	ok_rules = _save("floor_rules", "ok", ok_rules)
	var impossible := FloorGenRules.new()
	impossible.id = &"broken.rules.impossible"
	impossible.grid_size = Vector2i(3, 3)
	impossible.base_rooms = 30
	impossible.max_rooms = 30
	impossible.max_attempts = 3
	impossible = _save("floor_rules", "impossible", impossible)
	_save("chapters", "empty_query", _chapter("empty_query", &"Broken.Chapter.Nothing", ok_rules, scaling))
	_save("chapters", "zero_weights", _chapter("zero_weights", &"Broken.Zero", ok_rules, scaling))
	var gen: ChapterDefinition = _save("chapters", "gen", _chapter("gen", &"Broken.Gen", impossible, scaling))

	# Run structure: one floor whose chapter can't generate (generation_fails).
	var run := RunStructure.new()
	run.id = &"broken.run.generation_fails"
	var slot := FloorSlot.new()
	slot.chapters.append(gen)
	run.floors.append(slot)
	run.fallback_item = fallback
	_save("runs", "run", run)

	# Spec playable-demo 2.2: two runs flagged default_run (run_default_twice on the second id). Their floor is the
	# layout, so the validator doesn't generate it.
	for name in ["default_a", "default_b"]:
		var flagged := RunStructure.new()
		flagged.id = StringName("broken.run." + name)
		flagged.default_run = true
		var fixed := FloorSlot.new()
		fixed.chapters.append(gen)
		fixed.layout = layout
		flagged.floors.append(fixed)
		flagged.fallback_item = fallback
		_save("runs", name, flagged)

	# Spec item-pass: equipment without a slot, a placement offering an item and equipment, a trigger typo.
	var no_slot := EquipmentDefinition.new()
	no_slot.id = &"broken.equipment.bad_equipment"
	no_slot = _save("equipment", "bad_equipment", no_slot)
	var both := _placement(Vector2i(6, 3), P.ITEM_PEDESTAL)
	both.item = fallback
	both.equipment = no_slot
	_save("rooms", "placement_both", _room("placement_both", [&"Broken.Room"], [both]))
	var typo_path := ROOT + "abilities/trigger_unregistered.tscn"
	if _rebuild or not ResourceLoader.exists(typo_path):
		var typo := strike.instantiate() as BattleAbility
		typo.ability_tag = &"Broken.Ability.Typo"
		typo.trigger_event_tag = &"Event.Damage.Delt"
		var scene := PackedScene.new()
		scene.pack(typo)
		ResourceSaver.save(scene, typo_path)
		typo.free()
	var typo_set := AbilitySet.new()
	typo_set.abilities.append(load(typo_path))
	var typo_item := _item("broken.item.trigger_unregistered", [])
	typo_item.grants = typo_set
	_save("items", "trigger_unregistered", typo_item)

	# Spec animation-sets: a view path that isn't there; a view whose set has a non-looping idle and tracks outside
	# the skeleton its profile asks for; an ability animation moving a node that view doesn't have.
	for directory in ["views", "animation_sets"]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + directory))
	var lost := CharacterDefinition.new()
	_unit(lost, "broken.character.view_missing", [strike])
	lost.view = ROOT + "views/nowhere.tscn"
	_save("characters", "view_missing", lost)
	var stiff := UnitAnimationSet.new()
	stiff.idle = Animation.new()  # LOOP_NONE
	var stray := stiff.idle.add_track(Animation.TYPE_VALUE)
	stiff.idle.track_set_path(stray, NodePath("Body:position"))
	stiff.idle.track_insert_key(stray, 0.0, Vector3.ZERO)
	stiff.skeleton_profile = SkeletonProfileHumanoid.new()
	stiff = _save("animation_sets", "not_looping", stiff)
	var view_path := ROOT + "views/bad_set_view.tscn"
	if _rebuild or not ResourceLoader.exists(view_path):
		var view_root := UnitAnimator.new()
		view_root.animation_set = stiff
		var view_scene := PackedScene.new()
		view_scene.pack(view_root)
		ResourceSaver.save(view_scene, view_path)
		view_root.free()
	var reach_path := ROOT + "abilities/far_reach.tscn"
	if _rebuild or not ResourceLoader.exists(reach_path):
		var reach := strike.instantiate() as BattleAbility
		reach.ability_tag = &"Broken.Ability.FarReach"
		var moving: Animation = reach.animation.duplicate()
		var arm := moving.add_track(Animation.TYPE_VALUE)
		moving.track_set_path(arm, NodePath("Arm:position"))
		moving.track_insert_key(arm, 0.0, Vector3.ZERO)
		reach.animation = moving
		var reach_scene := PackedScene.new()
		reach_scene.pack(reach)
		ResourceSaver.save(reach_scene, reach_path)
		reach.free()
	var styled := CharacterDefinition.new()
	_unit(styled, "broken.character.bad_view_set", [load(reach_path)])
	styled.view = view_path
	_save("characters", "bad_view_set", styled)

	# Spec ult-interrupts: an ult that is a triggered passive (error), and an enemy ult without a cost or a charge
	# source (two warnings).
	var triggered_ult := _ult_scene(strike, "triggered_ult", &"Event.Battle.Start")
	var free_ult := _ult_scene(strike, "free_ult", &"")
	var ult_character := CharacterDefinition.new()
	_unit(ult_character, "broken.character.ult_triggered", [strike, triggered_ult])
	_save("characters", "ult_triggered", ult_character)
	var uncharged := EnemyDefinition.new()
	_unit(uncharged, "broken.enemy.uncharged", [strike, free_ult])
	_save("enemies", "uncharged", uncharged)

	# Spec content-pass: boss phases out of order, a pattern step the enemy lacks, two affinities for one type (enemies);
	# a status chance on a damage row and a control effect without a Status.Debuff.* tag (characters).
	var out_of_order := EnemyDefinition.new()
	_unit(out_of_order, "broken.enemy.phase_order", [strike])
	for hp_below in [50.0, 60.0]:
		var phase := BossPhase.new()
		phase.hp_below_x100 = Fixed.from_typed(hp_below)
		out_of_order.phases.append(phase)
	_save("enemies", "phase_order", out_of_order)
	var drummer := EnemyDefinition.new()
	_unit(drummer, "broken.enemy.pattern_unknown", [strike])
	var pattern := PatternBrain.new()
	pattern.pattern.assign([&"Broken.Ability.Nowhere"])
	drummer.brain = pattern
	_save("enemies", "pattern_unknown", drummer)
	var torn := EnemyDefinition.new()
	_unit(torn, "broken.enemy.affinity_conflict", [strike])
	torn.tags.assign([&"Drain.Fire", &"Weakness.Fire"])
	_save("enemies", "affinity_conflict", torn)
	var gamble := _row_scene(strike, "chance_on_damage", null)
	var gambler := CharacterDefinition.new()
	_unit(gambler, "broken.character.chance_on_damage", [gamble])
	_save("characters", "chance_on_damage", gambler)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "effects"))
	var silent := GameplayEffect.new()
	silent.policy = GameplayEffect.DurationPolicy.TURN_BASED
	silent.granted_tags.assign([Battle.CONTROLLED_TAG])
	var silent_path := ROOT + "effects/controlled_without_status.tres"
	if _rebuild or not ResourceLoader.exists(silent_path):
		ResourceSaver.save(silent, silent_path)
	var hush := _row_scene(strike, "controlled_without_status", load(silent_path))
	var hushed := CharacterDefinition.new()
	_unit(hushed, "broken.character.controlled_without_status", [hush])
	_save("characters", "controlled_without_status", hushed)
	var armored := CharacterDefinition.new()
	_unit(armored, "broken.character.party_toughness", [strike])
	armored.stats_x100.assign({"max_toughness": 6000, "toughness": 6000})
	_save("characters", "party_toughness", armored)

	# Spec playable-demo 3.8: a per-item effect that refreshes (error), a route slot no chapter of the previous floor
	# can follow (error), a choice of one (warning), a rotating chapter with fewer bosses than floors (warning), and a
	# price item whose effect refreshes (warning). The runs' floors are the layout, so nothing generates.
	var refreshing := GameplayEffect.new()
	refreshing.policy = GameplayEffect.DurationPolicy.INFINITE
	refreshing.stacking_policy = GameplayEffect.StackingPolicy.REFRESH_DURATION
	var greedy := EnemyDefinition.new()
	_unit(greedy, "broken.enemy.per_item_refresh", [strike])
	greedy.per_item_effect = refreshing
	_save("enemies", "per_item_refresh", greedy)
	var lit: ChapterDefinition = gen.duplicate()
	lit.id = &"broken.chapter.lit"
	lit.route_tag = &"Route.Light"
	_save("runs", "route_unmatched", _routed_run("route_unmatched", [[[gen], FloorSlot.Pick.RANDOM],
		[[lit], FloorSlot.Pick.ROUTE]], layout, fallback))
	_save("runs", "choice_single", _routed_run("choice_single", [[[gen], FloorSlot.Pick.CHOICE]], layout, fallback))
	var rotating: ChapterDefinition = gen.duplicate()
	rotating.id = &"broken.chapter.rotation_short"
	rotating.boss_rotation = true
	rotating.boss_encounter_query = _query([&"Broken.NoBoss"])  # no boss for its two floors
	rotating = _save("chapters", "rotation_short", rotating)
	_save("runs", "rotation_short", _routed_run("rotation_short", [[[rotating], FloorSlot.Pick.RANDOM],
		[[rotating], FloorSlot.Pick.RANDOM]], layout, fallback))
	var curse := _item("broken.item.refreshing_curse", [])
	curse.grants = AbilitySet.new()
	curse.grants.effects.append(refreshing)
	curse = _save("items", "refreshing_curse", curse)
	var altar := _placement(Vector2i(6, 3), RoomPlacement.Kind.ITEM_PEDESTAL)
	altar.item = fallback
	altar.price_item = curse
	_save("rooms", "price_refresh", _room("price_refresh", [&"Broken.Room"], [altar]))

	# Spec auto-battle: a party ability without a role (role_missing) and one whose role doesn't fit its targeting
	# (role_mismatch: Heal on an enemy move).
	var roles := CharacterDefinition.new()
	_unit(roles, "broken.character.roles", [_role_scene(strike, "role_missing", []),
		_role_scene(strike, "role_mismatch", [AutoPolicy.ROLE_DAMAGE, AutoPolicy.ROLE_HEAL])])
	_save("characters", "roles", roles)

	# Spec ff7-ui F4: two abilities tagged Ability.Type.Basic make Attack ambiguous (basic_ability_multiple).
	var two_basics := CharacterDefinition.new()
	var basic := [AutoPolicy.ROLE_DAMAGE, &"Ability.Type.Basic"]
	_unit(two_basics, "broken.character.two_basics", [_role_scene(strike, "basic_a", basic),
		_role_scene(strike, "basic_b", basic)])
	_save("characters", "two_basics", two_basics)
	print("Broken fixtures built under ", ROOT)
	get_tree().quit(0)


## A copy of `base` tagged Ability.Type.Ultimate, with no cost, saved as abilities/<name>.tscn.
func _ult_scene(base: PackedScene, name: String, trigger: StringName) -> PackedScene:
	var path := ROOT + "abilities/%s.tscn" % name
	if _rebuild or not ResourceLoader.exists(path):
		var ability := base.instantiate() as BattleAbility
		ability.ability_tag = StringName("Broken.Ability." + name.to_pascal_case())
		ability.asset_tags.append(BattleAbility.ULTIMATE_TAG)  # keeps the base's role (spec auto-battle)
		ability.trigger_event_tag = trigger
		var scene := PackedScene.new()
		scene.pack(ability)
		ResourceSaver.save(scene, path)
		ability.free()
	return load(path)


## A copy of `base` with exactly `roles` as its asset tags, saved as abilities/<name>.tscn.
func _role_scene(base: PackedScene, name: String, roles: Array) -> PackedScene:
	var path := ROOT + "abilities/%s.tscn" % name
	if _rebuild or not ResourceLoader.exists(path):
		var ability := base.instantiate() as BattleAbility
		ability.ability_tag = StringName("Broken.Ability." + name.to_pascal_case())
		ability.asset_tags.assign(roles)
		var scene := PackedScene.new()
		scene.pack(ability)
		ResourceSaver.save(scene, path)
		ability.free()
	return load(path)


## A copy of `base` whose first row rolls a 50% status chance (`effect` null: keeps the row's damage effect), saved
## as abilities/<name>.tscn.
func _row_scene(base: PackedScene, name: String, effect: GameplayEffect) -> PackedScene:
	var path := ROOT + "abilities/%s.tscn" % name
	if _rebuild or not ResourceLoader.exists(path):
		var ability := base.instantiate() as BattleAbility
		ability.ability_tag = StringName("Broken.Ability." + name.to_pascal_case())
		var row: ExecutionRow = ability.executions[0].duplicate()
		row.chance_x100 = Fixed.from_typed(50)
		if effect != null:
			row.effect = effect
			row.chance_x100 = 0
		var rows: Array[ExecutionRow] = [row]
		ability.executions = rows
		var scene := PackedScene.new()
		scene.pack(ability)
		ResourceSaver.save(scene, path)
		ability.free()
	return load(path)


func _item(id: String, tags: Array) -> ItemDefinition:
	var item := ItemDefinition.new()
	item.id = StringName(id)
	item.tags.assign(tags)
	return item


func _routed_run(name: String, slot_specs: Array, layout: FloorLayout, fallback: ItemDefinition) -> RunStructure:
	var run := RunStructure.new()
	run.id = StringName("broken.run." + name)
	run.fallback_item = fallback
	for spec in slot_specs:
		var slot := FloorSlot.new()
		slot.chapters.assign(spec[0])
		slot.pick = spec[1]
		slot.layout = layout
		run.floors.append(slot)
	return run


func _unit(unit: UnitDefinition, id: String, abilities: Array) -> void:
	unit.id = StringName(id)
	unit.attribute_set = ATTRIBUTE_SET
	unit.abilities.assign(abilities)


func _encounter(id: String, enemies: Array) -> EncounterDefinition:
	var encounter := EncounterDefinition.new()
	encounter.id = StringName(id)
	for enemy in enemies:
		var slot := EncounterSlot.new()
		slot.enemy = enemy
		encounter.slots.append(slot)
	return encounter


func _room(name: String, tags: Array, placements: Array) -> RoomDefinition:
	var room := RoomDefinition.new()
	room.id = StringName("broken.room." + name)
	room.tags.assign(tags)
	room.placements.assign(placements)
	return room


func _placement(cell: Vector2i, kind: RoomPlacement.Kind) -> RoomPlacement:
	var placement := RoomPlacement.new()
	placement.cell = cell
	placement.kind = kind
	return placement


func _query(require_all: Array) -> GameplayTagQuery:
	var query := GameplayTagQuery.new()
	query.require_all_tags.assign(require_all)
	return query


func _chapter(name: String, tag: StringName, rules: FloorGenRules, scaling: ScalingRules) -> ChapterDefinition:
	var chapter := ChapterDefinition.new()
	chapter.id = StringName("broken.chapter." + name)
	chapter.room_query = _query([tag])
	chapter.floor_gen_rules = rules
	chapter.scaling = scaling
	return chapter


func _save(directory: String, name: String, resource: Resource) -> Resource:
	var path := ROOT + "%s/%s.tres" % [directory, name]
	if _rebuild or not ResourceLoader.exists(path):
		var error := ResourceSaver.save(resource, path)
		if error != OK:
			push_error("build_broken_fixtures: could not save %s (%s)" % [path, error_string(error)])
	_saved[path] = load(path)
	return _saved[path]
