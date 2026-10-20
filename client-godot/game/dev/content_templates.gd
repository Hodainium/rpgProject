## New content from a basic template (spec dev-tools 3.8), for the dock's Create and the console's `create`.
## Templates are code, so there are no template files to keep in sync. Values are only starting points.
class_name ContentTemplates
extends RefCounted

## Type → default folder name under the content folder.
const TYPES: Dictionary = {"character": "characters", "enemy": "enemies", "encounter": "encounters",
	"loadout": "loadouts", "room": "rooms", "item": "items", "event": "events"}
const DEFAULT_BASE: String = "res://content/demo/"


static func default_folder(type: String, base: String = DEFAULT_BASE) -> String:
	return base.path_join(TYPES.get(type, type)) + "/"


## A new resource of `type` with `id`, or null for an unknown type. `content` gives the attribute set most units use.
static func create(type: String, id: String, content: ContentIndex) -> Resource:
	match type:
		"character":
			var character := CharacterDefinition.new()
			_fill_unit(character, id, content)
			character.selectable = true
			return character
		"enemy":
			var enemy := EnemyDefinition.new()
			_fill_unit(enemy, id, content)
			return enemy
		"encounter":
			var encounter := EncounterDefinition.new()
			encounter.id = StringName(id)
			encounter.display_name = display_name_of(id)
			return encounter
		"loadout":
			var loadout := Loadout.new()
			loadout.id = StringName(id)
			return loadout
		"room":
			var room := RoomDefinition.new()
			room.id = StringName(id)
			room.display_name = display_name_of(id)
			room.doors = RoomDefinition.DOOR_N | RoomDefinition.DOOR_E | RoomDefinition.DOOR_S | RoomDefinition.DOOR_W
			room.min_doors = 1
			for slot in range(1, 5):
				var spawn := RoomPlacement.new()
				spawn.kind = RoomPlacement.Kind.PLAYER_SPAWN
				spawn.slot = slot
				spawn.cell = Vector2i(1, slot)
				room.placements.append(spawn)
			return room
		"item":
			var item := ItemDefinition.new()
			item.id = StringName(id)
			item.display_name = display_name_of(id)
			item.kind = ItemDefinition.Kind.PASSIVE
			item.price = 0
			return item
		"event":
			var event := EventDefinition.new()
			event.id = StringName(id)
			event.display_name = display_name_of(id)
			var page := EventPage.new()
			page.text = "..."
			var leave := EventChoice.new()
			leave.label = "Leave"
			leave.outcomes.append(EndEvent.new())
			page.choices.append(leave)
			event.pages.append(page)
			return event
	return null


## Creates and saves <folder>/<file name>.tres. {"path", "resource", "error"}; never overwrites a file or reuses an id.
static func save_new(type: String, id: String, folder: String, content: ContentIndex) -> Dictionary:
	var result := {"path": "", "resource": null, "error": ""}
	if not TYPES.has(type):
		result["error"] = "unknown type '%s' (one of %s)" % [type, ", ".join(TYPES.keys())]
		return result
	if id.strip_edges() == "" or id.contains(" "):
		result["error"] = "the id must be one word, e.g. demo.enemy.slime"
		return result
	var used := id_owner(type, id, content)
	if used != "":
		result["error"] = "the id %s is already used by %s" % [id, used]
		return result
	var path := folder.trim_suffix("/") + "/" + file_name_of(id) + ".tres"
	if FileAccess.file_exists(path):
		result["error"] = "%s already exists" % path
		return result
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var resource := create(type, id, content)
	var error := ResourceSaver.save(resource, path)
	if error != OK:
		result["error"] = "could not save %s (%s)" % [path, error_string(error)]
		return result
	result["path"] = path
	result["resource"] = load(path)
	return result


## The file already using `id` for this type, or "".
static func id_owner(type: String, id: String, content: ContentIndex) -> String:
	if content == null:
		return ""
	var table: Dictionary = {"character": content.units, "enemy": content.units, "encounter": content.encounters,
		"loadout": content.loadouts, "room": content.rooms, "item": content.items, "event": content.events}.get(type, {})
	var owner: Resource = table.get(StringName(id))
	return owner.resource_path if owner != null else ""


## "demo.enemy.big_slime" → "Big Slime".
static func display_name_of(id: String) -> String:
	return id.get_slice(".", id.get_slice_count(".") - 1).capitalize()


## "demo.enemy.big_slime" → "big_slime".
static func file_name_of(id: String) -> String:
	return id.get_slice(".", id.get_slice_count(".") - 1)


## Every attribute of the set at its default, ×100 as stored (so the designer only changes numbers). In the editor a
## script that isn't @tool can't be instantiated, so this reads the nearest @tool ancestor (e.g. the generated
## UnitAttributeSet under a hand-written subclass); attributes only the subclass declares are then left out.
static func stats_of(attribute_set: Script) -> Dictionary[String, int]:
	var stats: Dictionary[String, int] = {}
	var script := attribute_set
	if Engine.is_editor_hint():
		while script != null and not script.is_tool():
			script = script.get_base_script()
	if script == null or not script.can_instantiate():
		return stats
	var instance: Object = script.new()
	for property in instance.get_property_list():
		var value: Variant = instance.get(property["name"])
		if value is AttributeData:
			stats[property["name"]] = int(value.base_value)
	return stats


## The attribute set most existing units use (ties: the first by path), or null.
static func common_attribute_set(content: ContentIndex) -> Script:
	if content == null:
		return null
	var counts := {}
	for id in content.units:
		var script: Script = content.units[id].attribute_set
		if script != null:
			counts[script] = counts.get(script, 0) + 1
	var best: Script = null
	for script in counts:
		if best == null or counts[script] > counts[best] or (counts[script] == counts[best] and script.resource_path < best.resource_path):
			best = script
	return best


static func _fill_unit(unit: UnitDefinition, id: String, content: ContentIndex) -> void:
	unit.id = StringName(id)
	unit.display_name = display_name_of(id)
	unit.display_color = Color(0.55, 0.6, 0.7)
	unit.attribute_set = common_attribute_set(content)
	unit.stats_x100 = stats_of(unit.attribute_set)
