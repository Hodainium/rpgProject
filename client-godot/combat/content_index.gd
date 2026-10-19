## Finds content by id under a content root (spec section 3.1).
##
## res://tests/fixtures/ for system tests, res://content/ for real play. Scans <root>/units/ and <root>/encounters/
## for .tres files, sorted by file name so the result is stable, and indexes them by id.
class_name ContentIndex
extends RefCounted

var root: String
var units: Dictionary = {}       # StringName -> UnitDefinition
var encounters: Dictionary = {}  # StringName -> EncounterDefinition
var problems := PackedStringArray()


func _init(content_root: String) -> void:
	root = content_root.trim_suffix("/")
	for path in _resource_paths(root + "/units"):
		var unit := load(path) as UnitDefinition
		if unit == null:
			problems.append("%s is not a UnitDefinition" % path)
		elif units.has(unit.id):
			problems.append("duplicate unit id %s (%s)" % [unit.id, path])
		else:
			units[unit.id] = unit
	for path in _resource_paths(root + "/encounters"):
		var encounter := load(path) as EncounterDefinition
		if encounter == null:
			problems.append("%s is not an EncounterDefinition" % path)
		elif encounters.has(encounter.id):
			problems.append("duplicate encounter id %s (%s)" % [encounter.id, path])
		else:
			encounters[encounter.id] = encounter


static func _resource_paths(directory: String) -> PackedStringArray:
	var paths := PackedStringArray()
	for file_name in ResourceLoader.list_directory(directory):
		# Exported builds list "x.tres.remap"; load() resolves the original path.
		var name := file_name.trim_suffix(".remap")
		if name.ends_with(".tres") or name.ends_with(".res"):
			paths.append(directory + "/" + name)
	paths.sort()
	return paths
