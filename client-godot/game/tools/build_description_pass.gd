## Description pass (spec ff7-ui F5): drafts a one-line description for every party ability that has none, from what it
## does (its Ability.Role.* tags, targeting, damage types, cost), for the battle hints and the Status screen. The texts
## are the designer's: the drafts go to a JSON file to edit; --apply writes the (edited) file back, one
## `description = "..."` line per ability scene's root node (nothing else in the file changes).
##   godot --headless --path client-godot --quit-after 3000 res://game/tools/build_description_pass.tscn
##     [-- --content-root res://content/] [--out <drafts.json>]          (default user://description_pass.json)
##   ... -- --apply <drafts.json>                                          (writes the descriptions)
## Exit 0; 1 on a file it can't read or write.
class_name DescriptionPass
extends Node

const ROLE_TEXT := {
	"Damage": "%s damage to %s.", "Heal": "Restores HP to %s.", "Revive": "Brings %s back.",
	"Buff": "Strengthens %s.", "Debuff": "Weakens %s.", "Dispel": "Removes buffs from %s.",
	"Cleanse": "Removes debuffs from %s.", "RestoreMP": "Restores MP to %s.", "Guard": "Guards %s until the next turn.",
}
const TARGET_TEXT := {
	BattleAbility.Targeting.SINGLE_ENEMY: "one enemy", BattleAbility.Targeting.ALL_ENEMIES: "every enemy",
	BattleAbility.Targeting.BLAST_ENEMY: "one enemy and its neighbours", BattleAbility.Targeting.SINGLE_ALLY: "one ally",
	BattleAbility.Targeting.ALL_ALLIES: "the party", BattleAbility.Targeting.SELF: "yourself",
	BattleAbility.Targeting.SINGLE_DEAD_ALLY: "one fallen ally", BattleAbility.Targeting.ALL_DEAD_ALLIES: "every fallen ally",
}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var apply := RolePass._arg(args, "--apply", "")
	var code := apply_file(apply) if apply != "" else draft(RolePass._arg(args, "--content-root", "res://content/"),
		RolePass._arg(args, "--out", "user://description_pass.json"))
	get_tree().quit(code)


## Writes {scene path: draft} for every party ability without a description to `out`. 0, or 1 when it can't write.
func draft(root: String, out: String) -> int:
	var drafts := {}
	for path in RolePass.party_scenes(ContentIndex.new(root)):
		var scene := load(path) as PackedScene
		var ability := scene.instantiate() as BattleAbility if scene != null else null
		if ability == null:
			continue
		if ability.description == "" and not ability.is_triggered():
			drafts[path] = text_of(ability)
			print("%s: %s" % [path.get_file(), drafts[path]])
		ability.free()
	var file := FileAccess.open(out, FileAccess.WRITE)
	if file == null:
		push_error("DescriptionPass: can't write %s" % out)
		return 1
	file.store_string(JSON.stringify(drafts, "\t", true))
	print("DescriptionPass: %d draft(s) in %s; edit them, then run with --apply %s" % [drafts.size(), out, out])
	return 0


## A draft for `ability`: one sentence per role, then its cost.
static func text_of(ability: BattleAbility) -> String:
	var target: String = TARGET_TEXT.get(ability.targeting, "the target")
	var types := PackedStringArray()
	for row in ability.executions:
		if row != null:
			for type in row.damage_types():
				if not types.has(type):
					types.append(type)
	var sentences := PackedStringArray()
	for tag in ability.asset_tags:
		var role := String(tag).trim_prefix(AutoPolicy.ROLE_PREFIX)
		if not String(tag).begins_with(AutoPolicy.ROLE_PREFIX) or not ROLE_TEXT.has(role):
			continue
		var pattern: String = ROLE_TEXT[role]
		if role == "Damage":
			sentences.append(pattern % ["/".join(types) if not types.is_empty() else "Deals", target])
		else:
			sentences.append(pattern % target)
	if sentences.is_empty():
		sentences.append("Targets %s." % target)
	return " ".join(sentences)


## Writes each (edited) description into its scene. 0, or 1 when a file can't be read or written.
func apply_file(path: String) -> int:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_error("DescriptionPass: %s is not a JSON object" % path)
		return 1
	var written := 0
	for scene_path in parsed:
		if write_description(scene_path, str(parsed[scene_path])):
			written += 1
	print("DescriptionPass: %d description(s) written" % written)
	return 0 if written == parsed.size() else 1


## Adds or replaces the root node's `description = "..."` line. True when written.
static func write_description(scene_path: String, text: String) -> bool:
	var source := FileAccess.get_file_as_string(scene_path)
	if source == "":
		return false
	var lines := source.split("\n")
	var root := -1
	for index in lines.size():
		if lines[index].begins_with("[node ") and not lines[index].contains("parent="):
			root = index
			break
	if root < 0:
		return false
	var line := "description = %s" % JSON.stringify(text)
	var end := lines.size()
	for index in range(root + 1, lines.size()):
		if lines[index].begins_with("["):
			end = index
			break
		if lines[index].begins_with("description = "):
			lines[index] = line
			return _save(scene_path, "\n".join(lines))
	var insert := end
	while insert > root + 1 and lines[insert - 1].strip_edges() == "":
		insert -= 1
	lines.insert(insert, line)
	return _save(scene_path, "\n".join(lines))


static func _save(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	return true
