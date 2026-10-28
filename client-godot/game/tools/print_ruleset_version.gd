## Prints the ruleset version (spec server-authority 3.5) for deployment (the server's Ruleset:Accepted), or stamps it
## for an export. Exit 0, or 1 when the stamp can't be written:
##   godot --headless --path client-godot --quit-after 3000 res://game/tools/print_ruleset_version.tscn
##     [-- --stamp]   writes RulesetVersion.STAMP_PATH (tools/export.sh does this, then removes it)
##     [-- --files]   also lists the hashed files
extends Node


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var version := RulesetVersion.compute()
	if args.has("--files"):
		for path in RulesetVersion.files():
			print(path)
	print(version)
	if args.has("--stamp"):
		var stamp := RulesetStamp.new()
		stamp.version = version
		var error := ResourceSaver.save(stamp, RulesetVersion.STAMP_PATH)
		if error != OK:
			printerr("print_ruleset_version: can't write %s (error %d)" % [RulesetVersion.STAMP_PATH, error])
			get_tree().quit(1)
			return
		print("print_ruleset_version: stamped ", RulesetVersion.STAMP_PATH)
	get_tree().quit(0)
