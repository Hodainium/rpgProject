## One-time builder for the example set (spec game-skeleton 3.8): writes the demo content into res://content/demo/
## and the demo room and unit views into res://presentation/demo/, through ResourceSaver (exactly what the editor saves).
## The screens are no longer made here: the UI is res://presentation/demo/ui/ (spec ui-framework).
##
## It never overwrites: a file that already exists is skipped and the existing one is used, so your edits survive a
## rerun. It writes nowhere else. Values are placeholders typed as a designer would (Fixed.from_typed stores them x100).
## Needs the generated UnitAttributeSet (godot_gas "Unit" draft → Generate) first.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_demo.tscn
extends Node

const CONTENT: String = "res://content/demo/"
const SOUNDS: String = "res://presentation/audio/rtp/"
const SCREENS: String = "res://presentation/demo/"
const ALLOWED_ROOTS: Array[String] = [CONTENT, SCREENS]
const GENERATED_SET: String = "res://godot_gas/attributes/unit_attribute_set.gd"
const ATTRIBUTES: String = CONTENT + "attributes/demo_unit_attributes.gd"
const DAMAGE_CALC: String = CONTENT + "exec_calcs/exec_calc_standard_damage.gd"
const SCREEN_ROOTS: Dictionary = {"room_view_3d": "Node3D"}

var _made := PackedStringArray()
var _skipped := PackedStringArray()
var _failed := PackedStringArray()
var _r := {}  # "folder/name" -> loaded resource
var _attributes: Script


func _ready() -> void:
	if not ResourceLoader.exists(GENERATED_SET):
		_quit("No %s yet: open the GodotGAS dashboard, Attribute Sets → Unit → Generate, then run this again." % GENERATED_SET)
		return
	_attributes = load(ATTRIBUTES)
	if _attributes == null or load(DAMAGE_CALC) == null:
		_quit("Missing %s or %s (run --import once after generating)." % [ATTRIBUTES, DAMAGE_CALC])
		return
	_screens()
	_effects()
	_abilities()
	_world()
	print("build_demo: made %d, skipped %d existing, failed %d" % [_made.size(), _skipped.size(), _failed.size()])
	for path in _made:
		print("  made    ", path)
	for path in _skipped:
		print("  skipped ", path)
	for path in _failed:
		print("  FAILED  ", path)
	get_tree().quit(1 if not _failed.is_empty() else 0)


func _quit(message: String) -> void:
	push_error("build_demo: " + message)
	get_tree().quit(1)


# --- Screens (presentation/demo) -------------------------------------------------------------------------------------

func _screens() -> void:
	for screen in SCREEN_ROOTS:
		var root: Node = ClassDB.instantiate(SCREEN_ROOTS[screen])
		root.name = String(screen).to_pascal_case()
		root.set_script(load(SCREENS + screen + ".gd"))
		_pack(SCREENS + screen + ".tscn", root)
	var unit := Node3D.new()
	unit.name = "UnitView"
	var body := MeshInstance3D.new()
	body.name = "Body"
	var cube := BoxMesh.new()
	cube.size = Vector3(0.8, 0.8, 0.8)
	body.mesh = cube
	unit.add_child(body)
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	unit.add_child(player)
	var label := Label3D.new()
	label.name = "Label"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, 1.0, 0)
	label.font_size = 24
	unit.add_child(label)
	for child in unit.get_children():
		child.owner = unit
	unit.set_script(load(SCREENS + "unit_view.gd"))
	_pack(SCREENS + "unit_view.tscn", unit)


func _pack(path: String, root: Node) -> void:
	if _exists(path):
		root.free()
		return
	var scene := PackedScene.new()
	var error := scene.pack(root)
	root.free()
	if error != OK:
		_failed.append("%s (%s)" % [path, error_string(error)])
		return
	_write(path, scene)


# --- Effects ---------------------------------------------------------------------------------------------------------

