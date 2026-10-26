## Export-time patches (spec playable-demo 3.12 D34): rewrites only the exported copy of a vendored file that can't
## run in an export template; the file on disk stays untouched. Each patch must match exactly `count` times, or the
## export stops with the file named (a GodotGAS upgrade re-checks it). Plain script, so tests load it in any build.
extends RefCounted

## The one rewrite: the same object in the editor, a runtime lookup (never reached in a game) in an export template.
const EDITOR_INTERFACE: String = "EditorInterface."
const EDITOR_INTERFACE_LOOKUP: String = "Engine.get_singleton(&\"EditorInterface\")."
## path -> [[old, new, count], ...]. GodotGAS 1.1.2 names EditorInterface in runtime code; GDScript resolves it at
## parse time and export templates have no editor classes, so the GameplayCueManager autoload (and project_settings.gd,
## which it depends on) fail to load in any export.
const PATCHES: Dictionary = {
	"res://addons/GodotGAS/managers/gameplay_cue_manager.gd": [[EDITOR_INTERFACE, EDITOR_INTERFACE_LOOKUP, 1]],
	"res://addons/GodotGAS/utilities/project_settings.gd": [[EDITOR_INTERFACE, EDITOR_INTERFACE_LOOKUP, 2]],
}


## {"text": patched source, "error": ""} or {"text": "", "error": why}.
static func patch(path: String, source: String) -> Dictionary:
	var text := source
	for entry in PATCHES.get(path, []):
		var found := text.count(entry[0])
		if found != entry[2]:
			return {"text": "", "error": "%s: expected %d of '%s', found %d (GodotGAS changed? see spec playable-demo 3.12)" % [
				path, entry[2], entry[0], found]}
		text = text.replace(entry[0], entry[1])
	return {"text": text, "error": ""}
