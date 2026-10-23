## Builds the frozen fixture content under res://tests/fixtures/ (system-owned, never references res://content/).
##   godot --headless --path client-godot res://tests/tools/build_fixtures.tscn [-- --rebuild]
## Files that already exist are loaded, not rewritten, so adding fixtures leaves the frozen ones (and their uids)
## untouched. --rebuild rewrites everything, which changes resource uids: only when existing fixtures must change.
## Values are typed as designers would (Fixed.from_typed converts them ×100), to exercise the authoring format.
extends Node

const ROOT := "res://tests/fixtures/"
const DAMAGE_SCRIPT := preload("res://tests/fixtures/exec_calcs/fixture_damage.gd")
const SLEEPY_SCRIPT := preload("res://tests/fixtures/abilities/sleepy_ability.gd")
const ATTRIBUTE_SET := preload("res://tests/fixtures/attributes/fixture_attribute_set.gd")
const RUN_ATTRIBUTE_SET := preload("res://tests/fixtures/attributes/fixture_run_attribute_set.gd")
const BREAK_ATTRIBUTE_SET := preload("res://tests/fixtures/attributes/fixture_break_attribute_set.gd")
## Run-world folders (spec game-skeleton 6, "Fixtures").
const WORLD_DIRECTORIES: Array[String] = ["characters", "enemies", "loadouts", "variants", "equipment", "items", "events",
	"rooms", "chapters", "scaling", "floor_rules", "runs", "layouts"]

var _effects := {}
var _abilities := {}
var _units := {}
var _world := {}
var _rebuild := false
var _written := 0


func _ready() -> void:
	_rebuild = OS.get_cmdline_user_args().has("--rebuild")
	for directory in ["effects", "animations", "abilities", "units", "encounters"] + WORLD_DIRECTORIES:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + directory))
	_build_effects()
	_build_abilities()
	_build_units()
	_build_encounters()
	_build_run_world()
	_build_item_pass()
	_build_ult_interrupts()
	_build_views()
	print("Fixtures under %s: %d file(s) written" % [ROOT, _written])
	get_tree().quit(0)


## True when `path` should be (re)written; otherwise the existing file is kept and loaded.
func _should_write(path: String) -> bool:
	return _rebuild or not ResourceLoader.exists(path)


func _save(resource: Resource, path: String) -> void:
	if _should_write(path):
		_check(ResourceSaver.save(resource, path), path)
		_written += 1


func _build_effects() -> void:
	var damage := GameplayEffect.new()
	damage.policy = GameplayEffect.DurationPolicy.INSTANT
	damage.executions.append(DAMAGE_SCRIPT.new())
	_save_effect("damage", damage)

	_save_effect("haste", _turn_buff("spd", 20, 2))    # +20% SPD for 2 turns
	_save_effect("guard", _turn_buff("def", 50, 2))    # +50% DEF for 2 turns
	_save_effect("weaken", _turn_buff("def", -20, 2))  # -20% DEF for 2 turns

	var poison := GameplayEffect.new()
	poison.policy = GameplayEffect.DurationPolicy.TURN_BASED
	poison.period = 1.0
	poison.duration_turns = 3
	poison.modifiers.append(_modifier("hp", GameplayEffectModifier.Operation.ADD, -30))  # 30 HP per tick
	_save_effect("poison", poison)

	var noop := GameplayEffect.new()
	noop.policy = GameplayEffect.DurationPolicy.INSTANT
	_save_effect("noop", noop)


func _turn_buff(attribute_name: String, percent: float, turns: int) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.TURN_BASED
	effect.duration_turns = turns
	effect.modifiers.append(_modifier(attribute_name, GameplayEffectModifier.Operation.PERCENT_ADD, percent))
	return effect


func _modifier(attribute_name: String, operation: GameplayEffectModifier.Operation, typed: float) -> CombatModifier:
	var modifier := CombatModifier.new()
	modifier.attribute_name = attribute_name
	modifier.operation = operation
	modifier.value_x100 = Fixed.from_typed(typed)
	return modifier


func _save_effect(name: String, effect: GameplayEffect) -> void:
	var path := ROOT + "effects/%s.tres" % name
	_save(effect, path)
	_effects[name] = load(path)


func _build_abilities() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	_ability("strike", "Fixture.Ability.Strike", B.SINGLE_ENEMY,
		[_row("hit", "damage", D.SCALED, 100, T.ALL)], [[0.3, "hit"]])
	_ability("combo", "Fixture.Ability.Combo", B.BLAST_ENEMY,
		[_row("slash_light", "damage", D.SCALED, 60, T.PRIMARY),
		 _row("slash_heavy", "damage", D.SCALED, 120, T.PRIMARY),
		 _row("shockwave", "damage", D.FLAT, 80.5, T.ADJACENT)],
		[[0.35, "slash_light"], [0.6, "slash_light"], [1.1, "slash_heavy"], [1.15, "shockwave"]],
		[[0.2, "play_sound", "swoosh"]])  # not an execute key: ignored by combat
	_ability("sweep", "Fixture.Ability.Sweep", B.ALL_ENEMIES,
		[_row("sweep", "damage", D.SCALED, 60, T.ALL)], [[0.5, "sweep"]])
	_ability("haste", "Fixture.Ability.Haste", B.SINGLE_ALLY,
		[_row("buff", "haste", D.USE_EFFECT, 0, T.ALL)], [[0.4, "buff"]])
	_ability("guard", "Fixture.Ability.Guard", B.SELF,
		[_row("buff", "guard", D.USE_EFFECT, 0, T.ALL)], [[0.4, "buff"]])
	_ability("weaken", "Fixture.Ability.Weaken", B.SINGLE_ENEMY,
		[_row("hit", "damage", D.SCALED, 50, T.ALL), _row("debuff", "weaken", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "hit"], [0.5, "debuff"]])
	_ability("poison", "Fixture.Ability.Poison", B.SINGLE_ENEMY,
		[_row("hit", "damage", D.SCALED, 40, T.ALL), _row("dot", "poison", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "hit"], [0.5, "dot"]])
	_ability("idle", "Fixture.Ability.Idle", B.SELF,
		[_row("idle", "noop", D.USE_EFFECT, 0, T.ALL)], [[0.1, "idle"]])
	_ability("claw", "Fixture.Ability.Claw", B.SINGLE_ENEMY,
		[_row("hit", "damage", D.SCALED, 100, T.ALL)], [[0.3, "hit"]])
	_ability("slam", "Fixture.Ability.Slam", B.BLAST_ENEMY,
		[_row("slam_main", "damage", D.SCALED, 80, T.PRIMARY), _row("slam_splash", "damage", D.SCALED, 40, T.ADJACENT)],
		[[0.3, "slam_main"], [0.32, "slam_splash"]])
	_ability("sleepy", "Fixture.Ability.Sleepy", B.SINGLE_ENEMY,
		[_row("hit", "damage", D.SCALED, 100, T.ALL)], [[0.3, "hit"]], [], SLEEPY_SCRIPT)


