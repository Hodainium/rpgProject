## How a builder writes a NEW file (review fix 2026-11-09): ResourceSaver.save, then a fresh UID when the saved file has none, so
## every builder-made scene and resource can be referenced by UID (the inspector and the dashboard store a cue scene that way,
## GodotGAS patch 3). Builders still never overwrite an existing design file: they call this only for a path that does not exist
## (or with their explicit --force).
class_name BuilderSave
extends RefCounted


static func save(resource: Resource, path: String) -> Error:
	var error := ResourceSaver.save(resource, path)
	if error == OK and ResourceLoader.get_resource_uid(path) == ResourceUID.INVALID_ID:
		var id := ResourceUID.create_id()
		ResourceUID.add_id(id, path)
		ResourceSaver.set_uid(path, id)
	return error
