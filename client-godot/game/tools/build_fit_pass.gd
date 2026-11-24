## Fit pass (spec bot-play 2.3; the build_role_pass pattern): proposes the Item.Fit.* and Item.Grants.* tags each item
## and gear piece needs from its GAS data (FitProposal), so the run bots know who should hold it. Prints one line per
## file that gains a tag ("+Item.Fit.Damage +Item.Grants.FollowUp") or has nothing to propose ("? none found": a human
## decides). Dev items (the Dev tag) are skipped.
##
## Dry run by default. --write adds the missing tags to the resource's `tags` line as a text edit (nothing else in the
## file changes; a file with no tags line gets one after its id). It edits existing design files in content/: run it
## with --write only with the user's OK.
##   godot --headless --path client-godot --quit-after 3000 res://game/tools/build_fit_pass.tscn
##     [-- --content-root res://content/] [--write]
## Exit 0, or 3 while a pooled thing has nothing to propose and no fit yet.
class_name FitPass
extends Node


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var root := _arg(args, "--content-root", "res://content/")
	var content := ContentIndex.new(root)
	var write := args.has("--write")
	var unresolved := 0
	var changed := 0
	var lines := report(content)
	for row in lines:
		print(row["line"])
		if row["unresolved"]:
			unresolved += 1
		if write and not row["missing"].is_empty():
			var error := add_tags(row["path"], row["missing"])
			if error != "":
				print("  not written: ", error)
				unresolved += 1
			else:
				changed += 1
	print("fit pass: %d item(s) and piece(s), %d to tag%s, %d with nothing found" % [content.items.size()
		+ content.equipment.size(), lines.filter(func(row) -> bool: return not row["missing"].is_empty()).size(),
		" (%d written)" % changed if write else "", unresolved])
	get_tree().quit(3 if unresolved > 0 else 0)


## One row per item or piece that needs a line, sorted by path: {"path", "missing" (tags to add), "unresolved" (a pooled
## thing with no fit and nothing proposed), "line"}.
static func report(content: ContentIndex) -> Array[Dictionary]:
	var things: Array = []
	for table in [content.items, content.equipment]:
		for id in table:
			things.append(table[id])
	things.sort_custom(func(a: Resource, b: Resource) -> bool: return a.resource_path < b.resource_path)
	var rows: Array[Dictionary] = []
	for thing in things:
		if TagMatch.has(thing.tags, FloorGenerator.DEV_TAG):
			continue
		var missing := FitProposal.missing(thing)
		var has_fit: bool = thing.tags.any(func(tag) -> bool: return String(tag).begins_with(LootScorer.FIT_PREFIX))
		if not missing.is_empty():
			rows.append({"path": thing.resource_path, "missing": missing, "unresolved": false,
				"line": "%s: %s" % [thing.resource_path, " ".join(missing.map(func(tag) -> String: return "+" + String(tag)))]})
		elif not has_fit:
			var pooled: bool = thing.tags.any(func(tag) -> bool: return String(tag).begins_with("Pool."))
			rows.append({"path": thing.resource_path, "missing": [], "unresolved": pooled,
				"line": "%s: ? none found" % thing.resource_path})
	return rows


## Adds `tags` to the [resource] section's `tags` line of the .tres at `path` (a text edit). "" or why not.
static func add_tags(path: String, tags: Array) -> String:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return "can't read"
	var lines := text.split("\n")
	var start := lines.find("[resource]")
	if start < 0:
		return "no [resource] section"
	var end := lines.size()
	for index in range(start + 1, lines.size()):
		if lines[index].begins_with("["):
			end = index
			break
	var quoted := PackedStringArray(tags.map(func(tag) -> String: return "&\"%s\"" % tag))
	var done := false
	for index in range(start + 1, end):
		if lines[index].begins_with("tags = Array[StringName]([") and lines[index].ends_with("])"):
			var inner := lines[index].trim_prefix("tags = Array[StringName]([").trim_suffix("])")
			lines[index] = "tags = Array[StringName]([%s])" % ", ".join(([inner] if inner != "" else []) + Array(quoted))
			done = true
			break
		if lines[index].begins_with("tags = "):
			return "its tags line is not one Array[StringName] line"
	if not done:
		var at := -1
		for index in range(start + 1, end):
			if lines[index].begins_with("id = "):
				at = index + 1
				break
		if at < 0:
			return "no id line"
		lines.insert(at, "tags = Array[StringName]([%s])" % ", ".join(quoted))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "can't write"
	file.store_string("\n".join(lines))
	file.close()
	return ""


static func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