func _row(id: String, effect_name: String, mode: ExecutionRow.DamageMode, typed: float,
		targets: ExecutionRow.Targets, tags: Array = []) -> ExecutionRow:
	var row := ExecutionRow.new()
	row.id = StringName(id)
	row.effect = _effects[effect_name]
	row.damage_mode = mode
	row.targets = targets
	row.tags.assign(tags)
	if mode == ExecutionRow.DamageMode.FLAT:
		row.flat_damage_x100 = Fixed.from_typed(typed)
	elif mode == ExecutionRow.DamageMode.SCALED:
		row.multiplier_x100 = Fixed.from_typed(typed)
	return row


## extras (run-world abilities): "cost": GameplayEffect, "query": GameplayTagQuery, "trigger": StringName,
## "asset_tags": Array (e.g. Ability.Type.FollowUp).
func _ability(name: String, tag: String, targeting: BattleAbility.Targeting, rows: Array, execute_keys: Array,
		other_keys: Array = [], script: Script = null, extras: Dictionary = {}) -> void:
	var path := ROOT + "abilities/%s.tscn" % name
	if not _should_write(path):
		_abilities[name] = load(path)
		return
	var animation := Animation.new()
	animation.resource_name = name
	animation.length = 1.5
	var track := animation.add_track(Animation.TYPE_METHOD)
	animation.track_set_path(track, NodePath("."))
	for key in execute_keys:
		animation.track_insert_key(track, key[0], {"method": &"execute", "args": [StringName(key[1])]})
	for key in other_keys:
		animation.track_insert_key(track, key[0], {"method": StringName(key[1]), "args": [key[2]]})
	var animation_path := ROOT + "animations/%s.tres" % name
	_check(ResourceSaver.save(animation, animation_path), animation_path)
	_written += 1

	var ability: BattleAbility = script.new() if script else BattleAbility.new()
	ability.name = name.to_pascal_case()
	ability.ability_tag = StringName(tag)
	ability.targeting = targeting
	var typed_rows: Array[ExecutionRow] = []
	typed_rows.assign(rows)
	ability.executions = typed_rows
	ability.animation = load(animation_path)
	ability.cost_effect = extras.get("cost")
	ability.activation_query = extras.get("query")
	ability.trigger_event_tag = extras.get("trigger", &"")
	ability.asset_tags.assign(extras.get("asset_tags", []))
	var scene := PackedScene.new()
	scene.pack(ability)
	_save(scene, path)
	ability.free()
	_abilities[name] = load(path)


func _build_units() -> void:
	var standard := {"crit_rate": 5, "crit_dmg": 50}
	_unit("striker", {"max_hp": 1000, "hp": 1000, "atk": 500, "def": 300, "spd": 100}, standard, ["strike", "combo", "guard"])
	_unit("sweeper", {"max_hp": 900, "hp": 900, "atk": 420, "def": 250, "spd": 110}, {"crit_rate": 10, "crit_dmg": 50}, ["sweep", "strike"])
	_unit("support", {"max_hp": 850, "hp": 850, "atk": 300, "def": 280, "spd": 120}, standard, ["haste", "weaken", "strike"])
	_unit("poisoner", {"max_hp": 880, "hp": 880, "atk": 380, "def": 260, "spd": 95.5}, {"crit_rate": 7.5, "crit_dmg": 60}, ["poison", "strike"])
	_unit("dummy", {"max_hp": 800, "hp": 800, "atk": 300, "def": 200, "spd": 90}, standard, ["claw"])
	_unit("brute", {"max_hp": 3000, "hp": 3000, "atk": 350, "def": 350, "spd": 105}, standard, ["slam", "claw"])
	_unit("wall", {"max_hp": 5000, "hp": 5000, "atk": 0, "def": 0, "spd": 100}, {}, ["idle"])
	_unit("pacifist", {"max_hp": 5000, "hp": 5000, "atk": 0, "def": 0, "spd": 100}, {}, ["idle"])
	_unit("sleeper", {"max_hp": 1000, "hp": 1000, "atk": 500, "def": 300, "spd": 100}, standard, ["sleepy"])


func _unit(name: String, core: Dictionary, extra: Dictionary, ability_names: Array) -> void:
	var unit := UnitDefinition.new()
	unit.id = StringName("fixture.unit." + name)
	unit.attribute_set = ATTRIBUTE_SET
	var stats: Dictionary[String, int] = {}
	for source in [core, extra]:
		for attribute_name in source:
			stats[attribute_name] = Fixed.from_typed(float(source[attribute_name]))
	unit.stats_x100 = stats
	var scenes: Array[PackedScene] = []
	for ability_name in ability_names:
		scenes.append(_abilities[ability_name])
	unit.abilities = scenes
	var path := ROOT + "units/%s.tres" % name
	_save(unit, path)
	_units[name] = load(path)


func _build_encounters() -> void:
	_encounter("duel", ["dummy"])
	_encounter("squad", ["dummy", "brute", "dummy"])
	_encounter("stalemate", ["wall"])


