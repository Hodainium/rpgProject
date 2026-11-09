## Headless smoke run of the effects (spec vfx-framework 6): validates and plays every effect (or `--id`) at every quality
## tier on a scripted clock and prints JSON. Exit 0 all fine, 3 a problem, a layer that never ended or an effect that did
## not play, 1 tool error (an unknown id).
##   godot --headless --path client-godot --quit-after 3000 res://game/tools/fx_smoke.tscn [-- --all | --id <id>] [--param k=v ...] [--tiers low,high]
extends Node


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var ids: Array = []
	if args.has("--id"):
		ids.append(_arg(args, "--id", ""))
	var params := {}
	for index in args.size():
		if args[index] == "--param" and index + 1 < args.size() and args[index + 1].contains("="):
			var parts := args[index + 1].split("=", true, 1)
			params[parts[0]] = parts[1]
	var tiers: Array = []
	for name in _arg(args, "--tiers", "off,low,medium,high").split(","):
		var tier := FxQuality.NAMES.find(name.strip_edges())
		if tier >= 0:
			tiers.append(tier)
	if FxManager.catalog().is_empty():
		print("fx_smoke: no effects (registry %s)" % FxService.DEFAULT_REGISTRY)
		get_tree().quit(1)
		return
	for id in ids:
		if FxManager.definition(StringName(id)) == null:
			print("fx_smoke: no effect '%s'" % id)
			get_tree().quit(1)
			return
	var results := FxSmoke.run(self, FxManager, ids, tiers, params)
	print(JSON.stringify(results, "  "))
	get_tree().quit(0 if FxSmoke.all_ok(results) else 3)


static func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
