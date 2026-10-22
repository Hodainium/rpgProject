## Content validator (spec dev-tools 3.7): broken references, empty pools, unsatisfiable doors, bad placements, layouts,
## events and items. Pure: reads a ContentIndex, writes nothing. Never checks balance, so tuning can't fail it.
##   ContentValidator.validate(content, {"generate_seeds": 20})  → every issue, errors first
##   ContentValidator.check_room(room, content)                  → the room grid's live check
class_name ContentValidator
extends RefCounted

const SETTINGS := preload("res://addons/GodotGAS/utilities/project_settings.gd")
const TAG_HINT: String = "gas::tag"
## Tag prefix reserved for dev decisions in battle logs (spec dev-tools 3.6).
const RESERVED_TAG_PREFIX: String = "Dev."
const SINGLE_DOOR_MASKS: Array[int] = [1, 2, 4, 8]
## Spec item-pass 3.5: a trigger in one of the battle's event families must be an event the battle sends (typos such as
## Event.Damage.Delt never fire). Other triggers (e.g. an effect's own event_tags) aren't checked.
const BATTLE_EVENT_PREFIXES: Array[String] = ["Event.Damage.", "Event.Unit.", "Event.Battle.", "Event.Turn.",
	"Event.Ability.", "Event.Attack."]

var content: ContentIndex
var issues: Array[ValidationIssue] = []
var _visited: Dictionary = {}
var _known_events: Dictionary = {}
var _triggers: Dictionary = {}  # PackedScene -> trigger_event_tag
var _ults: Dictionary = {}  # PackedScene -> true when the ability is tagged Ability.Type.Ultimate


func _init(content_index: ContentIndex) -> void:
	content = content_index


## Every issue in the content root. options: {"generate_seeds": int (0 = skip generation), "tags": bool (default true)}.
static func validate(content_index: ContentIndex, options: Dictionary = {}) -> Array[ValidationIssue]:
	var validator := ContentValidator.new(content_index)
	validator._check_index()
	for id in _sorted(content_index.units):
		validator._check_unit(content_index.units[id])
	for id in _sorted(content_index.loadouts):
		validator._check_loadout(content_index.loadouts[id], null)
	for id in _sorted(content_index.encounters):
		validator._check_encounter(content_index.encounters[id])
	for id in _sorted(content_index.rooms):
		validator._check_room(content_index.rooms[id])
	for id in _sorted(content_index.chapters):
		validator._check_chapter(content_index.chapters[id])
	for id in _sorted(content_index.items):
		validator._check_item(content_index.items[id])
	for id in _sorted(content_index.equipment):
		validator._check_equipment(content_index.equipment[id])
	for id in _sorted(content_index.events):
		validator._check_event(content_index.events[id])
	for id in _sorted(content_index.layouts):
		validator._check_layout(content_index.layouts[id])
	for id in _sorted(content_index.runs):
		validator._check_run(content_index.runs[id], int(options.get("generate_seeds", 0)))
	if options.get("tags", true):
		validator._check_tags()
	return validator._sorted_issues()


## The checks the room grid shows live (content may be null: then references aren't resolved).
static func check_room(room: RoomDefinition, content_index: ContentIndex) -> Array[ValidationIssue]:
	var validator := ContentValidator.new(content_index)
	validator._check_room(room)
	return validator._sorted_issues()


static func check_layout(layout: FloorLayout, content_index: ContentIndex) -> Array[ValidationIssue]:
	var validator := ContentValidator.new(content_index)
	validator._check_layout(layout)
	return validator._sorted_issues()


static func error_count(found: Array[ValidationIssue]) -> int:
	return found.filter(func(issue: ValidationIssue) -> bool: return issue.is_error()).size()


## One line per issue, errors first.
static func report(found: Array[ValidationIssue]) -> String:
	var lines := PackedStringArray(["%d error(s), %d warning(s)" % [error_count(found), found.size() - error_count(found)]])
	for issue in found:
		lines.append("  " + str(issue))
	return "\n".join(lines)


# --- Checks ----------------------------------------------------------------------------------------------------------

