## Finds content by id under a content root (spec combat-replay-core 3.1; game-skeleton 3.1).
##
## res://tests/fixtures/ for system tests, res://content/ for real play. Every .tres/.res file under the root
## (subfolders included, so content/demo/... works) is loaded in path order and indexed by its class and id; files of
## other classes (effects, animations, abilities' resources) are ignored. A CharacterDefinition or EnemyDefinition is
## also a unit. Duplicate ids within one kind are problems.
class_name ContentIndex
extends RefCounted

var root: String
var units: Dictionary = {}       # StringName -> UnitDefinition (includes characters and enemies)
var characters: Dictionary = {}  # StringName -> CharacterDefinition
var encounters: Dictionary = {}  # StringName -> EncounterDefinition
var loadouts: Dictionary = {}    # StringName -> Loadout (only loadouts saved as their own file)
var variants: Dictionary = {}    # StringName -> EnemyVariant
var equipment: Dictionary = {}   # StringName -> EquipmentDefinition
var items: Dictionary = {}       # StringName -> ItemDefinition
var events: Dictionary = {}      # StringName -> EventDefinition
var rooms: Dictionary = {}       # StringName -> RoomDefinition
var chapters: Dictionary = {}    # StringName -> ChapterDefinition
var scaling: Dictionary = {}     # StringName -> ScalingRules
var floor_rules: Dictionary = {} # StringName -> FloorGenRules
var runs: Dictionary = {}        # StringName -> RunStructure
var layouts: Dictionary = {}     # StringName -> FloorLayout
var chests: Dictionary = {}      # StringName -> ChestDefinition (spec keys-and-gear)
var problems := PackedStringArray()


func _init(content_root: String) -> void:
	root = content_root.trim_suffix("/")
	if root == "":
		return
	for path in _resource_paths(root):
		_index(load(path), path)


## Indexes a second folder too (the dev content, spec dev-tools 3.3), with the same duplicate-id rules.
func add_root(extra_root: String) -> void:
	for path in _resource_paths(extra_root.trim_suffix("/")):
		_index(load(path), path)


## A copy that also holds `resources` (added, or replacing the same id), for a sandbox playing an unsaved room, a
## room outside the content root or an encounter built in memory (spec dev-tools 2.2). This index is unchanged.
func overlay(resources: Array) -> ContentIndex:
	var copy := ContentIndex.new("")
	copy.root = root
	for name in ["units", "characters", "encounters", "loadouts", "variants", "equipment", "items", "events", "rooms",
			"chapters", "scaling", "floor_rules", "runs", "layouts", "chests"]:
		copy.set(name, get(name).duplicate())
	copy.problems = problems.duplicate()
	for resource in resources:
		if resource != null:
			copy._index(resource, resource.resource_path, true)
	return copy


## Files a resource of a content class under its id (other classes are ignored). `replace` overwrites an existing id
## instead of reporting a duplicate.
func _index(resource: Resource, path: String, replace: bool = false) -> void:
	var entry := _table_for(resource)
	if entry.is_empty():
		return
	if replace:
		entry[0].erase(resource.get("id"))
	_add(entry[0], entry[1], resource, path)
	if resource is CharacterDefinition and entry[0].get(resource.id) == resource:
		characters[resource.id] = resource


## [table, kind name] for a content resource, or [] for any other class.
func _table_for(resource: Resource) -> Array:
	if resource is UnitDefinition:
		return [units, "unit"]
	if resource is EncounterDefinition:
		return [encounters, "encounter"]
	if resource is Loadout:
		return [loadouts, "loadout"]
	if resource is EnemyVariant:
		return [variants, "variant"]
	if resource is EquipmentDefinition:
		return [equipment, "equipment"]
	if resource is ItemDefinition:
		return [items, "item"]
	if resource is EventDefinition:
		return [events, "event"]
	if resource is RoomDefinition:
		return [rooms, "room"]
	if resource is ChapterDefinition:
		return [chapters, "chapter"]
	if resource is ScalingRules:
		return [scaling, "scaling"]
	if resource is FloorGenRules:
		return [floor_rules, "floor rules"]
	if resource is RunStructure:
		return [runs, "run structure"]
	if resource is FloorLayout:
		return [layouts, "layout"]
	if resource is ChestDefinition:
		return [chests, "chest"]
	return []


## Resolves a LoadoutRef (spec game-skeleton 3.5): a loadout id, or "<ownerId>#<n>" for the loadout typed inline into
## encounter slot n or room placement n (1-based), or "<unitId>#default" for a unit's inline default_loadout.
## Returns null for an unknown ref.
func resolve_loadout(ref: String) -> Loadout:
	if ref == "":
		return null
	if not ref.contains("#"):
		return loadouts.get(StringName(ref))
	var owner := StringName(ref.get_slice("#", 0))
	if ref.get_slice("#", 1) == "default":
		return units[owner].default_loadout if units.has(owner) else null
	var index := ref.get_slice("#", 1).to_int() - 1
	if encounters.has(owner):
		var slots: Array = encounters[owner].slots
		return slots[index].loadout if index >= 0 and index < slots.size() and slots[index] != null else null
	if rooms.has(owner):
		var placements: Array = rooms[owner].placements
		return placements[index].loadout if index >= 0 and index < placements.size() and placements[index] != null else null
	return null


## The LoadoutRef for a loadout found on an owner: its id when it is a saved file, else "<ownerId>#<n>" (n = "default"
## for a unit's default_loadout).
static func loadout_ref(loadout: Loadout, owner_id: StringName, number: String) -> String:
	if loadout == null:
		return ""
	if loadout.id != &"" and loadout.resource_path != "" and not loadout.resource_path.contains("::"):
		return String(loadout.id)
	return "%s#%s" % [owner_id, number]


func _add(index: Dictionary, kind: String, resource: Resource, path: String) -> void:
	var id: StringName = resource.get("id")
	if id == &"":
		problems.append("%s %s has no id" % [kind, path])
	elif index.has(id):
		problems.append("duplicate %s id %s (%s)" % [kind, id, path])
	else:
		index[id] = resource


static func _resource_paths(directory: String) -> PackedStringArray:
	var paths := PackedStringArray()
	for file_name in ResourceLoader.list_directory(directory):
		if file_name.ends_with("/"):
			if file_name != "golden/":
				paths.append_array(_resource_paths(directory + "/" + file_name.trim_suffix("/")))
			continue
		# Exported builds list "x.tres.remap"; load() resolves the original path.
		var name := file_name.trim_suffix(".remap")
		if name.ends_with(".tres") or name.ends_with(".res"):
			paths.append(directory + "/" + name)
	paths.sort()
	return paths
