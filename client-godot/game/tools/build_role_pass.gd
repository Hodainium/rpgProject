## Role pass (spec auto-battle A6): proposes the Ability.Role.* asset tags each party ability needs, read from what it
## does: Revive from dead-ally targeting; Damage (a SCALED / FLAT row, or an instant effect with an ExecCalc) and Debuff
## (a row granting Status.Debuff.*) and Dispel (an effect removing Status.Buff) on enemy moves; Heal (an effect adding
## to hp, Regen, or a heal word in the effect's file name, the old smart-policy guess), Buff (an effect granting
## Status.Buff.*) and Cleanse (an effect removing Status.Debuff) on ally moves. Prints one line per ability that gains a
## role ("+Ability.Role.Heal") or has none to propose ("? no role found": a human decides). Triggered passives need none.
##
## Dry run by default. --write adds the missing tags to each scene's root node `asset_tags` line as a text edit (nothing
## else in the file changes). Party abilities only (characters' abilities and learnable skills, items' use abilities,
## item and equipment grants); --all: every ability scene under the root.
##   godot --headless --path client-godot --quit-after 3000 res://game/tools/build_role_pass.tscn
##     [-- --content-root res://content/] [--all] [--write]
## Exit 0, or 3 while an ability has no role to propose.
class_name RolePass
extends Node

const HEAL_WORDS: Array[String] = ["heal", "regen", "mend", "sanctuary", "salve", "holy", "potion", "restore"]
const REGEN_TAG: StringName = &"Status.Buff.Regen"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var root := _arg(args, "--content-root", "res://content/")
	var content := ContentIndex.new(root)
	var scenes := all_scenes(root) if args.has("--all") else party_scenes(content)
	var unresolved := 0
	var changed := 0
	for path in scenes:
		var scene := load(path) as PackedScene
		var ability := scene.instantiate() as BattleAbility if scene != null else null
		if ability == null:
			continue
		if ability.is_triggered():
			ability.free()
			continue
		var proposed := roles_of(ability)
		var missing := proposed.filter(func(role: StringName) -> bool: return not ability.asset_tags.has(role))
		var has_any := ability.asset_tags.any(func(tag) -> bool: return String(tag).begins_with(AutoPolicy.ROLE_PREFIX))
		ability.free()
		if missing.is_empty() and (has_any or not proposed.is_empty()):
			continue
		if proposed.is_empty() and not has_any:
			unresolved += 1
			print("%s: ? no role found" % path)
			continue
		print("%s: %s" % [path, " ".join(missing.map(func(role) -> String: return "+" + String(role)))])
		if args.has("--write"):
			var error := add_tags(path, missing)
			if error != "":
				print("  not written: ", error)
				unresolved += 1
			else:
				changed += 1
	print("role pass: %d scene(s), %d to tag%s, %d without a role" % [scenes.size(), changed,
		" (written)" if args.has("--write") else "", unresolved])
	get_tree().quit(3 if unresolved > 0 else 0)


## The roles `ability` shows by its targeting and rows (AutoPolicy.ROLES order).
static func roles_of(ability: BattleAbility) -> Array[StringName]:
	var found := {}
	if ability.targets_dead():
		found[AutoPolicy.ROLE_REVIVE] = true
	for row in ability.executions:
		if row == null:
			continue
		var effect := row.effect
		if ability.targets_enemies():
			if row.damage_mode != ExecutionRow.DamageMode.USE_EFFECT \
					or effect != null and effect.policy == GameplayEffect.DurationPolicy.INSTANT and not effect.executions.is_empty():
				found[AutoPolicy.ROLE_DAMAGE] = true
			if row.applies_debuff():
				found[AutoPolicy.ROLE_DEBUFF] = true
			if effect != null and _removes(effect, AutoPolicy.BUFF_TAG):
				found[AutoPolicy.ROLE_DISPEL] = true
		elif effect != null and not ability.targets_dead():
			if _heals(effect):
				found[AutoPolicy.ROLE_HEAL] = true
			if effect.granted_tags.any(func(tag) -> bool: return String(tag).begins_with(AutoPolicy.BUFF_TAG + ".")):
				found[AutoPolicy.ROLE_BUFF] = true
			if _removes(effect, Battle.DEBUFF_TAG):
				found[AutoPolicy.ROLE_CLEANSE] = true
			if _adds(effect, "mp"):
				found[AutoPolicy.ROLE_RESTORE_MP] = true
	var roles: Array[StringName] = []
	for role in AutoPolicy.ROLES:
		if found.has(role):
			roles.append(role)
	return roles


