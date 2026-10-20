## Play an asset straight away (spec dev-tools 2.4): the editor's Play buttons write a request file and start
## play_main.tscn; the console's `play` command calls start() directly. Both end in the same sandbox or run.
##   room → that room · layout → that floor · encounter → a battle room of the chapter with the encounter as override
##   enemy → the same, with a one-slot encounter built in memory · character → a new run with them in slot 1
class_name PlayRequest
extends RefCounted

const REQUEST_PATH: String = "user://dev_play.cfg"
const SETTINGS_PATH: String = "user://dev_tools.cfg"
const KINDS: Array[String] = ["room", "encounter", "enemy", "character", "layout"]


## Play settings shared by every Play button and `play`: {party: Array, seed: String, depth: int, chapter: String,
## content_root: String, folders: Dictionary (dock type → last folder)}.
static func settings() -> Dictionary:
	var result := {"party": [], "seed": "1", "depth": 0, "chapter": "", "content_root": "res://content/", "folders": {}}
	var file := ConfigFile.new()
	if file.load(SETTINGS_PATH) == OK:
		for key in result:
			result[key] = file.get_value("play", key, result[key])
	return result


static func save_settings(values: Dictionary) -> void:
	var file := ConfigFile.new()
	file.load(SETTINGS_PATH)
	for key in values:
		file.set_value("play", key, values[key])
	file.save(SETTINGS_PATH)


## What a Play button sends to play_main.tscn.
static func write(kind: String, target: String) -> Error:
	var file := ConfigFile.new()
	file.set_value("request", "kind", kind)
	file.set_value("request", "target", target)
	return file.save(REQUEST_PATH)


## The pending request ({"kind", "target"}), deleted once read; {} when there is none.
static func take() -> Dictionary:
	var file := ConfigFile.new()
	if file.load(REQUEST_PATH) != OK:
		return {}
	DirAccess.remove_absolute(ProjectSettings.globalize_path(REQUEST_PATH))
	return {"kind": str(file.get_value("request", "kind", "")), "target": str(file.get_value("request", "target", ""))}


## Starts the request on a GameMain. "" or the error.
static func start(game: GameMain, kind: String, target: String, play: Dictionary = {}) -> String:
	var built := build(game.content, kind, target, play)
	if built["error"] != "":
		return built["error"]
	if built["run"].is_empty():
		return game.start_sandbox(built["sandbox"])
	return game.start_run(built["run"]["party"], built["run"]["seed"])


## {"sandbox": SandboxRequest or null, "run": {"party", "seed"} or {}, "error": String}.
## `play` = the Play settings ({} reads them from user://).
static func build(content: ContentIndex, kind: String, target: String, play: Dictionary = {}) -> Dictionary:
	if play.is_empty():
		play = settings()
	var result := {"sandbox": null, "run": {}, "error": ""}
	if not kind in KINDS:
		result["error"] = "play what? one of %s" % ", ".join(KINDS)
		return result
	var asset := find(content, kind, target)
	if asset == null:
		result["error"] = "no %s '%s'" % [kind, target]
		return result
	var seed_value := RunSeeds.parse(str(play.get("seed", "1")))
	var party := party_for(content, play.get("party", []))
	if kind == "character":
		party.erase(asset.id)
		party.push_front(asset.id)
		result["run"] = {"party": party.slice(0, 4), "seed": str(maxi(seed_value, 0))}
		return result
	if party.is_empty():
		result["error"] = "no selectable character to play with"
		return result
	var request := SandboxRequest.new()
	request.party = party
	request.seed = maxi(seed_value, 0)
	request.depth = int(play.get("depth", 0))
	request.chapter_id = StringName(str(play.get("chapter", "")))
	match kind:
		"room":
			request.room = asset
		"layout":
			request.layout = asset
		"encounter", "enemy":
			var encounter: EncounterDefinition = asset if kind == "encounter" else _solo_encounter(asset)
			var chapter := _chapter(content, request.chapter_id)
			request.room = _battle_room(content, chapter)
			if request.room == null:
				result["error"] = "the content has no room to fight in"
				return result
			request.chapter_id = chapter.id if chapter != null else &""
			request.encounter = encounter
	result["sandbox"] = request
	return result


## An asset by id (from the content index) or by path (res:// or user://, loaded as it is on disk).
static func find(content: ContentIndex, kind: String, target: String) -> Resource:
	if target.begins_with("res://") or target.begins_with("user://"):
		var loaded: Resource = load(target) if ResourceLoader.exists(target) else null
		return loaded if _is_kind(loaded, kind) else null
	var table: Dictionary = {"room": content.rooms, "encounter": content.encounters, "enemy": content.units,
		"character": content.characters, "layout": content.layouts}[kind]
	var found: Resource = table.get(StringName(target))
	return found if _is_kind(found, kind) else null


static func _is_kind(asset: Resource, kind: String) -> bool:
	match kind:
		"room":
			return asset is RoomDefinition
		"encounter":
			return asset is EncounterDefinition
		"enemy":
			return asset is UnitDefinition and not asset is CharacterDefinition
		"character":
			return asset is CharacterDefinition
		"layout":
			return asset is FloorLayout
	return false


## The saved party (ids that still exist), else the first two selectable characters by id.
static func party_for(content: ContentIndex, saved: Array) -> Array:
	var party: Array = []
	for id in saved:
		if content.characters.has(StringName(str(id))) and party.size() < 4:
			party.append(StringName(str(id)))
	if not party.is_empty():
		return party
	var ids := content.characters.keys()
	ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	for id in ids:
		if content.characters[id].selectable and party.size() < 2:
			party.append(id)
	return party


static func _solo_encounter(enemy: UnitDefinition) -> EncounterDefinition:
	var encounter := EncounterDefinition.new()
	encounter.id = StringName("sandbox.enemy." + String(enemy.id))
	encounter.display_name = enemy.display_name
	var slot := EncounterSlot.new()
	slot.enemy = enemy
	encounter.slots.append(slot)
	return encounter


static func _chapter(content: ContentIndex, chapter_id: StringName) -> ChapterDefinition:
	if content.chapters.has(chapter_id):
		return content.chapters[chapter_id]
	var ids := content.chapters.keys()
	ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	return content.chapters[ids[0]] if not ids.is_empty() else null


## The first normal battle room (by id) of the chapter; else any room with an enemy spawn; else the first room.
static func _battle_room(content: ContentIndex, chapter: ChapterDefinition) -> RoomDefinition:
	var ids := content.rooms.keys()
	ids.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	var normal_tag: StringName = chapter.floor_gen_rules.normal_room_tag \
		if chapter != null and chapter.floor_gen_rules != null else &""
	for id in ids:
		var room: RoomDefinition = content.rooms[id]
		if chapter != null and not TagMatch.matches(chapter.room_query, room.tags):
			continue
		if room.content_mode in [RoomDefinition.ContentMode.ENCOUNTER, RoomDefinition.ContentMode.ENCOUNTER_QUERY] \
				and (normal_tag == &"" or TagMatch.has(room.tags, normal_tag)):
			return room
	for id in ids:
		for placement in content.rooms[id].placements:
			if placement != null and placement.kind == RoomPlacement.Kind.ENEMY_SPAWN:
				return content.rooms[id]
	return content.rooms[ids[0]] if not ids.is_empty() else null
