## Headless seed statistics (spec dev-tools 2.5): the SeedReport for many seeds as JSON, for tuning FloorGenRules.
## Exit 0 (no failures), 3 (some seeds failed to generate), 1 (tool error).
##   godot --headless --path client-godot --quit-after 100000 res://game/tools/seed_report.tscn
##     -- [--content-root res://content/] [--from 1] [--count 1000] [--floor 0] [--out report.json]
extends Node


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var root := _arg(args, "--content-root", "res://content/")
	var content := ContentIndex.new(root)
	if content.runs.size() != 1:
		print("seed_report: %s needs exactly one RunStructure" % root)
		get_tree().quit(1)
		return
	var report := SeedReport.many(content, int(_arg(args, "--from", "1")), int(_arg(args, "--count", "1000")),
		int(_arg(args, "--floor", "0")))
	print(SeedReport.text(report))
	var out := _arg(args, "--out", "")
	if out != "":
		var file := FileAccess.open(out, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "  ", false))
		file.close()
	get_tree().quit(3 if not report["failures"].is_empty() else 0)


static func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