func _check_index() -> void:
	for problem in content.problems:
		if problem.contains(" has no id"):
			_error("missing_id", content.root, problem)
		else:
			_error("content_index", content.root, problem)


func _check_unit(unit: UnitDefinition) -> void:
	var path := unit.resource_path
	if unit.attribute_set == null:
		_error("dangling_ref", path + "::attribute_set", "%s has no attribute_set" % unit.id)
	if unit.abilities.is_empty():
		_warning("incomplete", path + "::abilities", "%s has no abilities yet" % unit.id)
	for index in unit.abilities.size():
		_check_skill_scene(unit.abilities[index], "%s::abilities[%d]" % [path, index], unit.id)
	if unit is CharacterDefinition:
		for index in unit.learnable_skills.size():
			_check_skill_scene(unit.learnable_skills[index], "%s::learnable_skills[%d]" % [path, index], unit.id)
	if unit is EnemyDefinition:
		for index in unit.variants.size():
			if unit.variants[index] == null:
				_error("dangling_ref", "%s::variants[%d]" % [path, index], "%s has an empty variant entry" % unit.id)
	if unit.default_loadout != null and _is_inline(unit.default_loadout):
		_check_loadout(unit.default_loadout, unit)
	elif unit.default_loadout != null and unit is CharacterDefinition:
		_check_loadout_skills(unit.default_loadout, unit, path + "::default_loadout")
	if unit is EnemyDefinition:
		_check_enemy_charge(unit)
	_check_view(unit)


## Spec ult-interrupts: an enemy with an ult needs something that charges it (a triggered passive on the enemy or in
## its default loadout), or its ult never fires. A warning: content may charge it some other way.
func _check_enemy_charge(enemy: EnemyDefinition) -> void:
	var scenes: Array = enemy.abilities.duplicate()
	if enemy.default_loadout != null:
		scenes.append_array(enemy.default_loadout.skills)
		for item in enemy.default_loadout.items:
			if item != null and item.grants != null:
				scenes.append_array(item.grants.abilities)
	scenes = scenes.filter(func(scene) -> bool: return scene != null and SkillTags.tag_of(scene) != &"")
	if scenes.any(func(scene) -> bool: return _is_ult(scene)) \
			and not scenes.any(func(scene) -> bool: return _trigger_of(scene) != &""):
		_warning("ult_no_charge", enemy.resource_path, "%s has an ult but no triggered passive to charge it" % enemy.id)


## Spec animation-sets: the unit's view scene, its animation set and its abilities' tracks against the view. Warnings
## only: a look can't break a run. Units without a view use the game's default (the demo cube) and are skipped.
func _check_view(unit: UnitDefinition) -> void:
	if unit.view == "":
		return
	var where := unit.resource_path + "::view"
	var scene: PackedScene = load(unit.view) as PackedScene if ResourceLoader.exists(unit.view) else null
	if scene == null:
		_warning("view_missing", where, "%s's view %s is not a scene; the default view is used" % [unit.id, unit.view])
		return
	var root := scene.instantiate()
	if not root is UnitAnimator:
		_warning("view_missing", where, "%s's view %s has no UnitAnimator root; the default view is used" % [unit.id, unit.view])
		root.free()
		return
	_check_animation_set((root as UnitAnimator).animation_set, unit.view + "::animation_set")
	for index in unit.abilities.size():
		var ability := unit.abilities[index].instantiate() as BattleAbility if unit.abilities[index] != null else null
		if ability == null:
			continue
		if ability.animation != null:
			for track in ability.animation.get_track_count():
				var names := NodePath(ability.animation.track_get_path(track).get_concatenated_names())
				if ability.animation.track_get_type(track) != Animation.TYPE_METHOD and not names.is_empty() \
						and root.get_node_or_null(names) == null:
					_warning("ability_montage_path", "%s::abilities[%d]" % [unit.resource_path, index],
						"%s's animation moves %s, which %s doesn't have" % [ability.ability_tag, names, unit.view])
					break
		ability.free()
	root.free()