func _encounter(name: String, enemy_names: Array) -> void:
	var encounter := EncounterDefinition.new()
	encounter.id = StringName("fixture.encounter." + name)
	var slots: Array[EncounterSlot] = []
	for enemy_name in enemy_names:
		var slot := EncounterSlot.new()
		slot.enemy = _units[enemy_name]
		slots.append(slot)
	encounter.slots = slots
	var path := ROOT + "encounters/%s.tres" % name
	_save(encounter, path)


## The run world (spec game-skeleton section 6, "Fixtures"). Tags live under Fixture.* and need no registry.
func _build_run_world() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting

	# Effects: heals, revive, MP cost, item / equipment / variant / scaling bonuses.
	_save_effect("heal", _instant("hp", 300))
	_save_effect("revive", _instant("hp", 200))
	_save_effect("mp_cost", _instant("mp", -20))
	_save_effect("whetstone", _infinite("atk", GameplayEffectModifier.Operation.PERCENT_ADD, 20))
	_save_effect("banner", _infinite("def", GameplayEffectModifier.Operation.PERCENT_ADD, 10))
	_save_effect("blade", _infinite("atk", GameplayEffectModifier.Operation.ADD, 50))
	_save_effect("elite", _infinite("max_hp", GameplayEffectModifier.Operation.PERCENT_ADD, 50))
	_save_effect("scale_1", _infinite("def", GameplayEffectModifier.Operation.PERCENT_ADD, 10))
	_save_effect("scale_2", _infinite("atk", GameplayEffectModifier.Operation.PERCENT_ADD, 20))

	# Abilities: an Ice skill, a triggered Fire passive, a map-only heal spell, item use abilities.
	var ice := [&"Damage.Type.Ice"]
	var fire := [&"Damage.Type.Fire"]
	_ability("frost", "Fixture.Ability.Frost", B.SINGLE_ENEMY, [_row("hit", "damage", D.SCALED, 90, T.ALL, ice)], [[0.3, "hit"]])
	_ability("ember", "Fixture.Ability.Ember", B.SINGLE_ENEMY, [_row("burn", "damage", D.FLAT, 50, T.ALL, fire)],
		[[0.2, "burn"]], [], null, {"trigger": &"Event.Damage.Dealt.Ice"})
	_ability("mend", "Fixture.Ability.Mend", B.SINGLE_ALLY, [_row("heal", "heal", D.USE_EFFECT, 0, T.ALL)], [[0.3, "heal"]],
		[], null, {"cost": _effects["mp_cost"], "query": _query([&"State.Infield"])})
	_ability("flask", "Fixture.Ability.Flask", B.ALL_ALLIES, [_row("heal", "heal", D.USE_EFFECT, 0, T.ALL)], [[0.3, "heal"]])
	_ability("feather", "Fixture.Ability.Feather", B.SINGLE_DEAD_ALLY, [_row("revive", "revive", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "revive"]])
	# Birthright-like: the crest grants both; each only activates for its character (tag in the activation query).
	_ability("crest_knight", "Fixture.Ability.CrestKnight", B.SELF, [_row("buff", "whetstone", D.USE_EFFECT, 0, T.ALL)],
		[[0.2, "buff"]], [], null, {"trigger": &"Event.Battle.Start", "query": _query([&"Fixture.Character.Knight"])})
	_ability("crest_medic", "Fixture.Ability.CrestMedic", B.ALL_ALLIES, [_row("heal", "heal", D.USE_EFFECT, 0, T.ALL)],
		[[0.2, "heal"]], [], null, {"trigger": &"Event.Battle.Start", "query": _query([&"Fixture.Character.Medic"])})

	# Equipment and items.
	var blade := EquipmentDefinition.new()
	blade.id = &"fixture.equipment.blade"
	blade.display_name = "Blade"
	blade.slot = &"Fixture.Equipment.Slot.Weapon"
	blade.grants = _ability_set([], ["blade"])
	_save_world("equipment", "blade", blade)
	_item("crumb", [], ItemDefinition.Kind.PASSIVE, null)  # the run's fallback item
	_item("whetstone", [&"Fixture.Pool.Treasure"], ItemDefinition.Kind.PASSIVE, _ability_set([], ["whetstone"]))
	var banner := _item("banner", [&"Fixture.Pool.Treasure", &"Fixture.Pool.Shop"], ItemDefinition.Kind.PASSIVE,
		_ability_set([], ["banner"]), {"applies_to": ItemDefinition.AppliesTo.PARTY})
	_item("ember_charm", [&"Fixture.Pool.Treasure"], ItemDefinition.Kind.PASSIVE, _ability_set(["ember"], []))
	_item("feather", [&"Fixture.Pool.Shop"], ItemDefinition.Kind.USABLE, null,
		{"use_ability": _abilities["feather"], "use_mode": ItemDefinition.UseMode.CONSUMABLE})
	_item("flask", [&"Fixture.Pool.Shop"], ItemDefinition.Kind.USABLE, null,
		{"use_ability": _abilities["flask"], "use_mode": ItemDefinition.UseMode.COOLDOWN, "cooldown_battles": 1})
	_item("satchel", [&"Fixture.Pool.Boss"], ItemDefinition.Kind.PASSIVE, null, {"extra_use_slots": 1})
	var lucky := GainCoins.new()
	lucky.amount = 1
	var lucky_hooks: Array[RunOutcome] = []
	lucky_hooks.append(lucky)
	_item("lucky_coin", [&"Fixture.Pool.Boss"], ItemDefinition.Kind.PASSIVE, null, {"on_room_cleared": lucky_hooks})

	# Characters (with MP and ult charge) and enemies.
	var tough := Loadout.new()
	tough.id = &"fixture.loadout.tough"
	tough.stats_x100.assign({"def": Fixed.from_typed(500)})
	_save_world("loadouts", "tough", tough)
	var elite := EnemyVariant.new()
	elite.id = &"fixture.variant.elite"
	elite.display_name = "Elite"
	elite.display_color = Color.GOLD
	elite.coin_bonus = 2
	elite.grants = _ability_set([], ["elite"])
	_save_world("variants", "elite", elite)

	var run_stats := {"max_mp": 100, "mp": 100, "energy": 0}
	var knight_kit := Loadout.new()
	knight_kit.skills.assign([_abilities["frost"]])
	knight_kit.items.assign([_world["items/feather"]])
	knight_kit.equipment.assign([_world["equipment/blade"]])
	_character("knight", {"max_hp": 1000, "hp": 1000, "atk": 500, "def": 300, "spd": 100, "crit_rate": 5,
		"crit_dmg": 50}, run_stats, ["strike", "combo", "guard"], ["frost", "mend"], knight_kit, Color.STEEL_BLUE)
	var medic_kit := Loadout.new()
	medic_kit.skills.assign([_abilities["mend"]])
	_character("medic", {"max_hp": 850, "hp": 850, "atk": 300, "def": 280, "spd": 120, "crit_rate": 5, "crit_dmg": 50},
		run_stats, ["haste", "strike"], ["mend"], medic_kit, Color.SEA_GREEN)
	_character("rogue", {"max_hp": 880, "hp": 880, "atk": 380, "def": 260, "spd": 95.5, "crit_rate": 7.5, "crit_dmg": 60},
		run_stats, ["poison", "strike"], [], null, Color.MEDIUM_PURPLE)
	_item("crest", [&"Fixture.Pool.Treasure"], ItemDefinition.Kind.PASSIVE, _ability_set(["crest_knight", "crest_medic"], []))
	_enemy("grunt", {"max_hp": 600, "hp": 600, "atk": 250, "def": 150, "spd": 90, "crit_rate": 5, "crit_dmg": 50},
		["claw"], [], Color.INDIAN_RED)
	_enemy("chief", {"max_hp": 1500, "hp": 1500, "atk": 300, "def": 250, "spd": 105, "crit_rate": 5, "crit_dmg": 50},
		["slam", "claw"], [&"Enemy.Boss"], Color.DARK_RED)

	# Encounters (one inline loadout override on slot 2 of the pack).
	var strong := Loadout.new()
	strong.stats_x100.assign({"atk": Fixed.from_typed(400)})
	_world_encounter("pack", [&"Fixture.Chapter.A", &"Fixture.Chapter.B"], [["grunt", null], ["grunt", strong]], 1)
	_world_encounter("lone", [&"Fixture.Chapter.A"], [["grunt", null]], 1)
	_world_encounter("lair", [&"Fixture.Chapter.B"], [["grunt", null], ["grunt", null], ["grunt", null]], 0.5)
	_world_encounter("boss", [&"Fixture.Encounter.Boss", &"Fixture.Chapter.A", &"Fixture.Chapter.B"],
		[["chief", null], ["grunt", null]], 1)

	# Events.
	var coin := EventDefinition.new()
	coin.id = &"fixture.event.coin"
	coin.display_name = "A coin"
	coin.tags.assign([&"Fixture.Event"])
	coin.pages.assign([_page("A coin glints on the floor.", [_choice("Take it", [], [_gain(5)]), _choice("Leave it", [], [])])])
	_save_world("events", "coin", coin)
	var toll := EventDefinition.new()
	toll.id = &"fixture.event.toll"
	toll.display_name = "The toll"
	toll.tags.assign([&"Fixture.Event"])
	var pay := LoseCoins.new()
	pay.amount = 3
	var afford := CoinsAtLeast.new()
	afford.amount = 3
	var to_thanks := GoToPage.new()
	to_thanks.page = 1
	var fight := StartEncounter.new()
	fight.encounter = _world["encounters/lone"]
	var rest := ApplyPartyEffect.new()
	rest.effect = _effects["heal"]
	toll.pages.assign([
		_page("A guard wants 3 coins.", [_choice("Pay", [afford], [pay, to_thanks]), _choice("Fight", [], [fight])]),
		_page("He lets you rest.", [_choice("Rest", [], [rest])]),
	])
	_save_world("events", "toll", toll)

	# Rooms.
	var everywhere := [&"Fixture.Chapter.A", &"Fixture.Chapter.B"]
	var spawns := [_placement(Vector2i(3, 3), RoomPlacement.Kind.PLAYER_SPAWN, 1), _placement(Vector2i(9, 3), RoomPlacement.Kind.ENEMY_SPAWN, 1)]
	_room("start", [&"Fixture.Room.Type.Start"] + everywhere, 15, 1, RoomDefinition.ContentMode.NONE, [])
	_room("cross", [&"Fixture.Room.Type.Normal"] + everywhere, 15, 1, RoomDefinition.ContentMode.ENCOUNTER_QUERY, spawns)
	var guarded := _placement(Vector2i(9, 3), RoomPlacement.Kind.ENEMY_SPAWN, 1)
	guarded.loadout = _world["loadouts/tough"]
	_room("hall", [&"Fixture.Room.Type.Normal", &"Fixture.Chapter.A"], RoomDefinition.DOOR_N | RoomDefinition.DOOR_S, 1,
		RoomDefinition.ContentMode.ENCOUNTER_QUERY, [guarded])
	_room("shrine", [&"Fixture.Room.Type.Normal", &"Fixture.Chapter.A"], 15, 2, RoomDefinition.ContentMode.EVENT_QUERY,
		[_placement(Vector2i(6, 3), RoomPlacement.Kind.EVENT_PROP, 1)])
	_room("den", [&"Fixture.Room.Type.Normal", &"Fixture.Chapter.B"], 15, 1, RoomDefinition.ContentMode.ENCOUNTER_QUERY, spawns)
	var reward := _placement(Vector2i(6, 1), RoomPlacement.Kind.ITEM_PEDESTAL, 1)
	reward.item_query = _query([&"Fixture.Pool.Boss"])
	_room("throne", [&"Fixture.Room.Type.Boss"] + everywhere, 15, 1, RoomDefinition.ContentMode.ENCOUNTER_QUERY, spawns + [reward])
	var treasure := _placement(Vector2i(6, 3), RoomPlacement.Kind.ITEM_PEDESTAL, 1)
	treasure.item_query = _query([&"Fixture.Pool.Treasure"])
	_room("vault", [&"Fixture.Room.Type.Treasure"] + everywhere, 15, 1, RoomDefinition.ContentMode.NONE, [treasure])
	var stock_a := _placement(Vector2i(4, 3), RoomPlacement.Kind.SHOP_SLOT, 1)
	stock_a.item_query = _query([&"Fixture.Pool.Shop"])
	var stock_b := _placement(Vector2i(6, 3), RoomPlacement.Kind.SHOP_SLOT, 1)
	stock_b.item_query = _query([&"Fixture.Pool.Shop"])
	var bargain := _placement(Vector2i(8, 3), RoomPlacement.Kind.SHOP_SLOT, 1)
	bargain.item = _world["items/crumb"]
	bargain.price = 1
	_room("market", [&"Fixture.Room.Type.Shop"] + everywhere, 15, 1, RoomDefinition.ContentMode.NONE, [stock_a, stock_b, bargain])

	# Chapters, rules, scaling, run structure, hand-made layout.
	var rules := FloorGenRules.new()
	rules.id = &"fixture.rules.small"
	rules.base_rooms = 5
	rules.rooms_per_depth = 1
	rules.random_extra_rooms = 1
	rules.max_rooms = 10
	rules.start_room_tag = &"Fixture.Room.Type.Start"
	rules.normal_room_tag = &"Fixture.Room.Type.Normal"
	rules.boss_room_tag = &"Fixture.Room.Type.Boss"
	rules.special_room_tags.assign([&"Fixture.Room.Type.Treasure", &"Fixture.Room.Type.Shop"])
	_save_world("floor_rules", "small", rules)
	var scaling := ScalingRules.new()
	scaling.id = &"fixture.scaling.a"
	scaling.enemy_effects_by_depth.assign([_effects["scale_1"], _effects["scale_2"]])
	scaling.elite_chance_x100 = Fixed.from_typed(30)
	scaling.coin_drop_chance_x100 = Fixed.from_typed(100)
	scaling.coin_drop_min = 1
	scaling.coin_drop_max = 2
	_save_world("scaling", "a", scaling)
	_chapter("a", &"Fixture.Chapter.A")
	_chapter("b", &"Fixture.Chapter.B")
	var run := RunStructure.new()
	run.id = &"fixture.run.two_floors"
	run.display_name = "Two floors"
	run.fallback_item = _world["items/crumb"]
	var first := FloorSlot.new()
	first.chapters.assign([_world["chapters/a"]])
	var second := FloorSlot.new()
	second.chapters.assign([_world["chapters/a"], _world["chapters/b"]])
	run.floors.assign([first, second])
	run.equipment_slots.assign([&"Fixture.Equipment.Slot.Weapon", &"Fixture.Equipment.Slot.Head", &"Fixture.Equipment.Slot.Body"])
	_save_world("runs", "two_floors", run)
	var layout := FloorLayout.new()
	layout.id = &"fixture.layout.line"
	layout.display_name = "A short line"
	layout.cells.assign([
		_layout_cell(Vector2i(3, 4), "start", FloorLayoutCell.Role.START),
		_layout_cell(Vector2i(4, 4), "cross", FloorLayoutCell.Role.NORMAL),
		_layout_cell(Vector2i(4, 3), "vault", FloorLayoutCell.Role.SPECIAL),
		_layout_cell(Vector2i(5, 4), "throne", FloorLayoutCell.Role.BOSS),
	])
	_save_world("layouts", "line", layout)


