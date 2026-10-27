## Cost pass (spec skill-points 3.2, D5): sets each party ability's SP cost from a cost table you approved, through one
## shared cost effect per amount (effects/sp_cost_<n>.tres: an instant GameplayEffect running the SP cost ExecCalc).
## The table is a JSON file {"Ability.Tag": cost as typed, ...}; this tool holds no numbers. Prints one line per
## ability: "Ability.Fireburst  15 MP → 29 SP". Abilities the table doesn't name are left alone.
##
## Dry run by default. --write creates the missing sp_cost_<n>.tres files and points each listed ability's cost_effect
## at its file, as a text edit of the scene (the cost's ext_resource path, or one ext_resource line and one
## cost_effect line when the ability had no cost; nothing else in the file changes). It writes into the content root,
## so run it with --write only with the user's go-ahead.
##   godot --headless --path client-godot --quit-after 3000 res://game/tools/build_cost_pass.tscn
##     -- --table <costs.json> [--content-root res://content/] [--effects res://content/demo/effects/]
##        [--calc res://content/demo/exec_calcs/exec_calc_cost.gd] [--write]
## Exit 0, 3 when a table entry names no party ability, 1 on a tool error.
extends Node

const COST_ID := "sp_cost"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var root := _arg(args, "--content-root", "res://content/")
	var effects_dir := _arg(args, "--effects", "res://content/demo/effects/")
	var calc_path := _arg(args, "--calc", "res://content/demo/exec_calcs/exec_calc_cost.gd")
	var write := args.has("--write")
	var table: Variant = JSON.parse_string(FileAccess.get_file_as_string(_arg(args, "--table", "")))
	if not table is Dictionary:
		print("build_cost_pass: --table <file> must be a JSON object {\"Ability.Tag\": cost}")
		get_tree().quit(1)
		return
	var content := ContentIndex.new(root)
	var by_tag := {}
	for path in RolePass.party_scenes(content):
		var scene := load(path) as PackedScene
		if scene != null:
			by_tag[String(SkillTags.tag_of(scene))] = path
	var missing := 0
	var tags: Array = table.keys()
	tags.sort()
	for tag in tags:
		if not by_tag.has(tag):
			print("  ? %s: no party ability has this tag" % tag)
			missing += 1
			continue
		var path: String = by_tag[tag]
		var ability := (load(path) as PackedScene).instantiate() as BattleAbility
		var before := AbilityHint.cost_text(ability)
		ability.free()
		var typed := float(table[tag])
		var effect_path := effects_dir + "sp_cost_%s.tres" % _name_of(typed)
		print("  %s  %s → %s SP  (%s)" % [tag, before if before != "" else "free", _name_of(typed), effect_path.get_file()])
		if write:
			if not ResourceLoader.exists(effect_path) and not _save_cost(effect_path, calc_path, typed):
				get_tree().quit(1)
				return
			if not _point_cost(path, effect_path):
				get_tree().quit(1)
				return
	print("build_cost_pass: %d abilities in the table%s" % [tags.size(), ", written" if write else " (dry run; --write applies)"])
	get_tree().quit(3 if missing > 0 else 0)


## "29", or "12.5" for a typed fraction.
static func _name_of(typed: float) -> String:
	return str(int(typed)) if typed == floorf(typed) else str(typed)


## A new shared cost effect: instant, one execution of the cost ExecCalc at `typed` SP.
static func _save_cost(path: String, calc_path: String, typed: float) -> bool:
	var calc_script := load(calc_path) as Script
	if calc_script == null:
		print("build_cost_pass: no cost ExecCalc at %s" % calc_path)
		return false
	var calc: Resource = calc_script.new()
	calc.set("amount_x100", Fixed.from_typed(typed))
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INSTANT
	effect.executions.append(calc)
	var error := ResourceSaver.save(effect, path)
	if error != OK:
		print("build_cost_pass: could not save %s (%s)" % [path, error_string(error)])
		return false
	return true


## Points the scene's cost_effect at `effect_path` as a text edit: the existing cost ext_resource's path, or a new
## ext_resource line after the last one plus a cost_effect line after the root node's script line.
static func _point_cost(scene_path: String, effect_path: String) -> bool:
	var text := FileAccess.get_file_as_string(scene_path)
	var lines := text.split("\n")
	var cost_id := ""
	var root_at := -1
	for index in lines.size():
		var line := lines[index]
		if line.begins_with("cost_effect = ExtResource(\""):
			cost_id = line.trim_prefix("cost_effect = ExtResource(\"").trim_suffix("\")")
		if line.begins_with("[node ") and not line.contains(" parent=") and root_at < 0:
			root_at = index
	if cost_id != "":
		for index in lines.size():
			if lines[index].begins_with("[ext_resource ") and lines[index].contains("id=\"%s\"" % cost_id):
				var start := lines[index].find("path=\"") + 6
				var end := lines[index].find("\"", start)
				lines[index] = lines[index].substr(0, start) + effect_path + lines[index].substr(end)
	else:
		if root_at < 0:
			print("build_cost_pass: no root node in %s" % scene_path)
			return false
		var last_ext := -1
		for index in lines.size():
			if lines[index].begins_with("[ext_resource "):
				last_ext = index
		# After the root's script line: a property set before its script exists would be dropped.
		var after := root_at + 1
		if after < lines.size() and lines[after].begins_with("script = "):
			after += 1
		lines.insert(after, "cost_effect = ExtResource(\"%s\")" % COST_ID)
		lines.insert(last_ext + 1, "[ext_resource type=\"Resource\" path=\"%s\" id=\"%s\"]" % [effect_path, COST_ID])
	var file := FileAccess.open(scene_path, FileAccess.WRITE)
	if file == null:
		print("build_cost_pass: cannot write %s" % scene_path)
		return false
	file.store_string("\n".join(lines))
	file.close()
	return true


static func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