func _check_animation_set(animation_set: UnitAnimationSet, where: String) -> void:
	if animation_set == null or _visited.has(animation_set):
		return
	_visited[animation_set] = true
	for slot in UnitAnimationSet.LOOPING:
		var animation := animation_set.animation_for(slot)
		if animation != null and animation.loop_mode == Animation.LOOP_NONE:
			_warning("animation_set_loop", where, "%s's %s doesn't loop (it plays until something else happens)" % [animation_set.resource_path, slot])
	if animation_set.skeleton_profile != null:
		for slot in animation_set.own_slots():
			var animation: Animation = animation_set.get(slot)
			for track in animation.get_track_count():
				if not String(animation.track_get_path(track)).begins_with("%GeneralSkeleton"):
					_warning("animation_set_profile", where, "%s's %s has a track outside %%GeneralSkeleton (%s) but the set uses a skeleton profile" % [animation_set.resource_path, slot, animation.track_get_path(track)])
					break


func _check_skill_scene(scene: PackedScene, path: String, owner: StringName) -> void:
	if scene == null:
		_error("dangling_ref", path, "%s has an empty ability entry" % owner)
	elif SkillTags.tag_of(scene) == &"":
		_error("bad_skill", path, "%s is not a BattleAbility scene" % scene.resource_path)
	else:
		var trigger := _trigger_of(scene)
		if BATTLE_EVENT_PREFIXES.any(func(prefix: String) -> bool: return String(trigger).begins_with(prefix)) \
				and not _battle_events().has(trigger):
			_warning("trigger_unregistered", path, "%s triggers on %s, which the battle never sends" % [scene.resource_path, trigger])
		_check_ult(scene, path)


## Spec ult-interrupts: an ult (asset tag Ability.Type.Ultimate) is cast out of turn, so it can't be a triggered
## passive, and without a cost (ult charge) it could fire at every window.
func _check_ult(scene: PackedScene, path: String) -> void:
	if _visited.has(scene) or not _is_ult(scene, true):
		return
	_visited[scene] = true
	var ability := scene.instantiate() as BattleAbility
	if ability.is_triggered():
		_error("ult_triggered", path, "%s is tagged %s but is a triggered passive" % [scene.resource_path, BattleAbility.ULTIMATE_TAG])
	elif ability.cost_effect == null:
		_warning("ult_no_cost", path, "%s is an ult without a cost effect: it would fire at every ult window" % scene.resource_path)
	ability.free()


func _trigger_of(scene: PackedScene) -> StringName:
	if not _triggers.has(scene):
		var ability := scene.instantiate() as BattleAbility
		_triggers[scene] = ability.trigger_event_tag if ability != null else &""
		_ults[scene] = ability != null and ability.asset_tags.has(BattleAbility.ULTIMATE_TAG)
		if ability != null:
			ability.free()
	return _triggers[scene]


## True when the scene's ability carries Ability.Type.Ultimate (`tagged_only`: even when it is a triggered passive).
func _is_ult(scene: PackedScene, tagged_only: bool = false) -> bool:
	_trigger_of(scene)
	return _ults[scene] and (tagged_only or _triggers[scene] == &"")


## Every event the battle can send: its fixed events, plus Event.Damage.Dealt/Taken.<X> for each Damage.Type.<X> and
## Hit.<X> in the tag registry (and the hit tags the battle injects itself).
func _battle_events() -> Dictionary:
	if not _known_events.is_empty():
		return _known_events
	for tag in [Battle.EVENT_BATTLE_START, Battle.EVENT_TURN_START, Battle.EVENT_TURN_END, Battle.EVENT_DAMAGE_DEALT,
			Battle.EVENT_DAMAGE_TAKEN, Battle.EVENT_UNIT_DIED, Battle.EVENT_ABILITY_USED, Battle.EVENT_ATTACK_FOLLOW_UP,
			Battle.EVENT_UNIT_KILLED, Battle.EVENT_ONE_MORE]:
		_known_events[tag] = true
	var kinds: Array = [Battle.HIT_BREAK, Battle.HIT_FOLLOW_UP]
	var registry: GameplayTagRegistry = load(SETTINGS.get_registry_tag_path())
	if registry != null:
		kinds.append_array(registry.tags)
	for tag in kinds:
		for prefix in [Battle.DAMAGE_TYPE_PREFIX, Battle.HIT_TAG_PREFIX]:
			if String(tag).begins_with(prefix):
				var suffix := String(tag).trim_prefix(prefix)
				_known_events[StringName("%s.%s" % [Battle.EVENT_DAMAGE_DEALT, suffix])] = true
				_known_events[StringName("%s.%s" % [Battle.EVENT_DAMAGE_TAKEN, suffix])] = true
	return _known_events