func _effects() -> void:
	var damage := GameplayEffect.new()
	damage.policy = GameplayEffect.DurationPolicy.INSTANT
	damage.executions.append(load(DAMAGE_CALC).new())
	_save("effects/damage", damage)
	_save("effects/heal", _instant({"hp": 300}))           # field / battle heal: +300 HP
	_save("effects/potion_heal", _instant({"hp": 250}))    # potion: +250 HP to everyone
	_save("effects/revive", _instant({"hp": 400}))         # phoenix feather: back with 400 HP
	_save("effects/mp_cost_ice", _instant({"mp": -20}))
	_save("effects/mp_cost_heal", _instant({"mp": -25}))
	_save("effects/whetstone", _infinite({"atk": 20}, true))         # +20% ATK
	_save("effects/war_banner", _infinite({"def": 10}, true))        # +10% DEF (party)
	_save("effects/iron_sword", _infinite({"atk": 60}, false))       # +60 ATK
	_save("effects/elite", _infinite({"max_hp": 50, "atk": 10}, true)) # elite: +50% MaxHP, +10% ATK
	_save("effects/scale_depth_0", _infinite({"atk": 10}, true))
	_save("effects/scale_depth_1", _infinite({"atk": 20, "def": 10}, true))
	_save("effects/ult_charge", _instant({"energy": 25}))      # +25 ult charge per ability used in battle
	_save("effects/ult_charge_hit", _instant({"energy": 10}))  # +10 ult charge per hit taken
	_save("effects/ult_cost", _instant({"energy": -100}))      # an ult's cost: needs a full bar, empties it
	_save("effects/sanctuary_heal", _instant({"hp": 400}))


func _instant(changes: Dictionary) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INSTANT
	for attribute_name in changes:
		effect.modifiers.append(_modifier(attribute_name, GameplayEffectModifier.Operation.ADD, changes[attribute_name]))
	return effect


func _infinite(changes: Dictionary, percent: bool) -> GameplayEffect:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INFINITE
	var operation := GameplayEffectModifier.Operation.PERCENT_ADD if percent else GameplayEffectModifier.Operation.ADD
	for attribute_name in changes:
		effect.modifiers.append(_modifier(attribute_name, operation, changes[attribute_name]))
	return effect


func _modifier(attribute_name: String, operation: GameplayEffectModifier.Operation, typed: float) -> CombatModifier:
	var modifier := CombatModifier.new()
	modifier.attribute_name = attribute_name
	modifier.operation = operation
	modifier.value_x100 = Fixed.from_typed(typed)
	return modifier


# --- Abilities and their animations (jump, spin, flash on the cube's Body) ---------------------------------------------

