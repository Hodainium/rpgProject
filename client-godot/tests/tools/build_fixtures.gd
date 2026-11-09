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
const STATUS_ATTRIBUTE_SET := preload("res://tests/fixtures/attributes/fixture_status_attribute_set.gd")
const SP_ATTRIBUTE_SET := preload("res://tests/fixtures/attributes/fixture_sp_attribute_set.gd")
const SP_RESTORE_SCRIPT := preload("res://tests/fixtures/exec_calcs/fixture_sp_restore.gd")
const SP_COST_SCRIPT := preload("res://tests/fixtures/exec_calcs/fixture_sp_cost.gd")
## Run-world folders (spec game-skeleton 6, "Fixtures").
const WORLD_DIRECTORIES: Array[String] = ["characters", "enemies", "loadouts", "variants", "equipment", "items", "events",
	"rooms", "chapters", "scaling", "floor_rules", "runs", "layouts", "chests"]
## Spec auto-battle: roles the role pass can't read from an ability's rows (its effects carry no Status.* tag).
## Every other non-triggered ability gets RolePass.roles_of.
const ROLE_OVERRIDES: Dictionary = {
	"expose": [&"Ability.Role.Debuff"], "guard": [&"Ability.Role.Buff"], "haste": [&"Ability.Role.Buff"],
	"rally": [&"Ability.Role.Buff"], "ult_sacrifice": [&"Ability.Role.Buff"], "ult_shield": [&"Ability.Role.Buff"],
	"ult_ward": [&"Ability.Role.Buff"],
}

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
	_build_content_pass()
	_build_full_descent()
	_build_keys_and_gear()
	_build_skill_points()
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
	if not ability.is_triggered():
		ability.asset_tags.append_array(ROLE_OVERRIDES.get(name, RolePass.roles_of(ability)))
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
	# Spec run-verify 4: a party that cannot lose to any fixture enemy, so an e2e scenario can play a whole run (through a
	# rollback and a rebuild) and still end Won whatever the dice say. Nothing refers to it but the scenarios that name it.
	_character("titan", {"max_hp": 5000000, "hp": 5000000, "atk": 9000, "def": 9000, "spd": 200, "crit_rate": 5,
		"crit_dmg": 50}, run_stats, ["strike"], [], null, Color.GOLD)
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