## A loadout (a saved file, or inline on `unit`).
func _check_loadout(loadout: Loadout, unit: UnitDefinition) -> void:
	var path := loadout.resource_path if not _is_inline(loadout) else unit.resource_path + "::default_loadout"
	for index in loadout.skills.size():
		_check_skill_scene(loadout.skills[index], "%s::skills[%d]" % [path, index], loadout.id)
	for index in loadout.items.size():
		if loadout.items[index] == null:
			_error("dangling_ref", "%s::items[%d]" % [path, index], "an empty item entry")
	for index in loadout.equipment.size():
		if loadout.equipment[index] == null:
			_error("dangling_ref", "%s::equipment[%d]" % [path, index], "an empty equipment entry")
	if unit is CharacterDefinition:
		_check_loadout_skills(loadout, unit, path)


func _check_loadout_skills(loadout: Loadout, character: CharacterDefinition, path: String) -> void:
	for index in loadout.skills.size():
		var tag := SkillTags.tag_of(loadout.skills[index])
		if tag != &"" and character.skill_scene(tag) == null:
			_error("bad_skill", "%s::skills[%d]" % [path, index],
				"%s's loadout gives %s, which is not in its abilities or learnable_skills" % [character.id, tag])


func _check_encounter(encounter: EncounterDefinition) -> void:
	var path := encounter.resource_path
	if encounter.slots.is_empty():
		_warning("incomplete", path + "::slots", "%s has no enemies yet" % encounter.id)
	for index in encounter.slots.size():
		var slot: EncounterSlot = encounter.slots[index]
		var where := "%s::slots[%d]" % [path, index]
		if slot == null or slot.enemy == null:
			_error("dangling_ref", where, "slot %d of %s has no enemy" % [index + 1, encounter.id])
			continue
		_check_loadout_ref(slot.loadout, encounter.id, str(index + 1), where + ".loadout")
	_check_weight(encounter, path)


func _check_loadout_ref(loadout: Loadout, owner_id: StringName, number: String, where: String) -> void:
	if loadout == null or content == null:
		return
	var ref := ContentIndex.loadout_ref(loadout, owner_id, number)
	if content.resolve_loadout(ref) == null:
		_error("bad_loadout_ref", where, "loadout ref '%s' does not resolve (is the loadout file under %s?)" % [ref, content.root])