func _abilities() -> void:
	var D := ExecutionRow.DamageMode
	var T := ExecutionRow.Targets
	var B := BattleAbility.Targeting
	var physical := [&"Damage.Type.Physical"]
	var ice := [&"Damage.Type.Ice"]
	_ability("strike", "Ability.Strike", B.SINGLE_ENEMY, [_row("hit", "damage", D.SCALED, 100, T.ALL, physical)],
		_jump(0.7), [[0.35, "hit"]], {"sound": ["Attack2", 0.1, -12.0]})
	_ability("ice_blast", "Ability.Iceblast", B.BLAST_ENEMY,
		[_row("blast", "damage", D.SCALED, 120, T.PRIMARY, ice), _row("chill", "damage", D.SCALED, 50, T.ADJACENT, ice)],
		_spin(0.8), [[0.5, "blast"], [0.55, "chill"]], {"cost": "mp_cost_ice", "sound": ["Ice1", 0.0, 16.5]})
	_ability("bite", "Ability.Bite", B.SINGLE_ENEMY, [_row("bite", "damage", D.SCALED, 100, T.ALL, physical)],
		_flash(0.5), [[0.3, "bite"]], {"sound": ["Blow2", 0.05, -13.5]})
	var crush := _jump(1.0)
	_add_spin(crush, 1.0)
	_ability("crush", "Ability.Crush", B.BLAST_ENEMY,
		[_row("crush", "damage", D.SCALED, 90, T.PRIMARY, physical), _row("quake", "damage", D.SCALED, 40, T.ADJACENT, physical)],
		crush, [[0.6, "crush"], [0.62, "quake"]], {"sound": ["Earth6", 0.3, -3.5]})
	_ability("heal", "Ability.Heal", B.SINGLE_ALLY, [_row("heal", "heal", D.USE_EFFECT, 0, T.ALL)],
		_flash(0.6), [[0.3, "heal"]], {"cost": "mp_cost_heal", "sound": ["Recovery5", 0.0, 4.5]})
	_ability("phoenix_feather", "Ability.Item.Revive", B.SINGLE_DEAD_ALLY,
		[_row("revive", "revive", D.USE_EFFECT, 0, T.ALL)], _spin(0.8), [[0.5, "revive"]], {"sound": ["Raise2", 0.0, 0.0]})
	_ability("potion", "Ability.Item.Potion", B.ALL_ALLIES, [_row("heal", "potion_heal", D.USE_EFFECT, 0, T.ALL)],
		_jump(0.5), [[0.3, "heal"]], {"sound": ["Recovery7", 0.0, 1.5]})
	_ability("frost_ember", "Ability.Passive.Frostember", B.SINGLE_ENEMY,
		[_row("burn", "damage", D.FLAT, 60, T.ALL, [&"Damage.Type.Fire"])], _flash(0.4), [[0.2, "burn"]],
		{"trigger": &"Event.Damage.Dealt.Ice", "sound": ["Fire1", 0.0, -3.5]})
	# Oath Stone (Birthright-like): one item, a different battle-start effect per holder, chosen by character tag.
	_ability("oath_warrior", "Ability.Oath.Warrior", B.SELF, [_row("oath", "whetstone", D.USE_EFFECT, 0, T.ALL)],
		_spin(0.6), [[0.3, "oath"]], {"trigger": &"Event.Battle.Start", "query": _query([&"Character.Warrior"]),
		"sound": ["Buff", 0.0, 2.0]})
	_ability("oath_cleric", "Ability.Oath.Cleric", B.ALL_ALLIES, [_row("oath", "potion_heal", D.USE_EFFECT, 0, T.ALL)],
		_flash(0.6), [[0.3, "oath"]], {"trigger": &"Event.Battle.Start", "query": _query([&"Character.Cleric"]),
		"sound": ["Holy3", 0.0, -6.5]})
	# Ults: the cost is ult charge (energy), so GAS blocks them until the bar is full and empties it on use. The
	# charge listener is a triggered passive on Event.Ability.Used (sent by the battle after each action).
	_ability("ult_charge", "Ability.Passive.Ultcharge.Action", B.SELF, [_row("charge", "ult_charge", D.USE_EFFECT, 0, T.ALL)],
		_still(0.05), [[0.0, "charge"]], {"trigger": &"Event.Ability.Used"})
	_ability("ult_charge_hit", "Ability.Passive.Ultcharge.Hit", B.SELF,
		[_row("charge", "ult_charge_hit", D.USE_EFFECT, 0, T.ALL)], _still(0.05), [[0.0, "charge"]],
		{"trigger": &"Event.Damage.Taken"})
	var cleave := _jump(1.2)
	_add_spin(cleave, 1.2)
	_ability("cleave", "Ability.Ult.Cleave", B.ALL_ENEMIES, [_row("cleave", "damage", D.SCALED, 200, T.ALL, physical)],
		cleave, [[0.7, "cleave"]], {"cost": "ult_cost", "sound": ["Explosion1", 0.5, 2.5]})
	_ability("sanctuary", "Ability.Ult.Sanctuary", B.ALL_ALLIES, [_row("bless", "sanctuary_heal", D.USE_EFFECT, 0, T.ALL)],
		_spin(1.0), [[0.6, "bless"]], {"cost": "ult_cost", "sound": ["Holy5", 0.2, -4.0]})


