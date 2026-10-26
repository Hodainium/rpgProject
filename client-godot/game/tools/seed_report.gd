## Headless seed statistics (spec dev-tools 2.5): the SeedReport for many seeds as JSON, for tuning FloorGenRules.
## Exit 0 (no failures), 3 (some seeds failed to generate), 1 (tool error).
##   godot --headless --path client-godot --quit-after 100000 res://game/tools/seed_report.tscn
##     -- [--content-root res://content/] [--run <id>] [--from 1] [--count 1000] [--floor 0] [--route <chapter id>]
##        [--out report.json]
## With --play (spec playable-demo 2.3, 2.3b) it plays each seed instead (PlayReport): exit 0, 3 when a run was
## stopped or (chaos, --check) an invariant broke; failing battles are saved next to --out.
##     -- --play [--policy auto|smart|chaos] [--illegal 20] [--chaos 100] [--chaos-from 1] [--check] [--trace]
##        [--party a,b | --party-size 1-4|mixed (default 4)] [--max-steps 2000]   (chaos below 100% or from a later floor plays on top of smart)
##   (give --quit-after a large frame count: every battle step takes frames)
## Shards (spec playable-demo 2.3d): run seed ranges in parallel processes with --records, then
##     -- --merge shard1.json shard2.json ... --out all.json   (game/tools/play_sharded.sh does both)
## Every mode also exits 3 on any script or engine error (ScriptErrorLog), printed at the end; with --play they are in
## the report too ("errors", per seed).
extends Node

var _errors := ScriptErrorLog.new()


func _ready() -> void:
	OS.add_logger(_errors)
	var args := OS.get_cmdline_user_args()
	var root := _arg(args, "--content-root", "res://content/")
	var content := ContentIndex.new(root)
	var run_id := StringName(_arg(args, "--run", ""))
	var picked := RunController.pick_run(content, run_id)
	if picked["error"] != "":
		print("seed_report: %s: %s" % [root, picked["error"]])
		_quit(1)
		return
	if args.has("--merge"):
		_merge(args)
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
	_quit(3 if not report["failures"].is_empty() else 0)


func _play(content: ContentIndex, args: PackedStringArray) -> void:
	var policy := _arg(args, "--policy", "auto")
	if not PlayReport.POLICIES.has(policy):
		print("seed_report: --policy is one of %s" % ", ".join(PlayReport.POLICIES))
		_quit(1)
		return
	var party: Array = []
	for id in _arg(args, "--party", "").split(",", false):
		party.append(id.strip_edges())
	var options := {"run": _arg(args, "--run", ""), "party": party, "policy": policy,
		"illegal": int(_arg(args, "--illegal", "20")), "check": args.has("--check"), "trace": args.has("--trace"),
		"max_steps": int(_arg(args, "--max-steps", "2000")), "chaos": int(_arg(args, "--chaos", "100")),
		"chaos_from": int(_arg(args, "--chaos-from", "1")),
		"party_size": _arg(args, "--party-size", "4") if _arg(args, "--party-size", "4") == "mixed" else int(_arg(args, "--party-size", "4"))}
	var report := await PlayReport.many(content, self, int(_arg(args, "--from", "1")), int(_arg(args, "--count", "100")),
		options, true)
	var failures: Array = report["failures"]
	report.erase("failures")
	var records: Array = report["records"]
	var shard_options: Dictionary = report["options"]
	report.erase("records")
	report.erase("options")
	print(PlayReport.text(report))
	var out := _arg(args, "--out", "")
	if out != "":
		var file := FileAccess.open(out, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "  ", false))
		file.close()
		for path in PlayReport.save_failures(failures, out):
			print("  saved " + path)
		if args.has("--records"):
			var shard := FileAccess.open(out.get_basename() + ".records.json", FileAccess.WRITE)
			shard.store_string(JSON.stringify({"options": shard_options, "records": records}))
			shard.close()
	var stopped: bool = report["stopped"] > 0 or not report["violations"].is_empty()
	_quit(3 if stopped else 0, report["errors"])


## --merge a.json b.json ... --out all.json: one report from shards written with --records (spec playable-demo 2.3d).
func _merge(args: PackedStringArray) -> void:
	var shards: Array = []
	var at := args.find("--merge") + 1
	while at < args.size() and not args[at].begins_with("--"):
		var text := FileAccess.get_file_as_string(args[at].get_basename() + ".records.json")
		var parsed: Variant = JSON.parse_string(text) if text != "" else null
		if not parsed is Dictionary:
			print("seed_report: no records for %s (run the shard with --records)" % args[at])
			_quit(1)
			return
		shards.append(parsed)
		at += 1
	if shards.is_empty():
		print("seed_report: --merge needs shard reports")
		_quit(1)
		return
	var report := PlayReport.merge(shards)
	print(PlayReport.text(report))
	var out := _arg(args, "--out", "")
	if out != "":
		var file := FileAccess.open(out, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "  ", false))
		file.close()
	# The shards' errors are in the report (their processes exited 3 already); this process only checks its own.
	if not report["errors"].is_empty():
		print("seed_report: the shards had %d script or engine error(s)" % report["errors"].size())
	_quit(3 if report["stopped"] > 0 or not report["violations"].is_empty() or not report["errors"].is_empty() else 0)


## Quits with `code`, or 3 when this process raised script or engine errors (printed, except those already in the
## play report's `reported` list).
func _quit(code: int, reported: Array = []) -> void:
	var errors := _errors.take()
	OS.remove_logger(_errors)
	for entry in reported:
		errors.erase(entry["error"])
	if not errors.is_empty() or not reported.is_empty():
		print("seed_report: %d script or engine error(s)" % (errors.size() + reported.size()))
		for text in errors.slice(0, 20):
			print("  " + text)
		if code == 0:
			code = 3
	get_tree().quit(code)


static func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
