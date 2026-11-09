## "Preview in gallery" (spec vfx-framework 1, item 5): the inspector button on an FxDefinition writes a request file and
## starts fx_gallery.tscn, which reads it, registers that effect (so a new one that is not in the registry yet works too)
## and plays it. The same pattern as PlayRequest. The console's `fx play` is the command with the same effect.
class_name FxPreviewRequest
extends RefCounted

const REQUEST_PATH: String = "user://fx_preview.cfg"


## What the inspector button sends to the gallery: the effect's res:// path.
static func write(effect_path: String) -> Error:
	var file := ConfigFile.new()
	file.set_value("request", "path", effect_path)
	return file.save(REQUEST_PATH)


## The pending effect path, deleted once read; "" when there is none.
static func take() -> String:
	var file := ConfigFile.new()
	if file.load(REQUEST_PATH) != OK:
		return ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path(REQUEST_PATH))
	return str(file.get_value("request", "path", ""))
