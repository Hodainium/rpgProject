## Headless seed statistics (spec dev-tools 2.5): the SeedReport for many seeds as JSON, for tuning FloorGenRules.
## Exit 0 (no failures), 3 (some seeds failed to generate), 1 (tool error).
##   godot --headless --path client-godot --quit-after 100000 res://game/tools/seed_report.tscn
##     -- [--content-root res://content/] [--run <id>] [--from 1] [--count 1000] [--floor 0] [--route <chapter id>]
##        [--out report.json]
## With --play (spec playable-demo 2.3, 2.3b) it plays each seed instead (PlayReport): exit 0, 3 when a run was
## stopped or (chaos, --check) an invariant broke; failing battles are saved next to --out.
##     -- --play [--policy auto|smart|chaos] [--illegal 20] [--chaos 100] [--chaos-from 1] [--check] [--trace]
##        [--party a,b] [--max-steps 2000]   (chaos below 100% or from a later floor plays on top of smart)
##   (give --quit-after a large frame count: every battle step takes frames)
extends Node


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var root := _arg(args, "--content-root", "res://content/")
	var content := ContentIndex.new(root)
	var run_id := StringName(_arg(args, "--run", ""))
	var picked := RunController.pick_run(content, run_id)
	if picked["error"] != "":
		print("seed_report: %s: %s" % [root, picked["error"]])
		get_tree().quit(1)
		return
	if args.has("--play"):
		await _play(content, args)
		return
	var report := SeedReport.many(content, int(_arg(args, "--from", "1")), int(_arg(args, "--count", "1000")),
		int(_arg(args, "--floor", "0")), null, run_id, StringName(_arg(args, "--route", "")))
	print(SeedReport.text(report))
	var out := _arg(args, "--out", "")
	if out != "":
		var file := FileAccess.open(out, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "  ", false))
		file.close()
	get_tree().quit(3 if not report["failures"].is_empty() else 0)


func _play(content: ContentIndex, args: PackedStringArray) -> void:
	var policy := _arg(args, "--policy", "auto")
	if not PlayReport.POLICIES.has(policy):
		print("seed_report: --policy is one of %s" % ", ".join(PlayReport.POLICIES))
		get_tree().quit(1)
		return
	var party: Array = []
	for id in _arg(args, "--party", "").split(",", false):
		party.append(id.strip_edges())
	var options := {"run": _arg(args, "--run", ""), "party": party, "policy": policy,
		"illegal": int(_arg(args, "--illegal", "20")), "check": args.has("--check"), "trace": args.has("--trace"),
		"max_steps": int(_arg(args, "--max-steps", "2000")), "chaos": int(_arg(args, "--chaos", "100")),
		"chaos_from": int(_arg(args, "--chaos-from", "1"))}
	var report := await PlayReport.many(content, self, int(_arg(args, "--from", "1")), int(_arg(args, "--count", "100")),
		options)
	var failures: Array = report["failures"]
	report.erase("failures")
	print(PlayReport.text(report))
	var out := _arg(args, "--out", "")
	if out != "":
		var file := FileAccess.open(out, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "  ", false))
		file.close()
		for path in PlayReport.save_failures(failures, out):
			print("  saved " + path)
	var stopped: bool = report["stopped"] > 0 or not report["violations"].is_empty()
	get_tree().quit(3 if stopped else 0)


static func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