## Spec content-pass: statuses (DoT, stacking, control, taunt, immunity, cleanse, delay and advance), affinities
## (drain, resist), per-type break effects, ult-reacting passives, boss phases and the two brains. New units use
## FixtureStatusAttributeSet; nothing carries a pool or chapter tag, so floor generation never sees it.
func _build_content_pass() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	var fire := [&"Damage.Type.Fire"]
	var ice := [&"Damage.Type.Ice"]
	var ult := {"cost": _effects["ult_cost"], "asset_tags": [BattleAbility.ULTIMATE_TAG]}
	var not_controlled := _query([])
	not_controlled.ignore_tags.assign([&"State.Controlled"])

	# Statuses.
	var burn := _status(2, [&"Status.Debuff.Burn"])
	burn.period = 1.0
	burn.executions.append(DAMAGE_SCRIPT.new())  # a typed DoT: each tick runs the damage ExecCalc (affinities apply)
	_save_effect("st_burn", burn)
	var poison := _status(3, [&"Status.Debuff.Poison"])
	poison.period = 1.0
	poison.modifiers.append(_modifier("hp", GameplayEffectModifier.Operation.ADD, -20))  # 20 HP per stack per tick
	poison.max_stacks = 5
	_save_effect("st_poison", poison)
	_save_effect("st_freeze", _status(1, [&"Status.Debuff.Freeze", &"State.Controlled"]))
	var stun := _status(1, [&"Status.Debuff.Stun", &"State.Controlled"])
	stun.application_query = _query([])
	stun.application_query.ignore_tags.assign([&"Immune.Control"])
	_save_effect("st_stun", stun)
	_save_effect("st_taunt", _status(2, [&"Status.Buff.Taunt", &"State.Taunting"]))
	_save_effect("st_ward", _status(2, [&"Status.Buff.Ward", &"Immune.Control"]))
	var vulnerable := _status(2, [&"Status.Debuff.Vulnerable"])
	vulnerable.modifiers.append(_modifier("def", GameplayEffectModifier.Operation.PERCENT_ADD, -10))
	vulnerable.max_stacks = 3
	_save_effect("st_vulnerable", vulnerable)
	var entangle := _status(2, [&"Status.Debuff.Entangle"])
	entangle.modifiers.append(_modifier("spd", GameplayEffectModifier.Operation.PERCENT_ADD, -10))
	_save_effect("st_entangle", entangle)
	var cleanse := GameplayEffect.new()
	cleanse.policy = GameplayEffect.DurationPolicy.INSTANT
	cleanse.remove_effects_with_tags.assign([&"Status.Debuff"])
	_save_effect("st_cleanse", cleanse)
	# Affinities (worn: infinite effects that grant the tags).
	_save_effect("drain_fire_implant", _granting([&"Drain.Fire", &"Weakness.Ice"]))
	_save_effect("resist_ice", _granting([&"Resist.Ice"]))
	_save_effect("drain_physical", _granting([&"Drain.Physical"]))
	_save_effect("ult_refund", _instant("energy", 20))

	# Party abilities.
	_ability("hex_burn", "Fixture.Ability.HexBurn", B.SINGLE_ENEMY, [_row("hit", "damage", D.FLAT, 40, T.ALL, fire),
		_row("dot", "st_burn", D.FLAT, 30, T.ALL, fire)], [[0.3, "hit"], [0.5, "dot"]])
	var freeze_row := _row("freeze", "st_freeze", D.USE_EFFECT, 0, T.ALL)
	freeze_row.chance_x100 = Fixed.from_typed(50)
	_ability("frost_hex", "Fixture.Ability.FrostHex", B.SINGLE_ENEMY, [_row("hit", "damage", D.FLAT, 40, T.ALL, ice),
		freeze_row], [[0.3, "hit"], [0.5, "freeze"]])
	_ability("toxic_cloud", "Fixture.Ability.ToxicCloud", B.ALL_ENEMIES, [_row("dot", "st_poison", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "dot"], [0.5, "dot"]])
	_ability("ult_purify", "Fixture.Ability.UltPurify", B.ALL_ALLIES, [_row("cleanse", "st_cleanse", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "cleanse"]], [], null, ult.merged({"query": not_controlled}))
	_ability("provoke", "Fixture.Ability.Provoke", B.SELF, [_row("taunt", "st_taunt", D.USE_EFFECT, 0, T.ALL)], [[0.3, "taunt"]])
	var entangle_row := _row("entangle", "st_entangle", D.USE_EFFECT, 0, T.ALL)
	entangle_row.delay_x100 = Fixed.from_typed(30)
	_ability("entangle", "Fixture.Ability.Entangle", B.SINGLE_ENEMY, [entangle_row], [[0.3, "entangle"]])
	var rally_row := _row("advance", "noop", D.USE_EFFECT, 0, T.ALL)
	rally_row.delay_x100 = Fixed.from_typed(-25)
	_ability("rally", "Fixture.Ability.Rally", B.SINGLE_ALLY, [rally_row], [[0.3, "advance"]])
	_ability("ward", "Fixture.Ability.Ward", B.SELF, [_row("ward", "st_ward", D.USE_EFFECT, 0, T.ALL)], [[0.3, "ward"]])
	var ice_slash := _row("hit", "damage", D.SCALED, 50, T.ALL, ice)
	ice_slash.toughness_x100 = Fixed.from_typed(30)
	_ability("ice_slash", "Fixture.Ability.IceSlash", B.SINGLE_ENEMY, [ice_slash], [[0.3, "hit"]])
	_ability("ult_locked", "Fixture.Ability.UltLocked", B.SINGLE_ENEMY, [_row("hit", "damage", D.SCALED, 100, T.ALL)],
		[[0.3, "hit"]], [], null, ult.merged({"query": not_controlled}))
	_ability("ult_breakout", "Fixture.Ability.UltBreakout", B.SELF, [_row("cleanse", "st_cleanse", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "cleanse"]], [], null, ult)
	# Per-type break effects (spec content-pass D2: passives on the breaker, triggered by H4's combined events).
	_ability("break_fire", "Fixture.Ability.BreakFire", B.SINGLE_ENEMY, [_row("burst", "damage", D.FLAT, 30, T.ALL, fire),
		_row("dot", "st_burn", D.FLAT, 20, T.ALL, fire)], [[0.1, "burst"], [0.2, "dot"]], [], null,
		{"trigger": &"Event.Damage.Dealt.Break.Fire"})
	var break_freeze := _row("freeze", "st_freeze", D.USE_EFFECT, 0, T.ALL)
	break_freeze.chance_x100 = Fixed.from_typed(65)
	_ability("break_ice", "Fixture.Ability.BreakIce", B.SINGLE_ENEMY, [_row("burst", "damage", D.FLAT, 30, T.ALL, ice),
		break_freeze], [[0.1, "burst"], [0.2, "freeze"]], [], null, {"trigger": &"Event.Damage.Dealt.Break.Ice"})
	# Passives that react to the new events (H4, drain).
	_ability("overcharge", "Fixture.Ability.Overcharge", B.SELF, [_row("charge", "ult_refund", D.USE_EFFECT, 0, T.ALL)],
		[[0.0, "charge"]], [], null, {"trigger": &"Event.Ability.Used.Ultimate"})
	_ability("interrupter", "Fixture.Ability.Interrupter", B.SELF, [_row("charge", "energy_up", D.USE_EFFECT, 0, T.ALL)],
		[[0.0, "charge"]], [], null, {"trigger": &"Event.Battle.Interrupt"})
	_ability("siphon", "Fixture.Ability.Siphon", B.SELF, [_row("charge", "energy_up", D.USE_EFFECT, 0, T.ALL)],
		[[0.0, "charge"]], [], null, {"trigger": &"Event.Damage.Taken.Drained"})

	# Enemy abilities.
	var touch_freeze := _row("freeze", "st_freeze", D.USE_EFFECT, 0, T.ALL)
	touch_freeze.chance_x100 = Fixed.from_typed(50)
	_ability("frost_touch", "Fixture.Ability.FrostTouch", B.SINGLE_ENEMY, [_row("hit", "damage", D.FLAT, 50, T.ALL, ice),
		touch_freeze], [[0.3, "hit"], [0.5, "freeze"]])
	_ability("spit", "Fixture.Ability.Spit", B.SINGLE_ENEMY, [_row("hit", "damage", D.FLAT, 30, T.ALL, physical),
		_row("dot", "st_poison", D.USE_EFFECT, 0, T.ALL)], [[0.3, "hit"], [0.5, "dot"]])
	_ability("fire_bolt", "Fixture.Ability.FireBolt", B.SINGLE_ENEMY, [_row("hit", "damage", D.FLAT, 60, T.ALL, fire)],
		[[0.3, "hit"]])
	var bash := _row("hit", "damage", D.FLAT, 60, T.ALL, physical)
	bash.toughness_x100 = Fixed.from_typed(30)
	var bash_stun := _row("stun", "st_stun", D.USE_EFFECT, 0, T.ALL)
	bash_stun.chance_x100 = Fixed.from_typed(40)
	_ability("bash", "Fixture.Ability.Bash", B.SINGLE_ENEMY, [bash, bash_stun], [[0.3, "hit"], [0.5, "stun"]])
	var phase_1 := _query([])
	phase_1.ignore_tags.assign([&"State.Phase.Two"])
	var phase_2 := _query([&"State.Phase.Two"])
	phase_2.ignore_tags.assign([&"State.Phase.Three"])
	var blast_main := _row("main", "damage", D.FLAT, 80, T.PRIMARY, physical)
	blast_main.toughness_x100 = Fixed.from_typed(30)
	_ability("bleed_blast", "Fixture.Ability.BleedBlast", B.BLAST_ENEMY, [blast_main,
		_row("splash", "damage", D.FLAT, 40, T.ADJACENT, physical)], [[0.3, "main"], [0.32, "splash"]], [], null,
		{"query": phase_1})
	_ability("hex_all", "Fixture.Ability.HexAll", B.ALL_ENEMIES, [_row("hit", "damage", D.FLAT, 40, T.ALL, physical),
		_row("hex", "st_vulnerable", D.USE_EFFECT, 0, T.ALL)], [[0.3, "hit"], [0.5, "hex"]], [], null, {"query": phase_2})
	var doom_bolt := _row("hit", "damage", D.FLAT, 120, T.ALL, physical)
	doom_bolt.toughness_x100 = Fixed.from_typed(30)
	_ability("doom_bolt", "Fixture.Ability.DoomBolt", B.SINGLE_ENEMY, [doom_bolt], [[0.3, "hit"]], [], null,
		{"query": _query([&"State.Phase.Three"])})
	_ability("death_ray", "Fixture.Ability.DeathRay", B.SINGLE_ENEMY, [_row("hit", "damage", D.FLAT, 150, T.ALL, ice)],
		[[0.3, "hit"]], [], null, ult)

	# Items.
	_item("implant", [], ItemDefinition.Kind.PASSIVE, _ability_set(["siphon"], ["drain_fire_implant"]))
	_item("frostguard", [], ItemDefinition.Kind.PASSIVE, _ability_set([], ["resist_ice"]))
	_item("leech", [], ItemDefinition.Kind.PASSIVE, _ability_set([], ["drain_physical"]))
	_item("overcharge_coil", [], ItemDefinition.Kind.PASSIVE, _ability_set(["overcharge", "interrupter"], []))

	# Characters.
	var core := {"crit_rate": 0, "crit_dmg": 50, "max_mp": 100, "mp": 100, "energy": 0}
	var no_toughness := {"max_toughness": 0, "toughness": 0, "weakness_dmg": 150, "toughness_dmg": 0, "broken_dmg": 0}
	var hexer := CharacterDefinition.new()
	_fill_unit(hexer, "fixture.character.hexer", {"max_hp": 1100, "hp": 1100, "atk": 400, "def": 200, "spd": 105}.merged(core),
		no_toughness, ["hex_burn", "frost_hex", "toxic_cloud", "strike", "ult_purify",
		"full_charge", "recharge", "break_fire", "break_ice"], Color.DARK_ORCHID, STATUS_ATTRIBUTE_SET)
	hexer.tags.assign([&"Fixture.Character.Hexer"])
	_save_world("characters", "hexer", hexer)
	var guard := CharacterDefinition.new()
	_fill_unit(guard, "fixture.character.guard", {"max_hp": 1600, "hp": 1600, "atk": 300, "def": 400, "spd": 95}.merged(core),
		no_toughness, ["provoke", "strike", "rally", "entangle", "ice_slash", "ward", "break_fire", "break_ice"],
		Color.DARK_SLATE_BLUE,
		STATUS_ATTRIBUTE_SET)
	guard.tags.assign([&"Fixture.Character.Guard"])
	_save_world("characters", "guard", guard)
	var guard_weak := CharacterDefinition.new()  # weak to Physical, no toughness: knocked down, never Broken (H7)
	_fill_unit(guard_weak, "fixture.character.guard_weak", {"max_hp": 1600, "hp": 1600, "atk": 300, "def": 400,
		"spd": 95}.merged(core), no_toughness, ["provoke", "strike", "ice_slash"], Color.MIDNIGHT_BLUE, STATUS_ATTRIBUTE_SET)
	guard_weak.tags.assign([&"Fixture.Character.Guard", &"Weakness.Physical"])
	_save_world("characters", "guard_weak", guard_weak)
	var breaker := CharacterDefinition.new()
	_fill_unit(breaker, "fixture.character.breaker", {"max_hp": 1000, "hp": 1000, "atk": 400, "def": 300,
		"spd": 100}.merged(core), no_toughness, ["strike", "ult_locked", "ult_breakout", "full_charge"], Color.TEAL,
		STATUS_ATTRIBUTE_SET)
	breaker.tags.assign([&"Fixture.Character.Breaker"])
	_save_world("characters", "breaker", breaker)

	# Enemies.
	var enemy_core := {"crit_rate": 0, "crit_dmg": 50, "max_mp": 0, "mp": 0, "energy": 0}
	_status_enemy("toad", {"max_hp": 1400, "hp": 1400, "atk": 200, "def": 100, "spd": 90}, enemy_core, {"max_toughness": 30,
		"toughness": 30, "weakness_dmg": 150}, ["spit"], [&"Weakness.Fire"], null, [])
	_status_enemy("wisp", {"max_hp": 1200, "hp": 1200, "atk": 200, "def": 100, "spd": 110}, enemy_core, {"max_toughness": 30,
		"toughness": 30, "weakness_dmg": 150}, ["frost_touch"], [&"Weakness.Fire", &"Weakness.Physical"],
		null, [])
	_status_enemy("imp", {"max_hp": 1000, "hp": 1000, "atk": 250, "def": 100, "spd": 100}, enemy_core, {"max_toughness": 30,
		"toughness": 30, "weakness_dmg": 150}, ["fire_bolt"], [&"Resist.Fire", &"Weakness.Ice"], null, [])
	_status_enemy("knight", {"max_hp": 1800, "hp": 1800, "atk": 250, "def": 300, "spd": 95}, enemy_core, {"max_toughness": 60,
		"toughness": 60, "weakness_dmg": 150}, ["bash"], [&"Weakness.Ice", &"Immune.Control"], null, [])
	var drums := PatternBrain.new()
	drums.pattern.assign([&"Fixture.Ability.Claw", &"Fixture.Ability.Claw", &"Fixture.Ability.Bash"])
	_status_enemy("drummer", {"max_hp": 1000, "hp": 1000, "atk": 250, "def": 200, "spd": 100}, enemy_core, {"max_toughness": 30,
		"toughness": 30, "weakness_dmg": 150}, ["claw", "bash"], [&"Weakness.Fire"], drums, [])
	var lich_brain := TacticalBrain.new()
	lich_brain.ult_when_party_down = true
	var second := _phase_set("lich_phase_2", [&"State.Phase.Two"])
	var third := _phase_set("lich_phase_3", [&"State.Phase.Three"])
	_status_enemy("lich", {"max_hp": 2000, "hp": 2000, "atk": 300, "def": 200, "spd": 105}, enemy_core, {"max_toughness": 60,
		"toughness": 60, "weakness_dmg": 150}, ["bleed_blast", "hex_all", "doom_bolt", "death_ray", "rage_charge"],
		[&"Resist.Ice", &"Weakness.Physical", &"Enemy.Boss"], lich_brain,
		[_phase(60, second, false), _phase(25, third, true)])
	_world_encounter("status_trial", [], [["wisp", null], ["toad", null], ["imp", null]], 1)
	_world_encounter("lich_court", [], [["lich", null], ["drummer", null]], 1)
	_world_encounter("knight_one", [], [["knight", null]], 1)