func _row(id: String, effect_name: String, mode: ExecutionRow.DamageMode, typed: float, targets: ExecutionRow.Targets,
		tags: Array = []) -> ExecutionRow:
	var row := ExecutionRow.new()
	row.id = StringName(id)
	row.effect = _r["effects/" + effect_name]
	row.damage_mode = mode
	row.targets = targets
	row.tags.assign(tags)
	if mode == ExecutionRow.DamageMode.FLAT:
		row.flat_damage_x100 = Fixed.from_typed(typed)
	elif mode == ExecutionRow.DamageMode.SCALED:
		row.multiplier_x100 = Fixed.from_typed(typed)
	return row


## extras: "cost": effect name, "query": GameplayTagQuery, "trigger": StringName, "asset_tags": Array (e.g.
## Ability.Type.FollowUp), "sound": [file in SOUNDS without .wav, time, volume dB] (an audio track on the cube's Audio
## node plus its volume).
func _ability(name: String, tag: String, targeting: BattleAbility.Targeting, rows: Array, animation: Animation,
		execute_keys: Array, extras: Dictionary = {}) -> void:
	var track := animation.add_track(Animation.TYPE_METHOD)
	animation.track_set_path(track, NodePath("."))
	for key in execute_keys:
		animation.track_insert_key(track, key[0], {"method": &"execute", "args": [StringName(key[1])]})
	if extras.has("sound"):
		var sound: Array = extras["sound"]
		var audio := animation.add_track(Animation.TYPE_AUDIO)
		animation.track_set_path(audio, NodePath("Audio"))
		animation.audio_track_insert_key(audio, sound[1], load(SOUNDS + sound[0] + ".wav"))
		var level := animation.add_track(Animation.TYPE_VALUE)
		animation.track_set_path(level, NodePath("Audio:volume_db"))
		animation.value_track_set_update_mode(level, Animation.UPDATE_DISCRETE)
		animation.track_insert_key(level, 0.0, float(sound[2]))
	animation.resource_name = name
	_save("animations/" + name, animation)
	var path := CONTENT + "abilities/%s.tscn" % name
	if not _exists(path):
		var ability := BattleAbility.new()
		ability.name = name.to_pascal_case()
		ability.ability_tag = StringName(tag)
		ability.targeting = targeting
		var typed_rows: Array[ExecutionRow] = []
		typed_rows.assign(rows)
		ability.executions = typed_rows
		ability.animation = _r["animations/" + name]
		ability.cost_effect = _r["effects/" + extras["cost"]] if extras.has("cost") else null
		ability.activation_query = extras.get("query")
		ability.trigger_event_tag = extras.get("trigger", &"")
		ability.asset_tags.assign(extras.get("asset_tags", []))
		_pack(path, ability)
	_r["abilities/" + name] = load(path)


func _jump(length: float) -> Animation:
	var animation := Animation.new()
	animation.length = length
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath("Body:position"))
	animation.track_insert_key(track, 0.0, Vector3.ZERO)
	animation.track_insert_key(track, length * 0.4, Vector3(0, 1.2, 0))
	animation.track_insert_key(track, length * 0.8, Vector3.ZERO)
	return animation


## Holds the cube still (a Body key, so the view doesn't add its default hop): for quiet triggered passives.
func _still(length: float) -> Animation:
	var animation := Animation.new()
	animation.length = length
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath("Body:visible"))
	animation.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
	animation.track_insert_key(track, 0.0, true)
	return animation


func _spin(length: float) -> Animation:
	var animation := Animation.new()
	animation.length = length
	_add_spin(animation, length)
	return animation


func _add_spin(animation: Animation, length: float) -> void:
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath("Body:rotation"))
	animation.track_insert_key(track, 0.0, Vector3.ZERO)
	animation.track_insert_key(track, length * 0.8, Vector3(0, TAU, 0))


func _flash(length: float) -> Animation:
	var animation := Animation.new()
	animation.length = length
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath("Body:visible"))
	animation.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
	for step in 6:
		animation.track_insert_key(track, length * step / 6.0, step % 2 == 0)
	animation.track_insert_key(track, length, true)
	return animation


# --- World: items, units, encounters, events, rooms, chapter, run ------------------------------------------------------