## Spec item-pass: weakness, toughness and break, follow-ups. Nothing here carries a pool or chapter tag, so floor
## generation (and its goldens) never sees it.
func _build_item_pass() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var fire := [&"Damage.Type.Fire"]
	var follow_up := {"asset_tags": [BattleAbility.FOLLOW_UP_TAG]}

	# "Exposed": weak to Fire for 2 turns, through the effect's granted tags.
	var exposed := GameplayEffect.new()
	exposed.policy = GameplayEffect.DurationPolicy.TURN_BASED
	exposed.duration_turns = 2
	exposed.granted_tags.assign([&"Weakness.Fire"])
	_save_effect("exposed", exposed)
	_save_effect("energy_up", _instant("energy", 10))

	var slash := _row("hit", "damage", D.SCALED, 50, T.ALL, fire)
	slash.toughness_x100 = Fixed.from_typed(30)
	_ability("fire_slash", "Fixture.Ability.FireSlash", B.SINGLE_ENEMY, [slash], [[0.3, "hit"]])
	var wave := _row("hit", "damage", D.SCALED, 30, T.ALL, fire)
	wave.toughness_x100 = Fixed.from_typed(30)
	_ability("fire_wave", "Fixture.Ability.FireWave", B.ALL_ENEMIES, [wave], [[0.3, "hit"]])
	_ability("expose", "Fixture.Ability.Expose", B.SINGLE_ENEMY, [_row("debuff", "exposed", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "debuff"]])
	# Follow-ups: one on weakness hits (typeless, so it can't break), one on crits (Fire, so it can).
	_ability("chaser", "Fixture.Ability.Chaser", B.SINGLE_ENEMY, [_row("hit", "damage", D.FLAT, 10, T.ALL)], [[0.2, "hit"]],
		[], null, follow_up.merged({"trigger": &"Event.Damage.Dealt.Weakness"}))
	var burn := _row("hit", "damage", D.FLAT, 10, T.ALL, fire)
	burn.toughness_x100 = Fixed.from_typed(30)
	_ability("burn_chaser", "Fixture.Ability.BurnChaser", B.SINGLE_ENEMY, [burn], [[0.2, "hit"]],
		[], null, follow_up.merged({"trigger": &"Event.Damage.Dealt.Critical"}))
	_ability("momentum", "Fixture.Ability.Momentum", B.SELF, [_row("charge", "energy_up", D.USE_EFFECT, 0, T.ALL)],
		[[0.1, "charge"]], [], null, {"trigger": &"Event.Attack.FollowUp"})

	_item("chaser_charm", [], ItemDefinition.Kind.PASSIVE, _ability_set(["chaser", "momentum"], []))
	_item("burn_charm", [], ItemDefinition.Kind.PASSIVE, _ability_set(["burn_chaser"], []))

	var break_stats := {"weakness_dmg": 150, "toughness_dmg": 0, "broken_dmg": 0}
	var duelist := CharacterDefinition.new()
	_fill_unit(duelist, "fixture.character.duelist", {"max_hp": 1000, "hp": 1000, "atk": 500, "def": 300, "spd": 100,
		"crit_rate": 0, "crit_dmg": 50, "max_mp": 100, "mp": 100, "energy": 0, "max_toughness": 0, "toughness": 0},
		break_stats, ["fire_slash", "fire_wave", "strike", "expose"], Color.ORANGE_RED, BREAK_ATTRIBUTE_SET)
	duelist.tags.assign([&"Fixture.Character.Duelist"])
	_save_world("characters", "duelist", duelist)
	var brittle := EnemyDefinition.new()
	_fill_unit(brittle, "fixture.enemy.brittle", {"max_hp": 3000, "hp": 3000, "atk": 100, "def": 0, "spd": 80,
		"crit_rate": 0, "crit_dmg": 50, "max_mp": 0, "mp": 0, "energy": 0, "max_toughness": 30, "toughness": 30},
		{"weakness_dmg": 200, "toughness_dmg": 0, "broken_dmg": 0}, ["claw"], Color.SANDY_BROWN, BREAK_ATTRIBUTE_SET)
	brittle.tags.assign([&"Weakness.Fire"])
	_save_world("enemies", "brittle", brittle)
	_world_encounter("brittle_one", [], [["brittle", null]], 1)
	_world_encounter("brittle_pair", [], [["brittle", null], ["brittle", null]], 1)

	# Armor (spec item-pass 3.5): pooled pieces and a pooled item under Fixture.Pool.Armory, offered only by the armory
	# room, which carries no chapter tag (sandbox only), so generated floors never change.
	var armory_pool := [&"Fixture.Pool.Armory"]
	_armor("helm", "Fixture.Equipment.Slot.Head", armory_pool, ["banner"])
	_armor("cap", "Fixture.Equipment.Slot.Head", armory_pool, ["whetstone"])
	_armor("mail", "Fixture.Equipment.Slot.Body", [], [])  # not pooled: only the shelf's fixed offer
	_item("armory_ring", armory_pool, ItemDefinition.Kind.PASSIVE, null)
	var placements := []
	for x in [3, 5, 7]:
		var pedestal := _placement(Vector2i(x, 3), RoomPlacement.Kind.ITEM_PEDESTAL, 1)
		pedestal.item_query = _query(armory_pool)
		placements.append(pedestal)
	var shelf := _placement(Vector2i(9, 3), RoomPlacement.Kind.SHOP_SLOT, 1)
	shelf.equipment = _world["equipment/mail"]
	placements.append(shelf)
	_room("armory", [&"Fixture.Room.Type.Treasure"], 15, 1, RoomDefinition.ContentMode.NONE, placements)


