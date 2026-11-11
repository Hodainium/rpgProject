## Tag checkpoint: checks the tags in use against the GodotGAS registry, then regenerates gameplay_tags.gd with the
## addon's own generator (the same call the dashboard makes when a tag is added or removed).
##
## Checked: every field marked "gas::tag" (GodotGAS's and ours) in every resource and scene under res://content/ and
## res://presentation/ (the UI policy, layers and slots, spec ui-framework), plus the tags the code itself uses
## (SYSTEM_TAGS, the Auto roles, the UI state tags, and the gameplay message channels, verbs and notification tags). Reported: tags in
## use but not registered (with where), tags with a bad format, and registered tags nothing uses.
## Writes only gameplay_tags.gd. With --add-missing it also adds the missing tags (it validates the format, sorts, saves and
## regenerates). With --remove <Tag>[,<Tag>...] it removes exactly those registered tags, and refuses any that something still uses (it
## names where) or that does not exist; --remove-unused removes every tag reported as unused. A tag with children is only removed
## itself, and a tag the code or content uses is never removed. Exit code 1 while anything is missing or a removal was refused.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/sync_tags.tscn [-- --add-missing] [--remove Tag,Tag | --remove-unused]
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
	# Spec keys-and-gear: where abilities work, and the run modifier tags the run reads from held items.
	&"Ability.Usage.Field", &"Ability.Usage.Battle", &"Run.Keys.Double", &"Run.Chest.Double", &"Run.Chest.NoKey",
	# Spec vfx-framework: the effect cues the proof set registers (cue_registry.tres). Effect asset tags (Fx.Kind.*) are
	# gas::tag fields, found in presentation/.
	&"Cue.Fx.HitSpark", &"Cue.Fx.Heal", &"Cue.Fx.Break", &"Cue.Fx.Aura",
]
const FORMAT: String = "^([A-Z][a-zA-Z0-9]*)(\\.[A-Z][a-zA-Z0-9]*)*$"

var _used: Dictionary = {}  # tag -> Array of "file: field"
## Review fix: tags only the test fixtures use. Never reported missing (fixtures may use their own tags), but never removed
## by --remove / --remove-unused either.
var _protected: Dictionary = {}
var _into_protected: bool = false
const FIXTURES_ROOT: String = "res://tests/fixtures/"
var _visited: Dictionary = {}


func _ready() -> void:
	var registry_path := SETTINGS.get_registry_tag_path()
	var registry: GameplayTagRegistry = load(registry_path)
	if registry == null:
		push_error("sync_tags: no tag registry at " + registry_path)
		get_tree().quit(1)
		return
	for tag in SYSTEM_TAGS + AutoPolicy.ROLES + UIState.ALL + GameplayMessageRouter.CHANNELS + GameplayMessageRouter.VERBS \
			+ GameplayMessageRouter.NOTIFICATION_TAGS:
		_note(tag, "code (system tag)")
	_scan(CONTENT_ROOT)
	_scan(PRESENTATION_ROOT)
	# Review fix: the cue registry's tags are in use (GameplayCueEntry.tag is not a gas::tag field, the dashboard names it).
	var cue_registry := load(SETTINGS.get_registry_cue_path()) as GameplayCueRegistry
	if cue_registry != null:
		for entry in cue_registry.entries:
			if entry != null:
				_note(entry.tag, "godot_gas/cue_registry.tres")
	_into_protected = true
	_scan(FIXTURES_ROOT)
	_into_protected = false

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
		if not _used.has(tag) and not _protected.has(tag) and not names.any(func(t): return String(t).begins_with(String(tag) + ".")):
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
	var refused := _remove(registry, registry_path, unused)
	GameplayTagGenerator.generate_tags_file(registry.tags)
	get_tree().quit(1 if not missing.is_empty() or not malformed.is_empty() or refused else 0)


## --remove / --remove-unused: takes tags out of the registry (a tag in use, or not registered, is refused and named). Returns whether
## anything was refused.
func _remove(registry: GameplayTagRegistry, registry_path: String, unused: Array) -> bool:
	var args := OS.get_cmdline_user_args()
	var wanted: Array = []
	if args.has("--remove-unused"):
		wanted.append_array(unused)
	if args.has("--remove") and args.find("--remove") + 1 < args.size():
		for tag in args[args.find("--remove") + 1].split(",", false):
			wanted.append(StringName(tag.strip_edges()))
	if wanted.is_empty():
		return false
	var in_use := _used.duplicate()
	in_use.merge(_protected)   # a tag only the fixtures use is never removed
	var plan := removal_plan(registry.tags, in_use, wanted)
	for entry in plan["refused"]:
		print("  %-15s %s  (%s)" % [entry["reason"], entry["tag"], entry["where"]])
	var refused: bool = not (plan["refused"] as Array).is_empty()
	var removed: int = (plan["remove"] as Array).size()
	for tag in plan["remove"]:
		registry.tags.erase(tag)
		print("  removed         %s" % tag)
	if removed > 0:
		var uid := ResourceLoader.get_resource_uid(registry_path)
		ResourceSaver.save(registry, registry_path)
		if uid != ResourceUID.INVALID_ID:
			ResourceSaver.set_uid(registry_path, uid)
		print("sync_tags: removed %d tag(s) from %s" % [removed, registry_path])
	return refused


## Which of `wanted` may leave a registry holding `tags`, given the tags in use (`used`: tag -> where): {remove: [tag], refused:
## [{tag, reason, where}]}. A tag in use or with a used descendant stays; so does a tag that is not registered (nothing to remove).
static func removal_plan(tags: Array, used: Dictionary, wanted: Array) -> Dictionary:
	var remove: Array = []
	var refused: Array = []
	for tag in wanted:
		if not tags.has(tag):
			refused.append({"tag": tag, "reason": "NOT REGISTERED", "where": "nothing to remove"})
		elif used.has(tag):
			refused.append({"tag": tag, "reason": "STILL USED", "where": ", ".join(used[tag])})
		elif used.keys().any(func(other): return String(other).begins_with(String(tag) + ".")):
			refused.append({"tag": tag, "reason": "STILL USED", "where": "a tag under it is used"})
		elif not remove.has(tag):
			remove.append(tag)
	return {"remove": remove, "refused": refused}


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
	var into: Dictionary = _protected if _into_protected else _used
	if not into.has(tag):
		into[tag] = []
	if not into[tag].has(where):
		into[tag].append(where)