func _world() -> void:
	var sword := EquipmentDefinition.new()
	sword.id = &"demo.equipment.iron_sword"
	sword.display_name = "Iron Sword"
	sword.slot = &"Equipment.Slot.Weapon"
	sword.grants = _ability_set([], ["iron_sword"])
	_save("equipment/iron_sword", sword)

	var common := &"Item.Rarity.Common"
	var rare := &"Item.Rarity.Rare"
	_item("stale_bread", "Stale Bread", [common], 1, null)  # the run's fallback item: does nothing
	_item("whetstone", "Whetstone", [&"Pool.Treasure", common], 6, _ability_set([], ["whetstone"]))
	_item("war_banner", "War Banner", [&"Pool.Treasure", &"Pool.Shop", rare], 8, _ability_set([], ["war_banner"]),
		{"applies_to": ItemDefinition.AppliesTo.PARTY})
	_item("frost_ember_charm", "Frost-Ember Charm", [&"Pool.Treasure", rare], 8, _ability_set(["frost_ember"], []))
	_item("phoenix_feather", "Phoenix Feather", [&"Pool.Shop", rare], 5, null,
		{"kind": ItemDefinition.Kind.USABLE, "use_ability": _r["abilities/phoenix_feather"],
		"use_mode": ItemDefinition.UseMode.CONSUMABLE})
	_item("potion", "Potion", [&"Pool.Shop", common], 4, null,
		{"kind": ItemDefinition.Kind.USABLE, "use_ability": _r["abilities/potion"],
		"use_mode": ItemDefinition.UseMode.COOLDOWN, "cooldown_battles": 2})
	_item("satchel", "Satchel", [&"Pool.Treasure", &"Pool.Boss", common], 6, null, {"extra_use_slots": 1})

	var hardened := Loadout.new()
	hardened.id = &"demo.loadout.hardened"
	hardened.stats_x100.assign({"def": Fixed.from_typed(400)})
	_save("loadouts/hardened", hardened)
	var elite := EnemyVariant.new()
	elite.id = &"demo.variant.elite"
	elite.display_name = "Elite"
	elite.display_color = Color.GOLD
	elite.coin_bonus = 2
	elite.grants = _ability_set([], ["elite"])
	_save("variants/elite", elite)

	var warrior_kit := Loadout.new()  # inline: Isaac-style starting kit, seeds the run state once
	warrior_kit.skills.assign([_r["abilities/ice_blast"]])
	warrior_kit.items.assign([_r["items/phoenix_feather"]])
	warrior_kit.equipment.assign([_r["equipment/iron_sword"]])
	_character("warrior", "Warrior", Color.STEEL_BLUE, {"max_hp": 1000, "hp": 1000, "max_mp": 60, "mp": 60,
		"atk": 500, "def": 300, "spd": 100, "crit_rate": 5, "crit_dmg": 50, "energy": 0, "toughness": 300},
		["cleave", "strike", "ult_charge", "ult_charge_hit"], ["ice_blast"], warrior_kit)
	var cleric_kit := Loadout.new()
	cleric_kit.items.assign([_r["items/potion"]])
	_character("cleric", "Cleric", Color.SEA_GREEN, {"max_hp": 800, "hp": 800, "max_mp": 100, "mp": 100, "atk": 350,
		"def": 250, "spd": 110, "crit_rate": 5, "crit_dmg": 50, "energy": 0, "toughness": 300}, ["sanctuary", "strike", "heal", "ult_charge", "ult_charge_hit"], [], cleric_kit)
	_item("oath_stone", "Oath Stone", [&"Pool.Treasure", rare], 7, _ability_set(["oath_warrior", "oath_cleric"], []))

	var standard := {"crit_rate": 5, "crit_dmg": 50, "toughness": 300}
	_enemy("slime", "Slime", Color.LIME_GREEN, {"max_hp": 400, "hp": 400, "atk": 200, "def": 100, "spd": 90}, standard,
		["bite"], [&"Enemy.Type.Slime"], _r["loadouts/hardened"], true)
	_enemy("bat", "Bat", Color.MEDIUM_PURPLE, {"max_hp": 250, "hp": 250, "atk": 260, "def": 50, "spd": 130}, standard,
		["bite"], [&"Enemy.Type.Bat"], null, true)
	_enemy("golem", "Golem", Color.SADDLE_BROWN, {"max_hp": 2000, "hp": 2000, "atk": 320, "def": 300, "spd": 80}, standard,
		["crush", "bite"], [&"Enemy.Boss", &"Enemy.Type.Golem"], null, false)

	var angry := Loadout.new()  # inline override on an encounter slot
	angry.stats_x100.assign({"atk": Fixed.from_typed(300)})
	var demo := [&"Chapter.Demo"]
	_encounter("slime_pair", "Slime pair", demo, [["slime", null], ["slime", angry]])
	_encounter("bat_swarm", "Bat swarm", demo, [["bat", null], ["bat", null], ["bat", null]])
	_encounter("mixed", "Slime and bat", demo, [["slime", null], ["bat", null]])
	_encounter("golem", "The Golem", [&"Encounter.Boss", &"Chapter.Demo"], [["golem", null]])

	_events()
	_rooms()

	var rules := FloorGenRules.new()
	rules.id = &"demo.rules.small"
	rules.base_rooms = 5
	rules.rooms_per_depth = 1
	rules.random_extra_rooms = 1
	rules.max_rooms = 8
	rules.special_room_tags.assign([&"Room.Type.Treasure", &"Room.Type.Shop"])
	_save("floor_rules/small", rules)
	var scaling := ScalingRules.new()
	scaling.id = &"demo.scaling.basic"
	scaling.enemy_effects_by_depth.assign([_r["effects/scale_depth_0"], _r["effects/scale_depth_1"]])
	scaling.elite_chance_x100 = Fixed.from_typed(20)
	scaling.coin_drop_chance_x100 = Fixed.from_typed(80)
	scaling.coin_drop_min = 1
	scaling.coin_drop_max = 3
	_save("scaling/basic", scaling)
	var chapter := ChapterDefinition.new()
	chapter.id = &"demo.chapter.cellar"
	chapter.display_name = "The Cellar"
	chapter.tags.assign(demo)
	chapter.room_query = _query([&"Chapter.Demo"])
	chapter.encounter_query = _query([&"Chapter.Demo"], [&"Encounter.Boss"])
	chapter.boss_encounter_query = _query([&"Encounter.Boss", &"Chapter.Demo"])
	chapter.event_query = _query([&"Event.Demo"])
	chapter.floor_gen_rules = _r["floor_rules/small"]
	chapter.scaling = _r["scaling/basic"]
	_save("chapters/cellar", chapter)
	var run := RunStructure.new()
	run.id = &"demo.run.one_floor"
	run.display_name = "Demo run"
	run.fallback_item = _r["items/stale_bread"]
	var floor_slot := FloorSlot.new()
	floor_slot.chapters.assign([_r["chapters/cellar"]])
	run.floors.assign([floor_slot])
	_save("runs/one_floor", run)