func _check_room(room: RoomDefinition) -> void:
	var path := room.resource_path if room.resource_path != "" else "room " + String(room.id)
	if room.id == &"":
		_error("missing_id", path, "the room has no id")
	if room.min_doors > RoomDefinition.door_count(room.doors):
		_error("doors_unsatisfiable", path + "::min_doors",
			"%s needs %d doors but has %d" % [room.id, room.min_doors, RoomDefinition.door_count(room.doors)])
	match room.content_mode:
		RoomDefinition.ContentMode.ENCOUNTER:
			if room.encounter == null:
				_error("dangling_ref", path + "::encounter", "%s is an encounter room without an encounter" % room.id)
		RoomDefinition.ContentMode.EVENT:
			if room.event == null:
				_error("dangling_ref", path + "::event", "%s is an event room without an event" % room.id)
		RoomDefinition.ContentMode.ENCOUNTER_QUERY:
			if room.content_query != null and content != null:
				_check_pool(content.encounters, room.content_query, path + "::content_query", "encounter")
		RoomDefinition.ContentMode.EVENT_QUERY:
			if room.content_query != null and content != null:
				_check_pool(content.events, room.content_query, path + "::content_query", "event")
	var used_cells := {}
	var enemy_spawns := 0
	var player_spawns := 0
	for index in room.placements.size():
		var placement: RoomPlacement = room.placements[index]
		var where := "%s::placements[%d]" % [path, index]
		if placement == null:
			_error("dangling_ref", where, "an empty placement entry")
			continue
		if placement.cell.x < 0 or placement.cell.y < 0 or placement.cell.x >= RoomDefinition.GRID.x \
				or placement.cell.y >= RoomDefinition.GRID.y:
			_error("placement_outside", where, "cell %s is outside the %s room grid" % [placement.cell, RoomDefinition.GRID])
		if used_cells.has(placement.cell):
			_error("placement_overlap", where, "cell %s is already used by placement %d" % [placement.cell, used_cells[placement.cell]])
		else:
			used_cells[placement.cell] = index
		var K := RoomPlacement.Kind
		match placement.kind:
			RoomPlacement.Kind.ENEMY_SPAWN:
				enemy_spawns += 1
				_check_loadout_ref(placement.loadout, room.id, str(index + 1), where + ".loadout")
			RoomPlacement.Kind.PLAYER_SPAWN:
				player_spawns += 1
			RoomPlacement.Kind.ITEM_PEDESTAL, RoomPlacement.Kind.SHOP_SLOT:
				if placement.item == null and placement.equipment == null and placement.item_query != null and content != null:
					_check_item_pool(placement.item_query, where + ".item_query")
		if placement.item != null and placement.equipment != null:
			_error("placement_both", where, "a placement offers one thing: an item or a piece of equipment, not both")
		if placement.price >= 0 and placement.kind != K.SHOP_SLOT:
			_warning("placement_kind", where, "a price only matters on a shop slot")
		if (placement.item != null or placement.equipment != null or placement.item_query != null) \
				and not placement.kind in [K.ITEM_PEDESTAL, K.SHOP_SLOT]:
			_warning("placement_kind", where, "an item only matters on an item pedestal or shop slot")
		if placement.loadout != null and placement.kind != K.ENEMY_SPAWN:
			_warning("placement_kind", where, "a loadout only matters on an enemy spawn")
	var has_encounter := room.content_mode in [RoomDefinition.ContentMode.ENCOUNTER, RoomDefinition.ContentMode.ENCOUNTER_QUERY]
	if room.content_mode == RoomDefinition.ContentMode.ENCOUNTER and room.encounter != null \
			and enemy_spawns < room.encounter.slots.size():
		_warning("spawn_mismatch", path + "::placements",
			"%s has %d enemy spawn(s) for %d encounter slot(s)" % [room.id, enemy_spawns, room.encounter.slots.size()])
	if has_encounter and player_spawns == 0:
		_warning("spawn_mismatch", path + "::placements", "%s has an encounter but no player spawn" % room.id)


func _check_item_pool(query: GameplayTagQuery, where: String) -> void:
	for id in content.items:
		if TagMatch.matches(query, content.items[id].tags):
			return
	for id in content.equipment:
		if not content.equipment[id].tags.is_empty() and TagMatch.matches(query, content.equipment[id].tags):
			return
	if _has_fallback_item():
		_warning("empty_item_pool", where, "no item matches this pool; the run's fallback_item is used")
	else:
		_error("empty_item_pool", where, "no item matches this pool and the run structure has no fallback_item")


func _has_fallback_item() -> bool:
	for id in content.runs:
		if content.runs[id].fallback_item != null:
			return true
	return false