## Spec ult-interrupts: ultists (two party members with four ults, full charge at battle start and +50 per action)
## against the ult trial (a fast enemy, a brittle one, and a raging dummy whose ult charges when it is hit).
func _build_ult_interrupts() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	_save_effect("ult_cost", _instant("energy", -100))
	_save_effect("ult_full", _instant("energy", 100))
	_save_effect("ult_recharge", _instant("energy", 50))
	var ult := {"cost": _effects["ult_cost"], "asset_tags": [BattleAbility.ULTIMATE_TAG]}

	var nova := _row("hit", "damage", D.SCALED, 60, T.ALL, [&"Damage.Type.Fire"])
	nova.toughness_x100 = Fixed.from_typed(30)
	_ability("ult_nova", "Fixture.Ability.UltNova", B.ALL_ENEMIES, [nova], [[0.3, "hit"]], [], null, ult)
	_ability("ult_snipe", "Fixture.Ability.UltSnipe", B.SINGLE_ENEMY, [_row("hit", "damage", D.SCALED, 150, T.ALL)],
		[[0.3, "hit"]], [], null, ult)
	_ability("ult_ward", "Fixture.Ability.UltWard", B.SELF, [_row("buff", "guard", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "buff"]], [], null, ult)
	_ability("ult_raise", "Fixture.Ability.UltRaise", B.SINGLE_DEAD_ALLY, [_row("raise", "revive", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "raise"]], [], null, ult)
	_ability("ult_rage", "Fixture.Ability.UltRage", B.ALL_ENEMIES, [_row("hit", "damage", D.SCALED, 80, T.ALL)],
		[[0.3, "hit"]], [], null, ult)
	_ability("full_charge", "Fixture.Ability.FullCharge", B.SELF, [_row("charge", "ult_full", D.USE_EFFECT, 0, T.ALL)],
		[[0.0, "charge"]], [], null, {"trigger": &"Event.Battle.Start"})
	_ability("recharge", "Fixture.Ability.Recharge", B.SELF, [_row("charge", "ult_recharge", D.USE_EFFECT, 0, T.ALL)],
		[[0.0, "charge"]], [], null, {"trigger": &"Event.Ability.Used"})
	_ability("rage_charge", "Fixture.Ability.RageCharge", B.SELF, [_row("charge", "ult_recharge", D.USE_EFFECT, 0, T.ALL)],
		[[0.0, "charge"]], [], null, {"trigger": &"Event.Damage.Taken"})
	# The martyr's ult kills its caster (an actor dying inside its own DECISION window).
	_save_effect("doom", _instant("hp", -100000))
	_ability("ult_sacrifice", "Fixture.Ability.UltSacrifice", B.SELF, [_row("doom", "doom", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "doom"]], [], null, ult)

	var no_break := {"weakness_dmg": 150, "toughness_dmg": 0, "broken_dmg": 0}
	var ultist := CharacterDefinition.new()
	_fill_unit(ultist, "fixture.character.ultist", {"max_hp": 1200, "hp": 1200, "atk": 400, "def": 300, "spd": 100,
		"crit_rate": 0, "crit_dmg": 50, "max_mp": 100, "mp": 100, "energy": 0, "max_toughness": 0, "toughness": 0},
		no_break, ["strike", "ult_nova", "ult_snipe", "ult_ward", "ult_raise", "full_charge", "recharge"], Color.GOLD,
		BREAK_ATTRIBUTE_SET)
	ultist.tags.assign([&"Fixture.Character.Ultist"])
	_save_world("characters", "ultist", ultist)
	var martyr := CharacterDefinition.new()
	_fill_unit(martyr, "fixture.character.martyr", {"max_hp": 1000, "hp": 1000, "atk": 300, "def": 300, "spd": 120,
		"crit_rate": 0, "crit_dmg": 50, "max_mp": 100, "mp": 100, "energy": 0, "max_toughness": 0, "toughness": 0},
		no_break, ["strike", "ult_sacrifice", "full_charge"], Color.DARK_VIOLET, BREAK_ATTRIBUTE_SET)
	martyr.tags.assign([&"Fixture.Character.Martyr"])
	_save_world("characters", "martyr", martyr)
	var sprinter := EnemyDefinition.new()
	_fill_unit(sprinter, "fixture.enemy.sprinter", {"max_hp": 1500, "hp": 1500, "atk": 150, "def": 0, "spd": 200,
		"crit_rate": 0, "crit_dmg": 50, "max_mp": 0, "mp": 0, "energy": 0, "max_toughness": 0, "toughness": 0},
		no_break, ["claw"], Color.SKY_BLUE, BREAK_ATTRIBUTE_SET)
	_save_world("enemies", "sprinter", sprinter)
	var raging := EnemyDefinition.new()
	_fill_unit(raging, "fixture.enemy.raging", {"max_hp": 2000, "hp": 2000, "atk": 200, "def": 0, "spd": 70,
		"crit_rate": 0, "crit_dmg": 50, "max_mp": 0, "mp": 0, "energy": 0, "max_toughness": 0, "toughness": 0},
		no_break, ["claw", "ult_rage", "rage_charge"], Color.CRIMSON, BREAK_ATTRIBUTE_SET)
	_save_world("enemies", "raging", raging)
	_world_encounter("ult_trial", [], [["sprinter", null], ["brittle", null], ["raging", null]], 1)
	# Two ult enemies (slot order inside one window) and an ally-targeting ult on its own character, so the ultist's
	# kit and the ult-seed-7 golden stay unchanged.
	_world_encounter("rage_pair", [], [["raging", null], ["raging", null]], 1)
	_ability("ult_shield", "Fixture.Ability.UltShield", B.SINGLE_ALLY, [_row("buff", "guard", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "buff"]], [], null, ult)
	var warden := CharacterDefinition.new()
	_fill_unit(warden, "fixture.character.warden", {"max_hp": 1200, "hp": 1200, "atk": 300, "def": 300, "spd": 100,
		"crit_rate": 0, "crit_dmg": 50, "max_mp": 100, "mp": 100, "energy": 0, "max_toughness": 0, "toughness": 0},
		no_break, ["strike", "ult_shield", "full_charge"], Color.SLATE_GRAY, BREAK_ATTRIBUTE_SET)
	warden.tags.assign([&"Fixture.Character.Warden"])
	_save_world("characters", "warden", warden)