func _events() -> void:
	var pray := ApplyPartyEffect.new()
	pray.effect = _r["effects/heal"]
	var shrine := EventDefinition.new()
	shrine.id = &"demo.event.shrine"
	shrine.display_name = "Old shrine"
	shrine.tags.assign([&"Event.Demo"])
	shrine.pages.assign([_page("A cracked shrine hums softly.", [_choice("Pray (heal 300 HP)", [], [pray]),
		_choice("Leave", [], [])])])
	_save("events/shrine", shrine)

	var afford := CoinsAtLeast.new()
	afford.amount = 5
	var pay := LoseCoins.new()
	pay.amount = 5
	var gift := GiveItem.new()
	gift.item_query = _query([&"Pool.Treasure"])
	var thanks := GoToPage.new()
	thanks.page = 1
	var rob := StartEncounter.new()
	rob.encounter = _r["encounters/mixed"]
	var merchant := EventDefinition.new()
	merchant.id = &"demo.event.merchant"
	merchant.display_name = "Shady merchant"
	merchant.tags.assign([&"Event.Demo"])
	merchant.pages.assign([
		_page("A hooded figure offers a trinket for 5 coins.", [_choice("Pay 5 coins", [afford], [pay, gift, thanks]),
			_choice("Rob him", [], [rob]), _choice("Walk away", [], [])]),
		_page("He pockets the coins and vanishes.", [_choice("Continue", [], [])]),
	])
	_save("events/merchant", merchant)