static func _heals(effect: GameplayEffect) -> bool:
	if effect.granted_tags.has(REGEN_TAG):
		return true
	if _adds(effect, "hp"):
		return true
	var file := effect.resource_path.get_file().to_lower()
	return HEAL_WORDS.any(func(word: String) -> bool: return file.contains(word))


## A modifier on `effect` adds a positive amount to `attribute`, or an ExecCalc restores it (`attribute` and a positive
## `percent_x100`, like the food percent-of-max calc).
static func _adds(effect: GameplayEffect, attribute: String) -> bool:
	var modifies := effect.modifiers.any(func(modifier) -> bool:
		return modifier != null and modifier.attribute_name == attribute and modifier.get("value_x100") != null \
			and int(modifier.get("value_x100")) > 0)
	return modifies or effect.executions.any(func(calc) -> bool:
		return calc != null and calc.get("attribute") == attribute and calc.get("percent_x100") != null \
			and int(calc.get("percent_x100")) > 0)


static func _removes(effect: GameplayEffect, prefix: String) -> bool:
	return effect.remove_effects_with_tags.any(func(tag) -> bool:
		return String(tag) == prefix or String(tag).begins_with(prefix + "."))


## Ability scenes a party member can use: characters' abilities and learnable skills, items' use abilities, item and
## equipment grants. Sorted paths.
static func party_scenes(content: ContentIndex) -> Array[String]:
	var found := {}
	for id in content.units:
		var unit: UnitDefinition = content.units[id]
		if not unit is CharacterDefinition:
			continue
		for scene in unit.abilities + unit.learnable_skills:
			if scene != null:
				found[scene.resource_path] = true
		for row in unit.level_skills:  # spec skill-points: learned skills and ranks
			if row != null and row.ability != null:
				found[row.ability.resource_path] = true
	for id in content.items:
		var item: ItemDefinition = content.items[id]
		if item.use_ability != null:
			found[item.use_ability.resource_path] = true
		_grants(item.grants, found)
	for id in content.equipment:
		_grants(content.equipment[id].grants, found)
	var paths: Array[String] = []
	paths.assign(found.keys())
	paths.sort()
	return paths


static func _grants(ability_set: AbilitySet, found: Dictionary) -> void:
	if ability_set == null:
		return
	for scene in ability_set.abilities:
		if scene != null:
			found[scene.resource_path] = true


static func all_scenes(root: String) -> Array[String]:
	var paths: Array[String] = []
	_walk(root, paths)
	paths.sort()
	return paths


static func _walk(dir_path: String, paths: Array[String]) -> void:
	for sub in DirAccess.get_directories_at(dir_path):
		_walk(dir_path.path_join(sub), paths)
	for file in DirAccess.get_files_at(dir_path):
		if file.ends_with(".tscn") and SkillTags.tag_of(load(dir_path.path_join(file))) != &"":
			paths.append(dir_path.path_join(file))


## Adds `tags` to the root node's asset_tags line of the scene at `path` (a text edit). "" or why not.
static func add_tags(path: String, tags: Array) -> String:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return "can't read"
	var lines := text.split("\n")
	var start := -1
	for index in lines.size():
		if lines[index].begins_with("[node ") and not lines[index].contains(" parent="):
			start = index
			break
	if start < 0:
		return "no root node"
	var end := lines.size()
	for index in range(start + 1, lines.size()):
		if lines[index].begins_with("["):
			end = index
			break
	var quoted := PackedStringArray(tags.map(func(tag) -> String: return "&\"%s\"" % tag))
	var done := false
	for index in range(start + 1, end):
		if lines[index].begins_with("asset_tags = Array[StringName]([") and lines[index].ends_with("])"):
			var inner := lines[index].trim_prefix("asset_tags = Array[StringName]([").trim_suffix("])")
			lines[index] = "asset_tags = Array[StringName]([%s])" % ", ".join(([inner] if inner != "" else []) + Array(quoted))
			done = true
			break
	if not done:
		var at := start + 1
		for index in range(start + 1, end):
			if lines[index].begins_with("script = ") or lines[index].begins_with("targeting = "):
				at = index + 1
		lines.insert(at, "asset_tags = Array[StringName]([%s])" % ", ".join(quoted))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "can't write"
	file.store_string("\n".join(lines))
	file.close()
	return ""


static func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