func _check_chapter(chapter: ChapterDefinition) -> void:
	var path := chapter.resource_path
	var rules := chapter.floor_gen_rules
	if rules == null:
		_error("dangling_ref", path + "::floor_gen_rules", "%s has no floor_gen_rules" % chapter.id)
	if chapter.scaling == null:
		_error("dangling_ref", path + "::scaling", "%s has no scaling" % chapter.id)
	if rules == null:
		return
	var roles := [["start", rules.start_room_tag, range(1, 16)], ["normal", rules.normal_room_tag, range(1, 16)],
		["boss", rules.boss_room_tag, SINGLE_DOOR_MASKS]]
	for tag in rules.special_room_tags:
		roles.append(["special", tag, SINGLE_DOOR_MASKS])
	var uses_encounter_query := {"normal": false, "boss": false}
	var uses_event_query := false
	for role in roles:
		var candidates: Array = []
		for id in _sorted(content.rooms):
			var room: RoomDefinition = content.rooms[id]
			if TagMatch.has(room.tags, role[1]) and TagMatch.matches(chapter.room_query, room.tags):
				candidates.append(room)
		if candidates.is_empty():
			_error("empty_query", path + "::room_query", "%s has no %s room (tag %s)" % [chapter.id, role[0], role[1]])
			continue
		if candidates.all(func(room: RoomDefinition) -> bool: return room.weight_x100 <= 0):
			_error("zero_weights", path + "::room_query", "every %s room of %s has weight 0" % [role[0], chapter.id])
		var unmet := PackedStringArray()
		for mask in role[2]:
			if not candidates.any(func(room: RoomDefinition) -> bool: return room.fits(mask)):
				unmet.append(_mask_name(mask))
		if not unmet.is_empty():
			_warning("doors_unsatisfiable", path + "::room_query", "no %s room of %s fits doors %s; a seed needing one fails"
				% [role[0], chapter.id, ", ".join(unmet)])
		for room in candidates:
			if room.content_mode == RoomDefinition.ContentMode.ENCOUNTER_QUERY and room.content_query == null:
				uses_encounter_query["boss" if role[0] == "boss" else "normal"] = true
			if room.content_mode == RoomDefinition.ContentMode.EVENT_QUERY and room.content_query == null:
				uses_event_query = true
	if uses_encounter_query["normal"]:
		_check_pool(content.encounters, chapter.encounter_query, path + "::encounter_query", "encounter")
	if uses_encounter_query["boss"]:
		_check_pool(content.encounters, chapter.boss_encounter_query, path + "::boss_encounter_query", "boss encounter")
	if uses_event_query:
		_check_pool(content.events, chapter.event_query, path + "::event_query", "event")


## A query a floor depends on: no matches → empty_query; all weights 0 → zero_weights.
func _check_pool(index: Dictionary, query: GameplayTagQuery, where: String, what: String) -> void:
	var matches: Array = []
	for id in _sorted(index):
		if TagMatch.matches(query, index[id].tags):
			matches.append(index[id])
	if matches.is_empty():
		_error("empty_query", where, "no %s matches this query" % what)
	elif matches.all(func(entry) -> bool: return int(entry.get("weight_x100")) <= 0):
		_error("zero_weights", where, "every %s matching this query has weight 0" % what)


func _check_weight(resource: Resource, path: String) -> void:
	if int(resource.get("weight_x100")) < 0:
		_error("zero_weights", path + "::weight", "a negative weight")


## Spec item-pass 3.5: a slot, and one the run structures offer (when any lists its slots); pickup fields as for items.
func _check_equipment(piece: EquipmentDefinition) -> void:
	var path := piece.resource_path
	if piece.slot == &"":
		_error("bad_equipment", path + "::slot", "%s has no slot" % piece.id)
	else:
		var listed := false
		var any_list := false
		for id in content.runs:
			var slots: Array[StringName] = content.runs[id].equipment_slots
			any_list = any_list or not slots.is_empty()
			listed = listed or slots.has(piece.slot)
		if any_list and not listed:
			_error("bad_equipment_slot", path + "::slot", "%s's slot %s is in no run structure's equipment_slots" % [piece.id, piece.slot])
	if piece.description == "":
		_warning("no_description", path + "::description", "%s has no description" % piece.id)
	_check_weight(piece, path)
	_check_ability_set(piece.grants, path + "::grants")


