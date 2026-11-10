## Spec main-menu M5 / section 3: the local-mode save of a run, `user://saves/local/run.json`, rewritten whole after
## every player action. Client only (not a wire contract): {schemaVersion, rulesetVersion, savedAt, summary, snapshot}.
## `summary` lets the main menu draw its Continue line without loading the run. Written to `run.json.tmp` and renamed,
## so a crash never leaves half a file.
class_name LocalSave
extends RefCounted

const SCHEMA_VERSION: int = 1
const DEFAULT_PATH: String = "user://saves/local/run.json"


## Writes the save of `run`. False when it can't be written.
static func write(path: String, run: RunController, content: ContentIndex) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var party: Array = []
	for member in run.state.party:
		var character: CharacterDefinition = content.characters.get(StringName(member["character"])) if content != null else null
		party.append(character.display_name if character != null and character.display_name != "" else str(member["character"]))
	var structure_name := String(run.state.run_structure_id)
	if run.structure != null and run.structure.display_name != "":
		structure_name = run.structure.display_name
	var data := {
		"schemaVersion": SCHEMA_VERSION,
		"rulesetVersion": RulesetVersion.current(),
		"savedAt": Time.get_datetime_string_from_system(true) + "Z",
		"summary": {"runName": structure_name, "floor": run.state.floor_index + 1, "party": party},
		"snapshot": run.snapshot(),
		"cardPoolSet": run.state.card_pool_set,  # so a save that loses both the pool and its digest is noticed too
	}
	if run.state.card_pool_set:
		data["cardPool"] = run.state.card_pool.map(func(id: StringName) -> String: return String(id))  # a local test pool, spec card-collection 3.6
		data["cardPoolDigest"] = run.state.card_pool_digest()  # so a save that loses or changes it is noticed (RunState.save_pool_problem)
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		push_error("LocalSave: can't write %s" % tmp)
		return false
	file.store_string(WireJson.stringify(data))
	file.close()
	return DirAccess.rename_absolute(tmp, path) == OK


## {"state": "none" | "ok" | "bad", "data": the save (when ok)}. A file that can't be read or has another schema is kept
## as `<path>.bad` (state "bad"), so nothing is lost silently. A leftover .tmp is ignored.
static func read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"state": "none"}
	var json := JSON.new()  # parse(), not parse_string(): a bad file is an answer here, not an engine error
	var parsed: Variant = json.data if json.parse(FileAccess.get_file_as_string(path)) == OK else null
	if parsed is Dictionary and int(parsed.get("schemaVersion", 0)) == SCHEMA_VERSION \
			and parsed.get("snapshot") is Dictionary and parsed.get("summary") is Dictionary:
		return {"state": "ok", "data": parsed}
	DirAccess.rename_absolute(path, path + ".bad")
	return {"state": "bad"}


static func delete(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
