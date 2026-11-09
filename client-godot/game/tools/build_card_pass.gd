## Proposes the card sets and the core set for a content root (spec card-collection 3.6) and reports it; changes nothing unless
## told to. Same shape as the other proposal passes (build_usage_pass, build_role_pass).
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_card_pass.tscn
##     [-- --content-root res://content/] [--out <report.json>]
##        --rules <path.tres>          uses these rules in memory when the content root has none (a dry run: nothing is written to content)
##        --create-rules <path.tres>   writes a CardRules resource with the spec defaults (30/30/15/15, Boss and Void all core,
##                                     six starter characters) if the file does not exist; never overwrites
##        --apply                      appends each proposed Card.Set tag to its definition file (a text patch of the one tags
##                                     line). Edits the user's design files: run only with their go-ahead
## The report lists the core cards, the per-pool core counts against the targets, the pools still short and the overshoot.
extends Node

## The spec's starter characters (6; the user confirms or changes them in the resource).
const STARTERS: Array[String] = ["demo.character.warrior", "demo.character.cleric", "demo.character.arcanist",
	"demo.character.ranger", "demo.character.bard", "demo.character.bulwark"]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var root := _arg(args, "--content-root", "res://content/")
	var rules_path := _arg(args, "--create-rules", "")
	if rules_path != "":
		var code := _create_rules(rules_path)
		if code != 0:
			get_tree().quit(code)
			return
	var content := ContentIndex.new(root)
	var rules_file := _arg(args, "--rules", rules_path)
	if rules_file != "" and content.card_rules.is_empty() and FileAccess.file_exists(rules_file):
		var loaded: CardRules = load(rules_file)  # a preview: rules from anywhere (user://), not part of the content root
		content.card_rules[loaded.id] = loaded
	if content.card_rules.is_empty():
		printerr("build_card_pass: %s has no CardRules resource; pass --create-rules <path.tres> to make one" % root)
		get_tree().quit(3)
		return
	var proposal := CardCorePass.propose(content)
	var lines := PackedStringArray()
	lines.append("cards: %d (core items %d, starter characters %d)" % [proposal["tags"].size(), proposal["core_items"].size(),
		proposal["core_characters"].size()])
	for pool in proposal["counts"]:
		lines.append("  %s: %d core, target %d%s" % [pool, proposal["counts"][pool][0], proposal["counts"][pool][1],
			"  (SHORT)" if proposal["short"].has(pool) else ("  (+%d over)" % proposal["overshoot"][pool] if proposal["overshoot"].has(pool) else "")])
	print("\n".join(lines))
	var out := _arg(args, "--out", "")
	if out != "":
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var file := FileAccess.open(out, FileAccess.WRITE)
		if file == null:
			printerr("build_card_pass: can't write " + out)
			get_tree().quit(1)
			return
		file.store_string(WireJson.stringify(_plain(proposal)))
		file.close()
		print("build_card_pass: report → ", out)
	if args.has("--apply"):
		var changed := CardCorePass.apply(content, proposal)
		for path in changed:
			print("tagged ", path)
		print("build_card_pass: %d file(s) tagged" % changed.size())
	get_tree().quit(0)


func _create_rules(path: String) -> int:
	if FileAccess.file_exists(path):
		print("build_card_pass: %s exists; left as it is" % path)
		return 0
	var rules := CardRules.new()
	rules.id = &"demo.cards.rules"
	rules.pool_targets = {&"Pool.Treasure": 30, &"Pool.Shop": 30, &"Pool.Void": 15}
	rules.all_core_pools.assign([&"Pool.Boss", &"Pool.Void"])
	for id in STARTERS:
		rules.starter_characters.append(StringName(id))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := ResourceSaver.save(rules, path)
	if error != OK:
		printerr("build_card_pass: can't write %s (error %d)" % [path, error])
		return 1
	print("build_card_pass: wrote ", path)
	return 0


## StringNames to strings, so the report is plain JSON.
func _plain(value: Variant) -> Variant:
	if value is Dictionary:
		var copy := {}
		for key in value:
			copy[String(key)] = _plain(value[key])
		return copy
	if value is Array:
		return value.map(func(item: Variant) -> Variant: return _plain(item))
	return String(value) if value is StringName else value


func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
