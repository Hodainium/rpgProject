## Tag checkpoint: checks the tags in use against the GodotGAS registry, then regenerates gameplay_tags.gd with the
## addon's own generator (the same call the dashboard makes when a tag is added or removed).
##
## Checked: every field marked "gas::tag" (GodotGAS's and ours) in every resource and scene under res://content/ and
## res://presentation/ (the UI policy, layers and slots, spec ui-framework), plus the tags the code itself uses
## (SYSTEM_TAGS and the UI state tags). Reported: tags in use but not registered (with where), tags with a bad
## format, and registered tags nothing uses (info only; nothing is ever removed).
## Writes only gameplay_tags.gd. With --add-missing it also adds the missing tags through the registry's own
## add_tag() (which validates the format, sorts, saves and regenerates). Exit code 1 while anything is missing.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/sync_tags.tscn [-- --add-missing]
extends Node

const SETTINGS := preload("res://addons/GodotGAS/utilities/project_settings.gd")
const CONTENT_ROOT: String = "res://content/"
const PRESENTATION_ROOT: String = "res://presentation/"
const TAG_HINT: String = "gas::tag"
## Tags the code reads or sends by name (spec game-skeleton 3.6, combat-replay-core).
const SYSTEM_TAGS: Array[StringName] = [
	&"State.Dead", &"State.Infield", &"Event.Battle.Start", &"Event.Turn.Start", &"Event.Turn.End",
	&"Event.Damage.Dealt", &"Event.Damage.Taken", &"Event.Unit.Died", &"Event.Ability.Used",
	&"Data.Damage.Flat", &"Data.Damage.Multiplier",
	# Spec item-pass: breaks, One More, follow-ups, kills, and the hit tags the battle itself injects.
	&"State.Broken", &"Ability.Type.FollowUp", &"Data.Toughness", &"Hit.Break", &"Hit.FollowUp",
	&"Event.Attack.FollowUp", &"Event.Unit.Killed", &"Event.Battle.OneMore",
	&"Event.Damage.Dealt.Break", &"Event.Damage.Taken.Break", &"Event.Damage.Dealt.FollowUp", &"Event.Damage.Taken.FollowUp",
	# Spec ult-interrupts: abilities cast out of turn.
	&"Ability.Type.Ultimate",
	# Spec content-pass: control and taunt rule tags, the status and phase events, drains, combined break and ult events.
	&"State.Controlled", &"State.Taunting", &"State.Downed", &"Status.Debuff", &"Event.Turn.Skipped", &"Event.Status.Resisted",
	&"Event.Battle.Interrupt", &"Event.Unit.PhaseChanged", &"Event.Ability.Used.Ultimate", &"Hit.Drained",
	&"Event.Damage.Dealt.Drained", &"Event.Damage.Taken.Drained",
	# Spec ui-framework: the layers the framework pushes to by name (confirm dialogs, UIPushButton's default).
	&"UI.Layer.Menu", &"UI.Layer.Modal",
]
const FORMAT: String = "^([A-Z][a-zA-Z0-9]*)(\\.[A-Z][a-zA-Z0-9]*)*$"

var _used: Dictionary = {}  # tag -> Array of "file: field"
var _visited: Dictionary = {}