func _rooms() -> void:
	var P := RoomPlacement.Kind
	var M := RoomDefinition.ContentMode
	var demo := [&"Chapter.Demo"]
	var players := [_placement(Vector2i(2, 2), P.PLAYER_SPAWN, 1), _placement(Vector2i(2, 4), P.PLAYER_SPAWN, 2),
		_placement(Vector2i(1, 1), P.PLAYER_SPAWN, 3), _placement(Vector2i(1, 5), P.PLAYER_SPAWN, 4)]
	var enemies := [_placement(Vector2i(10, 3), P.ENEMY_SPAWN, 1), _placement(Vector2i(10, 1), P.ENEMY_SPAWN, 2),
		_placement(Vector2i(10, 5), P.ENEMY_SPAWN, 3)]
	var all_doors := RoomDefinition.DOOR_N | RoomDefinition.DOOR_E | RoomDefinition.DOOR_S | RoomDefinition.DOOR_W
	_room("start", "Entrance", [&"Room.Type.Start"] + demo, all_doors, M.NONE, players)
	_room("arena", "Arena", [&"Room.Type.Normal"] + demo, all_doors, M.ENCOUNTER_QUERY, players + enemies)
	var guard := _placement(Vector2i(10, 3), P.ENEMY_SPAWN, 1)
	var bulky := Loadout.new()  # inline override on a room placement
	bulky.stats_x100.assign({"max_hp": Fixed.from_typed(600), "hp": Fixed.from_typed(600)})
	guard.loadout = bulky
	_room("hall", "Long hall", [&"Room.Type.Normal"] + demo, RoomDefinition.DOOR_N | RoomDefinition.DOOR_S,
		M.ENCOUNTER_QUERY, players + [guard] + enemies.slice(1))
	_room("corridor", "Corridor", [&"Room.Type.Normal"] + demo, RoomDefinition.DOOR_E | RoomDefinition.DOOR_W,
		M.ENCOUNTER_QUERY, players + enemies)
	_room("nook", "Quiet nook", [&"Room.Type.Normal"] + demo, all_doors, M.EVENT_QUERY,
		players + [_placement(Vector2i(6, 3), P.EVENT_PROP, 1)])
	var pedestal := _placement(Vector2i(6, 3), P.ITEM_PEDESTAL, 1)
	pedestal.item_query = _query([&"Pool.Treasure"])
	_room("treasure", "Treasure room", [&"Room.Type.Treasure"] + demo, all_doors, M.NONE, players + [pedestal])
	var stock := []
	for cell in [Vector2i(5, 3), Vector2i(7, 3)]:
		var slot := _placement(cell, P.SHOP_SLOT, 1)
		slot.item_query = _query([&"Pool.Shop"])
		stock.append(slot)
	_room("shop", "Shop", [&"Room.Type.Shop"] + demo, all_doors, M.NONE, players + stock)
	_room("boss", "Golem's den", [&"Room.Type.Boss"] + demo, all_doors, M.ENCOUNTER_QUERY, players + enemies)


# --- Small builders ------------------------------------------------------------------------------------------------

func _ability_set(ability_names: Array, effect_names: Array) -> AbilitySet:
	var ability_set := AbilitySet.new()
	for name in ability_names:
		ability_set.abilities.append(_r["abilities/" + name])
	for name in effect_names:
		ability_set.effects.append(_r["effects/" + name])
	return ability_set


func _item(name: String, title: String, tags: Array, price: int, grants: AbilitySet, extra: Dictionary = {}) -> void:
	var item := ItemDefinition.new()
	item.id = StringName("demo.item." + name)
	item.display_name = title
	item.tags.assign(tags)
	item.price = price
	item.grants = grants
	for key in extra:
		item.set(key, extra[key])
	_save("items/" + name, item)