func _check_item(item: ItemDefinition) -> void:
	var path := item.resource_path
	if item.description == "" and not TagMatch.has(item.tags, FloorGenerator.DEV_TAG):
		_warning("no_description", path + "::description", "%s has no description" % item.id)
	if item.kind == ItemDefinition.Kind.USABLE:
		if item.use_ability == null:
			_error("bad_item", path + "::use_ability", "%s is USABLE but has no use_ability" % item.id)
		elif SkillTags.tag_of(item.use_ability) == &"":
			_error("bad_item", path + "::use_ability", "%s's use_ability is not a BattleAbility scene" % item.id)
		if item.use_mode == ItemDefinition.UseMode.COOLDOWN and item.cooldown_battles <= 0:
			_error("bad_item", path + "::cooldown_battles", "%s has a COOLDOWN use mode with %d battles" % [item.id, item.cooldown_battles])
	_check_ability_set(item.grants, path + "::grants")
	for hook in ["on_pickup", "on_floor_start", "on_room_cleared"]:
		var outcomes: Array = item.get(hook)
		for index in outcomes.size():
			_check_outcome(outcomes[index], "%s::%s[%d]" % [path, hook, index], null)


func _check_ability_set(ability_set: AbilitySet, path: String) -> void:
	if ability_set == null:
		return
	for index in ability_set.abilities.size():
		_check_skill_scene(ability_set.abilities[index], "%s.abilities[%d]" % [path, index], &"an ability set")
	for index in ability_set.effects.size():
		if ability_set.effects[index] == null:
			_error("dangling_ref", "%s.effects[%d]" % [path, index], "an empty effect entry")


func _check_event(event: EventDefinition) -> void:
	var path := event.resource_path
	if event.pages.is_empty():
		_error("bad_event", path + "::pages", "%s has no pages" % event.id)
	for page_index in event.pages.size():
		var page: EventPage = event.pages[page_index]
		var where := "%s::pages[%d]" % [path, page_index]
		if page == null:
			_error("dangling_ref", where, "an empty page entry")
			continue
		if page.choices.is_empty():
			_error("bad_event", where, "page %d of %s has no choices" % [page_index, event.id])
		for choice_index in page.choices.size():
			var choice: EventChoice = page.choices[choice_index]
			if choice == null:
				_error("dangling_ref", "%s.choices[%d]" % [where, choice_index], "an empty choice entry")
				continue
			for index in choice.outcomes.size():
				_check_outcome(choice.outcomes[index], "%s.choices[%d].outcomes[%d]" % [where, choice_index, index], event)
	_check_weight(event, path)


func _check_outcome(outcome: RunOutcome, where: String, event: EventDefinition) -> void:
	if outcome == null:
		_error("dangling_ref", where, "an empty outcome entry")
	elif outcome is GiveItem and outcome.item == null and outcome.item_query == null:
		_error("dangling_ref", where, "GiveItem has neither an item nor an item query")
	elif outcome is StartEncounter and outcome.encounter == null:
		_error("dangling_ref", where, "StartEncounter has no encounter")
	elif outcome is GiveEquipment and outcome.equipment == null:
		_error("dangling_ref", where, "GiveEquipment has no equipment")
	elif outcome is ApplyPartyEffect and outcome.effect == null:
		_error("dangling_ref", where, "ApplyPartyEffect has no effect")
	elif outcome is GoToPage and event != null and (outcome.page < 0 or outcome.page >= event.pages.size()):
		_error("bad_event", where, "GoToPage %d, but %s has %d page(s)" % [outcome.page, event.id, event.pages.size()])


func _check_layout(layout: FloorLayout) -> void:
	var problem := FloorGenerator.check_layout(layout)
	if problem != "":
		_error("bad_layout", layout.resource_path, problem)