## Spec skill-points 3.3: SP gain on basic attacks (a passive on Event.Ability.Used.Basic), scaled SP costs, growth of
## SP gain and max SP per level, level skills (rank II replacing rank I at level 3; an enemy's secret skill reached
## only through a slot's level bonus) and the read-only level, on FixtureSpAttributeSet. Nothing carries a pool or
## chapter tag, so floor generation and the run goldens never see it.
func _build_skill_points() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	var gain := GameplayEffect.new()
	gain.policy = GameplayEffect.DurationPolicy.INSTANT
	gain.executions.append(SP_RESTORE_SCRIPT.new())
	_save_effect("sp_gain", gain)
	_save_effect("sp_cost_25", _sp_cost(25))
	_save_effect("sp_cost_37", _sp_cost(37))
	var growth := GameplayEffect.new()
	growth.policy = GameplayEffect.DurationPolicy.INFINITE
	growth.modifiers.append(_modifier("sp_gain", GameplayEffectModifier.Operation.PERCENT_ADD, 7))
	growth.modifiers.append(_modifier("max_mp", GameplayEffectModifier.Operation.PERCENT_ADD, 7))
	_save_effect("sp_growth", growth)
	# Rank I is listed first, so the first legal move casts it whenever the SP is there: "jab, jab, burst".
	_ability("chant_burst", "Fixture.Ability.ChantBurst", B.SINGLE_ENEMY, [_row("hit", "damage", D.SCALED, 220, T.ALL,
		physical)], [[0.3, "hit"]], [], null, {"cost": _effects["sp_cost_25"]})
	_ability("chant_burst_2", "Fixture.Ability.ChantBurstTwo", B.SINGLE_ENEMY, [_row("hit", "damage", D.SCALED, 330, T.ALL,
		physical)], [[0.3, "hit"]], [], null, {"cost": _effects["sp_cost_37"]})
	_ability("chant_jab", "Fixture.Ability.ChantJab", B.SINGLE_ENEMY, [_row("hit", "damage", D.SCALED, 100, T.ALL,
		physical)], [[0.3, "hit"]], [], null, {"asset_tags": [&"Ability.Type.Basic"]})
	_ability("sp_passive", "Fixture.Ability.SpGain", B.SELF, [_row("gain", "sp_gain", D.USE_EFFECT, 0, T.ALL)],
		[[0.0, "gain"]], [], null, {"trigger": &"Event.Ability.Used.Basic"})
	_ability("secret_slam", "Fixture.Ability.SecretSlam", B.SINGLE_ENEMY, [_row("hit", "damage", D.FLAT, 90, T.ALL,
		physical)], [[0.3, "hit"]])
	var no_toughness := {"max_toughness": 0, "toughness": 0, "weakness_dmg": 150, "toughness_dmg": 0, "broken_dmg": 0}
	var chanter := CharacterDefinition.new()
	_fill_unit(chanter, "fixture.character.chanter", {"max_hp": 1200, "hp": 1200, "atk": 400, "def": 250, "spd": 105},
		{"crit_rate": 0, "crit_dmg": 50, "max_mp": 60, "mp": 60, "energy": 0, "sp_basic": 17}.merged(no_toughness),
		["chant_burst", "chant_jab", "sp_passive"], Color.ORCHID, SP_ATTRIBUTE_SET)
	chanter.tags.assign([&"Fixture.Character.Chanter"])
	chanter.level_effect = _effects["sp_growth"]
	chanter.level_skills.assign([_level_skill(3, "chant_burst_2", &"Fixture.Ability.ChantBurst")])
	_save_world("characters", "chanter", chanter)
	# A healer with a basic attack and an SP-costed heal, for the danger reserve (spec skill-points 3.4).
	_ability("hymn", "Fixture.Ability.Hymn", B.SINGLE_ALLY, [_row("heal", "heal", D.USE_EFFECT, 0, T.ALL)], [[0.3, "heal"]],
		[], null, {"cost": _effects["sp_cost_25"]})
	var cantor := CharacterDefinition.new()
	_fill_unit(cantor, "fixture.character.cantor", {"max_hp": 1100, "hp": 1100, "atk": 380, "def": 250, "spd": 110},
		{"crit_rate": 0, "crit_dmg": 50, "max_mp": 60, "mp": 60, "energy": 0, "sp_basic": 13}.merged(no_toughness),
		["chant_burst", "chant_jab", "hymn", "sp_passive"], Color.PLUM, SP_ATTRIBUTE_SET)
	cantor.tags.assign([&"Fixture.Character.Cantor"])
	_save_world("characters", "cantor", cantor)
	var keeper := EnemyDefinition.new()
	_fill_unit(keeper, "fixture.enemy.keeper", {"max_hp": 2600, "hp": 2600, "atk": 260, "def": 200, "spd": 100},
		{"crit_rate": 0, "crit_dmg": 50, "max_mp": 0, "mp": 0, "energy": 0, "max_toughness": 30, "toughness": 30,
		"weakness_dmg": 150}, ["claw"], Color.SIENNA, SP_ATTRIBUTE_SET)
	keeper.level_skills.assign([_level_skill(2, "secret_slam", &"")])
	var chant := PatternBrain.new()
	chant.pattern.assign([&"Fixture.Ability.Claw", &"Fixture.Ability.SecretSlam"])
	keeper.brain = chant
	_save_world("enemies", "keeper", keeper)
	# Two keepers: slot 1 at level 1 (no secret skill: its pattern step falls back), slot 2 one level up (it has it).
	var trial := EncounterDefinition.new()
	trial.id = &"fixture.encounter.sp_trial"
	trial.display_name = "Sp Trial"
	trial.weight_x100 = Fixed.from_typed(1)
	for bonus in [0, 1]:
		var slot := EncounterSlot.new()
		slot.enemy = _world["enemies/keeper"]
		slot.level_bonus = bonus
		trial.slots.append(slot)
	_save_world("encounters", "sp_trial", trial)