func _stats(unit: UnitDefinition, typed: Dictionary) -> void:
	var stats: Dictionary[String, int] = {}
	for attribute_name in typed:
		stats[attribute_name] = Fixed.from_typed(float(typed[attribute_name]))
	unit.stats_x100 = stats


func _character(name: String, title: String, color: Color, stats: Dictionary, abilities: Array, learnable: Array,
		loadout: Loadout) -> CharacterDefinition:
	var character := CharacterDefinition.new()
	character.id = StringName("demo.character." + name)
	character.display_name = title
	character.display_color = color
	character.attribute_set = _attributes
	_stats(character, stats)
	for ability in abilities:
		character.abilities.append(_r["abilities/" + ability])
	for ability in learnable:
		character.learnable_skills.append(_r["abilities/" + ability])
	character.default_loadout = loadout
	character.tags.assign([StringName("Character." + name.capitalize())])
	return _save("characters/" + name, character) as CharacterDefinition


func _enemy(name: String, title: String, color: Color, core: Dictionary, extra: Dictionary, abilities: Array, tags: Array,
		loadout: Loadout, can_be_elite: bool) -> void:
	var enemy := EnemyDefinition.new()
	enemy.id = StringName("demo.enemy." + name)
	enemy.display_name = title
	enemy.display_color = color
	enemy.attribute_set = _attributes
	_stats(enemy, core.merged(extra))
	for ability in abilities:
		enemy.abilities.append(_r["abilities/" + ability])
	enemy.tags.assign(tags)
	enemy.default_loadout = loadout
	if can_be_elite:
		enemy.variants.assign([_r["variants/elite"]])
	_save("enemies/" + name, enemy)


func _encounter(name: String, title: String, tags: Array, slot_specs: Array) -> void:
	var encounter := EncounterDefinition.new()
	encounter.id = StringName("demo.encounter." + name)
	encounter.display_name = title
	encounter.tags.assign(tags)
	for spec in slot_specs:
		var slot := EncounterSlot.new()
		slot.enemy = _r["enemies/" + spec[0]]
		slot.loadout = spec[1]
		encounter.slots.append(slot)
	_save("encounters/" + name, encounter)


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


func _room(name: String, title: String, tags: Array, doors: int, mode: RoomDefinition.ContentMode, placements: Array) -> void:
	var room := RoomDefinition.new()
	room.id = StringName("demo.room." + name)
	room.display_name = title
	room.tags.assign(tags)
	room.doors = doors
	room.content_mode = mode
	room.placements.assign(placements)
	_save("rooms/" + name, room)


func _placement(cell: Vector2i, kind: RoomPlacement.Kind, slot: int) -> RoomPlacement:
	var placement := RoomPlacement.new()
	placement.cell = cell
	placement.kind = kind
	placement.slot = slot
	return placement


func _query(require_all: Array, ignore: Array = []) -> GameplayTagQuery:
	var query := GameplayTagQuery.new()
	query.require_all_tags.assign(require_all)
	query.ignore_tags.assign(ignore)
	return query


# --- Writing (never overwrites, never outside the two demo folders) ----------------------------------------------------

## Saves content/demo/<key>.tres unless it exists; either way _r[key] is the file's resource.
func _save(key: String, resource: Resource) -> Resource:
	var path := CONTENT + key + ".tres"
	if not _exists(path):
		_write(path, resource)
	_r[key] = load(path)
	return _r[key]


func _exists(path: String) -> bool:
	if FileAccess.file_exists(path):
		_skipped.append(path)
		return true
	return false


func _write(path: String, resource: Resource) -> void:
	if not ALLOWED_ROOTS.any(func(root): return path.begins_with(root)) or path.contains(".."):
		_failed.append("%s (outside content/demo and presentation/demo)" % path)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var error := ResourceSaver.save(resource, path)
	if error != OK:
		_failed.append("%s (%s)" % [path, error_string(error)])
	else:
		_made.append(path)
