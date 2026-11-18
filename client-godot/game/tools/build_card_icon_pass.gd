## Spec card-ui 3.5: the icon pass. Prints a game-icons glyph proposal for every item and armor card (the unmatched ones last);
## changes nothing unless told to.
##   godot --headless --path client-godot --quit-after 600 res://game/tools/build_card_icon_pass.tscn
##     [-- --content-root res://content/] [--source <game-icons 1x1 folder>] [--out <report.json>]
##        --apply   copies the used glyphs into presentation/demo/cards/icons/<author>/ (new files only) and writes
##                  presentation/demo/cards/card_icons.tres if it does not exist (--force rewrites it); then run
##                  `godot --headless --path client-godot --import` so the SVGs become textures
extends Node


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var content := ContentIndex.new(_arg(args, "--content-root", "res://content/"))
	var source := _arg(args, "--source", CardIconPass.DEFAULT_SOURCE)
	if CardIconPass.index(source).is_empty():
		printerr("build_card_icon_pass: no icons in %s (--source <folder of author folders>)" % source)
		get_tree().quit(3)
		return
	var rows := CardIconPass.propose(content, source)
	print(CardIconPass.report(rows))
	var out := _arg(args, "--out", "")
	if out != "":
		var file := FileAccess.open(out, FileAccess.WRITE)
		if file == null:
			printerr("build_card_icon_pass: can't write ", out)
			get_tree().quit(1)
			return
		file.store_string(WireJson.stringify({"cards": rows}))
		file.close()
	if args.has("--apply"):
		var result := CardIconPass.apply(rows, source, CardIconPass.DEST_DIR, CardArtSet.ICONS_PATH, args.has("--force"))
		print("copied %d, kept %d, wrote %s" % [result["copied"].size(), result["skipped"].size(), result["wrote"] if result["wrote"] != "" else "nothing"])
		for problem in result["problems"]:
			printerr("build_card_icon_pass: ", problem)
		if not result["problems"].is_empty():
			get_tree().quit(2)  # a glyph missing or not copied: some card has no art
			return
	get_tree().quit(0)


func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
