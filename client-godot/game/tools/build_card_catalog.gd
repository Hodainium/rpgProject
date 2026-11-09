## Exports the card catalog (spec card-collection 2.1): every item and piece of equipment in a pool, and every character, with
## its rarity, set, core flag and pools, plus a hash of the list, as the server's `infra/economy/card_catalog.json`. The
## server seeds its catalog from this file (Cards:CatalogFile) and never reads item data itself.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_card_catalog.tscn
##     [-- --content-root res://content/] [--out <path>]      default out: infra/economy/card_catalog.json in the repo
## Exit 0 written; 3 the content has card problems (a card with no set or rarity, no cards at all …) and nothing is written.
## Run it after the card set tags are in the content (build_card_pass proposes them).
extends Node

const DEFAULT_OUT: String = "../infra/economy/card_catalog.json"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var root := _arg(args, "--content-root", "res://content/")
	var out := _arg(args, "--out", ProjectSettings.globalize_path("res://").path_join(DEFAULT_OUT).simplify_path())
	var content := ContentIndex.new(root)
	var problems: Array = CardCatalog.problems(content)
	var cards := CardCatalog.cards(content)
	var failed := PackedStringArray()
	for problem in problems:
		failed.append("%s %s: %s" % [problem[0], problem[1], problem[2]])
	if cards.is_empty():
		failed.append("no cards in %s" % root)
	for card in cards:
		if card["setId"] == "":
			failed.append("%s has no Card.Set tag" % card["id"])
		if card["kind"] == CardCatalog.KIND_ITEM and card["rarity"] == "":
			failed.append("%s has no Item.Rarity tag" % card["id"])
	if not content.problems.is_empty():
		failed.append_array(content.problems)
	if not failed.is_empty():
		for line in failed:
			printerr("build_card_catalog: " + line)
		get_tree().quit(3)
		return
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var file := FileAccess.open(out, FileAccess.WRITE)
	if file == null:
		printerr("build_card_catalog: can't write " + out)
		get_tree().quit(1)
		return
	file.store_string(WireJson.stringify(CardCatalog.catalog_file(content)))
	file.close()
	var core := 0
	for card in cards:
		core += 1 if card["core"] else 0
	print("build_card_catalog: %d cards (%d core) → %s" % [cards.size(), core, out])
	get_tree().quit(0)


func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