func _sp_cost(typed: float) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INSTANT
	var cost := SP_COST_SCRIPT.new()
	cost.amount_x100 = Fixed.from_typed(typed)
	effect.executions.append(cost)
	return effect


func _level_skill(level: int, ability_name: String, replaces: StringName) -> LevelSkill:
	var row := LevelSkill.new()
	row.level = level
	row.ability = _abilities[ability_name]
	row.replaces = replaces
	return row


## A turn-based status that refreshes instead of stacking (REFRESH_DURATION, max 1); callers raise max_stacks.
## Spec playable-demo 3.8 (H9, H10): a mirror boss that copies the party's held items and armor and grows per piece
## held, alone in an encounter in no pool (the mirror-seed-9 golden).
func _build_full_descent() -> void:
	_save_effect("per_item_boost", _infinite("atk", GameplayEffectModifier.Operation.PERCENT_ADD, 5))
	var mirror := EnemyDefinition.new()
	_fill_unit(mirror, "fixture.enemy.mirror", {"max_hp": 2400, "hp": 2400, "atk": 260, "def": 200, "spd": 100,
		"crit_rate": 5, "crit_dmg": 50}, {}, ["slam", "claw"], Color.GOLD)
	mirror.tags.assign([&"Enemy.Boss"])
	mirror.mirror_party_items = true
	mirror.per_item_effect = _effects["per_item_boost"]
	_save_world("enemies", "mirror", mirror)
	_world_encounter("mirror_hall", [], [["mirror", null]], 1)