## Spec animation-sets: a probe view (UnitAnimator root, a Body node) and a set of short animations with known
## lengths, for headless AnimationTree tests. Presentation-style files, never referenced by fixture content.
func _build_views() -> void:
	for directory in ["views", "animation_sets"]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + directory))
	var set_path := ROOT + "animation_sets/probe_set.tres"
	if _should_write(set_path):
		var probe := UnitAnimationSet.new()
		probe.idle = _view_animation(0.4, "Body:position", [Vector3.ZERO, Vector3(0, 0.1, 0), Vector3.ZERO], true)
		probe.hit = _view_animation(0.2, "Body:position", [Vector3.ZERO, Vector3(0.3, 0, 0), Vector3.ZERO], false)
		probe.death = _view_animation(0.2, "Body:rotation", [Vector3.ZERO, Vector3(0, 0, PI / 2)], false)
		probe.dead = _view_animation(0.2, "Body:rotation", [Vector3(0, 0, PI / 2), Vector3(0, 0, PI / 2)], true)
		probe.revive = _view_animation(0.2, "Body:rotation", [Vector3(0, 0, PI / 2), Vector3.ZERO], false)
		probe.victory = _view_animation(0.2, "Body:rotation", [Vector3.ZERO, Vector3(0, PI, 0)], false)
		probe.cast = _view_animation(0.2, "Body:position", [Vector3.ZERO, Vector3(0, 0.8, 0), Vector3.ZERO], false)
		_save(probe, set_path)
	var view_path := ROOT + "views/probe_view.tscn"
	if _should_write(view_path):
		var root := UnitAnimator.new()
		root.name = "ProbeView"
		root.animation_set = load(set_path)
		var body := Node3D.new()
		body.name = "Body"
		root.add_child(body)
		body.owner = root
		var scene := PackedScene.new()
		scene.pack(root)
		_save(scene, view_path)
		root.free()


