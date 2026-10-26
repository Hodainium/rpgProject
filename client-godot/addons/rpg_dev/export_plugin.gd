## Applies export_patches.gd to the exported copies of the patched files (spec playable-demo 3.12 D34): the original
## is skipped and the patched source goes into the pack as a plain .gd at the same path. Needs text script export
## (script_export_mode=0): with binary tokens GDScript's own exporter takes every script and _export_file never sees
## it (and resource customization stores a .res that GDScript can't resolve as a dependency). A patch that no longer
## matches leaves the file unpatched and prints "RPG export:", which tools/export.sh fails on.
@tool
extends EditorExportPlugin

const ExportPatches := preload("res://addons/rpg_dev/export_patches.gd")


func _get_name() -> String:
	return "RpgExportPatches"


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if not ExportPatches.PATCHES.has(path):
		return
	var result := ExportPatches.patch(path, FileAccess.get_file_as_string(path))
	if result["error"] != "":
		push_error("RPG export: " + result["error"])
		printerr("RPG export: " + result["error"])
		return
	skip()
	add_file(path, result["text"].to_utf8_buffer(), false)
