## The effects system from the console (spec vfx-framework 6, dev tools): list the effects, show a parameter table, play
## one with `key=value` parameters, stop everything, see the counters, validate, set the quality tier, log plays on the
## message bus. Headless there is no picture, so `play` switches the system on for that call, runs the effect to its end
## on a scripted clock and reports it (a looping effect is stopped after 2 s). Presentation only.
extends DevCommand

const STEP: float = 1.0 / 30.0


func _init() -> void:
	name = "fx"
	usage = "fx list [tag] | params <id> | play <id> [key=value ...] [at=screen|origin|unit:<id>] | stop | stats | check [id] | quality [off|low|medium|high [save]] | log [on|off]"
	help = "Visual effects (spec vfx-framework): list, params <id>, play <id> color=#ff9a00 scale=1.5 at=unit:P1, stop, stats, check, quality, log."
	cheat = false
	arg_kinds.assign(["fx_op", "fx", "text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	var op := args[0] if args.size() > 0 else "list"
	match op:
		"list":
			var lines := PackedStringArray()
			for id in FxManager.catalog():
				var definition := FxManager.definition(id)
				if args.size() > 1 and not definition.tags.has(StringName(args[1])):
					continue
				lines.append("%-28s %-8s %d layers%s" % [id, FxDefinition.Space.keys()[definition.space].to_lower(),
					definition.layers.size(), "  loops" if definition.is_looping() else ""])
			return "\n".join(lines) if not lines.is_empty() else "no effects (the registry is %s)" % FxService.DEFAULT_REGISTRY
		"params":
			var definition := _find(args, 1)
			if definition == null:
				return ctx.fail("no effect '%s' (fx list)" % (args[1] if args.size() > 1 else ""))
			var lines := PackedStringArray(["%s: %s" % [definition.id, definition.display_name if definition.display_name != "" else "-"]])
			for spec in definition.params:
				lines.append("  " + (spec.describe() if spec != null else "! an empty parameter slot (fx check)"))
			for layer in definition.layers:
				if layer == null:
					lines.append("  ! an empty layer slot (fx check)")
				else:
					lines.append("  layer %-14s %-12s from %.2fs%s" % [layer.id, layer.kind(), layer.start_delay, "  loops" if layer.loop else ""])
			return "\n".join(lines)
		"play":
			return _play(ctx, args)
		"stop":
			var count := FxManager.live_count()
			FxManager.stop_all()
			return "stopped %d effect(s)" % count
		"stats":
			var stats := FxManager.stats()
			var by_id: Dictionary = stats["by_id"]
			var lines := PackedStringArray()
			for key in stats:
				if key != "by_id":
					lines.append("%-10s %s" % [key, stats[key]])
			for id in by_id:
				lines.append("  played %-26s %d" % [id, by_id[id]])
			return "\n".join(lines)
		"check":
			var issues: Array[ValidationIssue] = []
			for id in FxManager.catalog():
				if args.size() > 1 and String(id) != args[1]:
					continue
				issues.append_array(FxValidator.check(FxManager.definition(id)))
			if issues.is_empty():
				return "fx check: no problems in %s" % (args[1] if args.size() > 1 else "%d effects" % FxManager.catalog().size())
			ctx.failed = true
			return "\n".join(PackedStringArray(issues.map(func(issue: ValidationIssue) -> String: return str(issue))))
		"quality":
			if args.size() > 1:
				var tier := FxQuality.NAMES.find(args[1].to_lower())
				if tier < 0:
					return ctx.fail("quality is one of %s" % ", ".join(FxQuality.NAMES))
				FxManager.quality = tier
				if args.size() > 2 and args[2] == "save":
					GameMain.save_setting(FxService.SETTINGS_SECTION, FxService.SETTINGS_KEY, FxQuality.NAMES[tier])
			return "fx quality: %s" % FxQuality.NAMES[FxManager.quality]
		"log":
			if args.size() > 1:
				FxManager.dev_messages = args[1] == "on"
			return "fx log: %s (messages on Message.Dev.Fx shows it)" % ("on" if FxManager.dev_messages else "off")
	return ctx.fail("usage: " + usage)


func _find(args: PackedStringArray, at: int) -> FxDefinition:
	return FxManager.definition(StringName(args[at])) if args.size() > at else null


func _play(ctx: DevContext, args: PackedStringArray) -> String:
	var definition := _find(args, 1)
	if definition == null:
		return ctx.fail("no effect '%s' (fx list)" % (args[1] if args.size() > 1 else ""))
	var params := {}
	var anchor := FxAnchor.screen()
	for index in range(2, args.size()):
		var parts := args[index].split("=", true, 1)
		if parts.size() != 2:
			return ctx.fail("'%s' is not key=value" % args[index])
		if parts[0] == "at":
			if parts[1] == "origin":
				anchor = FxAnchor.position3d(Vector3.ZERO)
			elif parts[1].begins_with("unit:"):
				anchor = FxAnchor.unit(StringName(parts[1].trim_prefix("unit:")))
			elif parts[1] != "screen":
				return ctx.fail("at= is screen, origin or unit:<id>")
		else:
			params[parts[0]] = parts[1]
	var headless := DisplayServer.get_name() == "headless"
	var was_enabled := FxManager.enabled
	var was_manual := FxManager.manual_clock
	if headless:
		FxManager.enabled = true
		FxManager.manual_clock = true
	var handle := FxManager.play(definition, anchor, params)
	if handle.inert:
		FxManager.enabled = was_enabled
		FxManager.manual_clock = was_manual
		return ctx.fail("%s did not play (effects off, quality off, or the anchor is missing)" % definition.id)
	if not headless:
		return "playing %s%s" % [definition.id, " (looping: fx stop)" if definition.is_looping() else ""]
	var time := 0.0
	var stopped := false
	while handle.is_playing() and time < 60.0:
		FxManager.advance(STEP)
		time += STEP
		if definition.is_looping() and not stopped and time >= 2.0:
			handle.stop(0.2)
			stopped = true
	FxManager.stop_all()
	FxManager.enabled = was_enabled
	FxManager.manual_clock = was_manual
	return "played %s: %d layers, over after %.2f s%s" % [definition.id, definition.layers.size(), time, " (looped, stopped at 2 s)" if stopped else ""]