## Spec keys-and-gear: chests, gear only chests give (Fixture.Pool.Crate), the run-modifier and room-reveal items, and a
## field-only and a battle-only use item. Nothing here has a chapter or a pool other than the crate's, and no run
## structure lists it (tests build their keyed run in memory, tests/game/keys_world.gd), so every other fixture run,
## floor and golden is unchanged.
func _build_keys_and_gear() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var crate_pool := [&"Fixture.Pool.Crate"]
	_armor("dagger", "Fixture.Equipment.Slot.Weapon", crate_pool, ["blade"])
	_armor("hood", "Fixture.Equipment.Slot.Head", crate_pool, ["banner"])
	_ability("field_mend", "Fixture.Ability.FieldMend", B.SINGLE_ALLY, [_row("heal", "heal", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "heal"]], [], null, {"asset_tags": [BattleAbility.USAGE_FIELD_TAG], "query": _query([&"State.Infield"])})
	_ability("battle_flask", "Fixture.Ability.BattleFlask", B.ALL_ALLIES, [_row("heal", "heal", D.USE_EFFECT, 0, T.ALL)],
		[[0.3, "heal"]], [], null, {"asset_tags": [BattleAbility.USAGE_BATTLE_TAG]})
	_item("field_tonic", [], ItemDefinition.Kind.USABLE, null,
		{"use_ability": _abilities["field_mend"], "use_mode": ItemDefinition.UseMode.COOLDOWN, "cooldown_battles": 2})
	_item("battle_tonic", [], ItemDefinition.Kind.USABLE, null,
		{"use_ability": _abilities["battle_flask"], "use_mode": ItemDefinition.UseMode.COOLDOWN, "cooldown_battles": 1})
	_item("key_fob", [RunController.KEYS_DOUBLE_TAG], ItemDefinition.Kind.PASSIVE, null)
	var two_keys := GainKeys.new()
	two_keys.amount = 2
	var on_pickup: Array[RunOutcome] = [two_keys]
	_item("warden_key", [RunController.CHEST_DOUBLE_TAG], ItemDefinition.Kind.PASSIVE, null, {"on_pickup": on_pickup})
	_item("lockpick", [RunController.CHEST_NO_KEY_TAG], ItemDefinition.Kind.PASSIVE, null)
	var reveal: Array[RunOutcome] = [RevealRooms.new()]
	_item("dowsing", [], ItemDefinition.Kind.PASSIVE, null, {"on_pickup": reveal, "on_floor_start": reveal})
	var gear := GiveEquipment.new()
	gear.query = _query(crate_pool)
	gear.prefer_open_slot = true
	var crate := ChestDefinition.new()
	crate.id = &"fixture.chest.crate"
	crate.display_name = "Crate"
	crate.description = "Fixture chest: free, one piece of crate gear."
	crate.rewards.assign([_reward([gear], 1, 1)])
	_save_world("chests", "crate", crate)
	var strongbox := ChestDefinition.new()
	strongbox.id = &"fixture.chest.strongbox"
	strongbox.display_name = "Strongbox"
	strongbox.description = "Fixture chest: a key to open, 2-3 coins."
	strongbox.needs_key = true
	strongbox.rewards.assign([_reward([_gain(1)], 2, 3)])
	_save_world("chests", "strongbox", strongbox)