func _ready() -> void:
	var registry_path := SETTINGS.get_registry_tag_path()
	var registry: GameplayTagRegistry = load(registry_path)
	if registry == null:
		push_error("sync_tags: no tag registry at " + registry_path)
		get_tree().quit(1)
		return
	for tag in SYSTEM_TAGS + UIState.ALL:
		_note(tag, "code (system tag)")
	_scan(CONTENT_ROOT)
	_scan(PRESENTATION_ROOT)

	var registered := {}
	for tag in registry.tags:
		registered[tag] = true
	var format := RegEx.create_from_string(FORMAT)
	var missing: Array = []
	var malformed: Array = []
	var names: Array = _used.keys()
	names.sort()
	for tag in names:
		if format.search(String(tag)) == null:
			malformed.append(tag)
		elif not _is_registered(tag, registered):
			missing.append(tag)
	var unused: Array = []
	for tag in registry.tags:
		if not _used.has(tag) and not names.any(func(t): return String(t).begins_with(String(tag) + ".")):
			unused.append(tag)

	print("sync_tags: %d tags in use, %d registered" % [names.size(), registry.tags.size()])
	for tag in malformed:
		print("  BAD FORMAT  %s  (%s)" % [tag, ", ".join(_used[tag])])
	for tag in missing:
		print("  MISSING     %s  (%s)" % [tag, ", ".join(_used[tag])])
	for tag in unused:
		print("  unused      %s" % tag)
	for tag in names:
		if _dashboard_form(tag) != String(tag):
			print("  DASHBOARD   %s would become %s if typed into the GodotGAS dashboard" % [tag, _dashboard_form(tag)])

	if OS.get_cmdline_user_args().has("--add-missing") and not missing.is_empty():
		var uid := ResourceLoader.get_resource_uid(registry_path)
		# Not registry.add_tag(): it re-capitalises every segment (UltCharge -> Ultcharge), which would register a
		# different tag than the content uses. The format was already checked above; sort like add_tag does.
		for tag in missing:
			registry.tags.append(tag)
		registry.tags.sort_custom(func(a, b): return String(a) < String(b))
		ResourceSaver.save(registry, registry_path)
		# A headless save drops the file's uid header; keep the one the editor gave it.
		if uid != ResourceUID.INVALID_ID:
			ResourceSaver.set_uid(registry_path, uid)
		print("sync_tags: added %d tag(s) to %s" % [missing.size(), registry_path])
		missing.clear()
	GameplayTagGenerator.generate_tags_file(registry.tags)
	get_tree().quit(1 if not missing.is_empty() or not malformed.is_empty() else 0)


## A parent tag counts as registered when it is in the registry, like GodotGAS's hierarchy (Event.Damage.Dealt.Ice
## needs its own entry; its parent does not cover it).
func _is_registered(tag: StringName, registered: Dictionary) -> bool:
	return registered.has(tag)


## What GameplayTagRegistry.add_tag() (the dashboard) turns a tag into: each segment "Xxxx" (first letter upper,
## the rest lower).
static func _dashboard_form(tag: StringName) -> String:
	var parts := PackedStringArray()
	for part in String(tag).split("."):
		parts.append(part.substr(0, 1).to_upper() + part.substr(1).to_lower())
	return ".".join(parts)


func _scan(directory: String) -> void:
	var dir := DirAccess.open(directory)
	if dir == null:
		return
	for sub in dir.get_directories():
		_scan(directory.path_join(sub))
	for file in dir.get_files():
		var path := directory.path_join(file)
		if file.ends_with(".tres") or file.ends_with(".res"):
			var resource := load(path)
			if resource != null:
				_walk(resource, path)
		elif file.ends_with(".tscn"):
			var scene: PackedScene = load(path)
			var root := scene.instantiate() if scene != null else null
			if root != null:
				_walk_nodes(root, path)
				root.free()


func _walk_nodes(node: Node, path: String) -> void:
	_walk(node, path)
	for child in node.get_children():
		_walk_nodes(child, path)


func _walk(object: Object, path: String) -> void:
	var key := object.get_instance_id()
	if _visited.has(key):
		return
	_visited[key] = true
	for property in object.get_property_list():
		if not (property["usage"] & PROPERTY_USAGE_STORAGE):
			continue
		var value: Variant = object.get(property["name"])
		if property["hint_string"] == TAG_HINT:
			var where := "%s: %s" % [path.trim_prefix(CONTENT_ROOT), property["name"]]
			if value is StringName or value is String:
				_note(StringName(value), where)
			elif value is Array:
				for tag in value:
					_note(StringName(tag), where)
		elif value is Array:
			for element in value:
				if _followable(element):
					_walk(element, path)
		elif _followable(value):
			_walk(value, path)


## Sub-resources (rows, queries, ability sets, inline loadouts...). Other files are scanned on their own.
func _followable(value: Variant) -> bool:
	return value is Resource and not (value is Script or value is PackedScene or value is Texture or value is Mesh) \
		and (value.resource_path == "" or value.resource_path.contains("::"))


func _note(tag: StringName, where: String) -> void:
	if tag == &"":
		return
	if not _used.has(tag):
		_used[tag] = []
	if not _used[tag].has(where):
		_used[tag].append(where)