## Keys spread evenly over `length` on one value track.
func _view_animation(length: float, path: String, values: Array, looping: bool) -> Animation:
	var animation := Animation.new()
	animation.length = length
	if looping:
		animation.loop_mode = Animation.LOOP_LINEAR
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath(path))
	for index in values.size():
		animation.track_insert_key(track, length * index / maxf(values.size() - 1, 1), values[index])
	return animation


func _armor(name: String, slot: String, tags: Array, effect_names: Array) -> void:
	var piece := EquipmentDefinition.new()
	piece.id = StringName("fixture.equipment." + name)
	piece.display_name = name.capitalize()
	piece.description = "Fixture armor: %s." % name
	piece.slot = StringName(slot)
	piece.tags.assign(tags)
	piece.price = 2
	piece.grants = _ability_set([], effect_names)
	_save_world("equipment", name, piece)


func _instant(attribute_name: String, typed: float) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INSTANT
	effect.modifiers.append(_modifier(attribute_name, GameplayEffectModifier.Operation.ADD, typed))
	return effect


func _infinite(attribute_name: String, operation: GameplayEffectModifier.Operation, typed: float) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INFINITE
	effect.modifiers.append(_modifier(attribute_name, operation, typed))
	return effect


func _query(require_all: Array) -> GameplayTagQuery:
	var query := GameplayTagQuery.new()
	query.require_all_tags.assign(require_all)
	return query