func _reward(outcomes: Array, rolls_min: int, rolls_max: int) -> ChestReward:
	var reward := ChestReward.new()
	reward.outcomes.assign(outcomes)
	reward.rolls_min = rolls_min
	reward.rolls_max = rolls_max
	return reward


func _status(turns: int, granted: Array) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.TURN_BASED
	effect.duration_turns = turns
	effect.granted_tags.assign(granted)
	effect.stacking_policy = GameplayEffect.StackingPolicy.REFRESH_DURATION
	effect.max_stacks = 1
	return effect


func _granting(granted: Array) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INFINITE
	effect.granted_tags.assign(granted)
	return effect


## A boss phase's AbilitySet, saved on its own (its tags mark the phase for activation queries).
func _phase_set(name: String, tags: Array) -> AbilitySet:
	var path := ROOT + "loadouts/%s.tres" % name
	var ability_set := AbilitySet.new()
	ability_set.tags.assign(tags)
	_save(ability_set, path)
	return load(path)


func _phase(hp_below: float, ability_set: AbilitySet, clear_debuffs: bool) -> BossPhase:
	var phase := BossPhase.new()
	phase.hp_below_x100 = Fixed.from_typed(hp_below)
	phase.ability_set = ability_set
	phase.clear_debuffs = clear_debuffs
	return phase


func _status_enemy(name: String, core: Dictionary, extra: Dictionary, break_stats: Dictionary, ability_names: Array,
		tags: Array, brain: EnemyBrain, phases: Array) -> void:
	var enemy := EnemyDefinition.new()
	_fill_unit(enemy, "fixture.enemy." + name, core.merged(extra), {"toughness_dmg": 0, "broken_dmg": 0}.merged(break_stats),
		ability_names, Color.OLIVE_DRAB, STATUS_ATTRIBUTE_SET)
	enemy.tags.assign(tags)
	enemy.brain = brain
	enemy.phases.assign(phases)
	_save_world("enemies", name, enemy)


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
