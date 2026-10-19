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
var problems := PackedStringArray()


func _init(content_root: String) -> void:
	root = content_root.trim_suffix("/")
	for path in _resource_paths(root):
		var resource := load(path)
		if resource is UnitDefinition:
			_add(units, "unit", resource, path)
			if resource is CharacterDefinition:
				characters[resource.id] = resource
		elif resource is EncounterDefinition:
			_add(encounters, "encounter", resource, path)
		elif resource is Loadout:
			_add(loadouts, "loadout", resource, path)
		elif resource is EnemyVariant:
			_add(variants, "variant", resource, path)
		elif resource is EquipmentDefinition:
			_add(equipment, "equipment", resource, path)
		elif resource is ItemDefinition:
			_add(items, "item", resource, path)
		elif resource is EventDefinition:
			_add(events, "event", resource, path)
		elif resource is RoomDefinition:
			_add(rooms, "room", resource, path)
		elif resource is ChapterDefinition:
			_add(chapters, "chapter", resource, path)
		elif resource is ScalingRules:
			_add(scaling, "scaling", resource, path)
		elif resource is FloorGenRules:
			_add(floor_rules, "floor rules", resource, path)
		elif resource is RunStructure:
			_add(runs, "run structure", resource, path)
		elif resource is FloorLayout:
			_add(layouts, "layout", resource, path)


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