func _check_run(structure: RunStructure, generate_seeds: int) -> void:
	var path := structure.resource_path
	if structure.floors.is_empty():
		_error("dangling_ref", path + "::floors", "%s has no floors" % structure.id)
	for floor_index in structure.floors.size():
		var slot: FloorSlot = structure.floors[floor_index]
		var where := "%s::floors[%d]" % [path, floor_index]
		if slot == null or slot.chapters.is_empty() or slot.chapters.has(null):
			_error("dangling_ref", where, "floor %d of %s has no chapters (or an empty entry)" % [floor_index, structure.id])
			continue
		if generate_seeds <= 0 or slot.layout != null:
			continue
		for chapter in slot.chapters:
			if chapter.floor_gen_rules == null:
				continue
			for seed_value in range(1, generate_seeds + 1):
				var generator := FloorGenerator.new(content, structure, seed_value, floor_index)
				var result: Dictionary = generator.generate(chapter, slot.rooms_from_any_chapter, {"party": [], "held": [], "seen": []})
				if result["error"] != "":
					_error("generation_fails", where, "floor %d, chapter %s, seed %d: %s" % [floor_index, chapter.id, seed_value, result["error"]])
					break


## Every gas::tag value in the content against the registry; Dev.* is reserved for dev decisions.
func _check_tags() -> void:
	var registry: GameplayTagRegistry = load(SETTINGS.get_registry_tag_path())
	var registered := {}
	if registry != null:
		for tag in registry.tags:
			registered[tag] = true
	var used := {}  # tag -> first path
	for index in [content.units, content.encounters, content.loadouts, content.variants, content.equipment, content.items,
			content.events, content.rooms, content.chapters, content.scaling, content.floor_rules, content.runs, content.layouts]:
		for id in _sorted(index):
			_collect_tags(index[id], index[id].resource_path, used)
	var tags: Array = used.keys()
	tags.sort()
	for tag in tags:
		if String(tag).begins_with(RESERVED_TAG_PREFIX):
			_error("reserved_tag", used[tag], "%s uses the reserved prefix %s (dev decisions)" % [tag, RESERVED_TAG_PREFIX])
		elif registry != null and not registered.has(tag):
			_warning("unknown_tag", used[tag], "%s is not in the tag registry (run game/tools/sync_tags.tscn)" % tag)


func _collect_tags(object: Object, path: String, used: Dictionary) -> void:
	if _visited.has(object.get_instance_id()):
		return
	_visited[object.get_instance_id()] = true
	for property in object.get_property_list():
		if not (property["usage"] & PROPERTY_USAGE_STORAGE):
			continue
		var value: Variant = object.get(property["name"])
		if property["hint_string"] == TAG_HINT:
			var values: Array = value if value is Array else [value]
			for tag in values:
				if StringName(tag) != &"" and not used.has(StringName(tag)):
					used[StringName(tag)] = path + "::" + property["name"]
		elif value is Array:
			for element in value:
				if _is_inline(element):
					_collect_tags(element, path, used)
		elif _is_inline(value):
			_collect_tags(value, path, used)


# --- Helpers ---------------------------------------------------------------------------------------------------------

func _error(code: String, path: String, message: String) -> void:
	issues.append(ValidationIssue.new(ValidationIssue.ERROR, code, path, message))


func _warning(code: String, path: String, message: String) -> void:
	issues.append(ValidationIssue.new(ValidationIssue.WARNING, code, path, message))


func _sorted_issues() -> Array[ValidationIssue]:
	var result := issues.duplicate()
	result.sort_custom(func(a: ValidationIssue, b: ValidationIssue) -> bool:
		if a.severity != b.severity:
			return a.is_error()
		if a.path != b.path:
			return a.path < b.path
		return a.code < b.code)
	return result


## A sub-resource saved inside another file (or not saved at all), as opposed to its own file.
static func _is_inline(value: Variant) -> bool:
	return value is Resource and not (value is Script or value is PackedScene or value is Texture or value is Mesh) \
		and (value.resource_path == "" or value.resource_path.contains("::"))


static func _mask_name(mask: int) -> String:
	var sides := ""
	for pair in [[1, "N"], [2, "E"], [4, "S"], [8, "W"]]:
		if mask & pair[0]:
			sides += pair[1]
	return sides


static func _sorted(index: Dictionary) -> Array:
	var ids := index.keys()
	ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	return ids