func _ability_set(ability_names: Array, effect_names: Array) -> AbilitySet:
	var ability_set := AbilitySet.new()
	for name in ability_names:
		ability_set.abilities.append(_abilities[name])
	for name in effect_names:
		ability_set.effects.append(_effects[name])
	return ability_set


func _item(name: String, tags: Array, kind: ItemDefinition.Kind, grants: AbilitySet,
		extra: Dictionary = {}) -> ItemDefinition:
	var item := ItemDefinition.new()
	item.id = StringName("fixture.item." + name)
	item.display_name = name.capitalize()
	item.tags.assign(tags)
	item.kind = kind
	item.grants = grants
	item.price = 3
	for key in extra:
		item.set(key, extra[key])
	return _save_world("items", name, item) as ItemDefinition


func _character(name: String, core: Dictionary, extra: Dictionary, ability_names: Array, learnable: Array,
		loadout: Loadout, color: Color) -> CharacterDefinition:
	var character := CharacterDefinition.new()
	_fill_unit(character, "fixture.character." + name, core, extra, ability_names, color)
	character.tags.assign([StringName("Fixture.Character." + name.capitalize())])
	for ability_name in learnable:
		character.learnable_skills.append(_abilities[ability_name])
	character.default_loadout = loadout
	return _save_world("characters", name, character) as CharacterDefinition


func _enemy(name: String, core: Dictionary, ability_names: Array, tags: Array, color: Color) -> void:
	var enemy := EnemyDefinition.new()
	_fill_unit(enemy, "fixture.enemy." + name, core, {}, ability_names, color)
	enemy.tags.assign(tags)
	enemy.variants.assign([_world["variants/elite"]])
	_save_world("enemies", name, enemy)


func _fill_unit(unit: UnitDefinition, id: String, core: Dictionary, extra: Dictionary, ability_names: Array, color: Color,
		attribute_set: Script = RUN_ATTRIBUTE_SET) -> void:
	unit.id = StringName(id)
	unit.display_name = id.get_slice(".", 2).capitalize()
	unit.display_color = color
	unit.attribute_set = attribute_set
	var stats: Dictionary[String, int] = {}
	for source in [core, extra]:
		for attribute_name in source:
			stats[attribute_name] = Fixed.from_typed(float(source[attribute_name]))
	unit.stats_x100 = stats
	for ability_name in ability_names:
		unit.abilities.append(_abilities[ability_name])


func _world_encounter(name: String, tags: Array, slot_specs: Array, weight: float) -> void:
	var encounter := EncounterDefinition.new()
	encounter.id = StringName("fixture.encounter." + name)
	encounter.display_name = name.capitalize()
	encounter.tags.assign(tags)
	encounter.weight_x100 = Fixed.from_typed(weight)
	for spec in slot_specs:
		var slot := EncounterSlot.new()
		slot.enemy = _world["enemies/" + spec[0]]
		slot.loadout = spec[1]
		encounter.slots.append(slot)
	_save_world("encounters", name, encounter)


func _page(text: String, choices: Array) -> EventPage:
	var page := EventPage.new()
	page.text = text
	page.choices.assign(choices)
	return page


func _choice(label: String, conditions: Array, outcomes: Array) -> EventChoice:
	var choice := EventChoice.new()
	choice.label = label
	choice.conditions.assign(conditions)
	choice.outcomes.assign(outcomes)
	return choice


func _gain(amount: int) -> GainCoins:
	var outcome := GainCoins.new()
	outcome.amount = amount
	return outcome


func _placement(cell: Vector2i, kind: RoomPlacement.Kind, slot: int) -> RoomPlacement:
	var placement := RoomPlacement.new()
	placement.cell = cell
	placement.kind = kind
	placement.slot = slot
	return placement


func _room(name: String, tags: Array, doors: int, min_doors: int, mode: RoomDefinition.ContentMode,
		placements: Array) -> void:
	var room := RoomDefinition.new()
	room.id = StringName("fixture.room." + name)
	room.display_name = name.capitalize()
	room.tags.assign(tags)
	room.doors = doors
	room.min_doors = min_doors
	room.content_mode = mode
	room.placements.assign(placements)
	_save_world("rooms", name, room)


func _chapter(name: String, chapter_tag: StringName) -> void:
	var chapter := ChapterDefinition.new()
	chapter.id = StringName("fixture.chapter." + name)
	chapter.display_name = "Chapter " + name.to_upper()
	chapter.tags.assign([chapter_tag])
	chapter.room_query = _query([chapter_tag])
	chapter.encounter_query = _query([chapter_tag])
	chapter.encounter_query.ignore_tags.assign([&"Fixture.Encounter.Boss"])
	chapter.boss_encounter_query = _query([&"Fixture.Encounter.Boss", chapter_tag])
	chapter.event_query = _query([&"Fixture.Event"])
	chapter.floor_gen_rules = _world["floor_rules/small"]
	chapter.scaling = _world["scaling/a"]
	_save_world("chapters", name, chapter)


func _layout_cell(cell: Vector2i, room_name: String, role: FloorLayoutCell.Role) -> FloorLayoutCell:
	var entry := FloorLayoutCell.new()
	entry.cell = cell
	entry.room = _world["rooms/" + room_name]
	entry.role = role
	return entry


func _save_world(directory: String, name: String, resource: Resource) -> Resource:
	var path := ROOT + "%s/%s.tres" % [directory, name]
	_save(resource, path)
	_world["%s/%s" % [directory, name]] = load(path)
	return _world["%s/%s" % [directory, name]]


func _check(error: Error, path: String) -> void:
	if error != OK:
		push_error("build_fixtures: could not save %s (%s)" % [path, error_string(error)])
