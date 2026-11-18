## Spec card-ui 3.4: the player's NEW set, the card ids already seen in the Collection, kept on the player's machine only
## (`user://saves/<player>/cards_seen.json`, never uploaded). An owned non-core card shows NEW until it is opened in the detail or
## hovered for half a second. A missing or broken file means "nothing seen".
class_name CardSeen
extends RefCounted

const FILE_NAME: String = "cards_seen.json"

var path: String = ""
var ids: Dictionary = {}


## The set of `player` under `saves_dir` (the local mode's player is "local"); no `saves_dir`: kept in memory only.
static func open(saves_dir: String, player: String) -> CardSeen:
	var seen := CardSeen.new()
	if saves_dir == "":
		return seen
	seen.path = saves_dir.path_join(player if player != "" else "local").path_join(FILE_NAME)
	var text := FileAccess.get_file_as_string(seen.path) if FileAccess.file_exists(seen.path) else ""
	var json := JSON.new()
	var parsed: Variant = json.data if text != "" and json.parse(text) == OK else null   # a broken file: nothing seen, quietly
	if parsed is Dictionary and parsed.get("seen") is Array:
		for id in parsed["seen"]:
			seen.ids[str(id)] = true
	return seen


func has(id: String) -> bool:
	return ids.has(id)


## Marks `id` seen and saves; false when it already was.
func mark(id: String) -> bool:
	if ids.has(id):
		return false
	ids[id] = true
	save()
	return true


func save() -> void:
	if path == "":
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var list: Array[String] = []
	for id in ids:
		list.append(str(id))
	list.sort()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("CardSeen: cannot write %s" % path)
		return
	file.store_string(JSON.stringify({"seen": list}))
