## Spec cube-style 3.8: the units' looks, the chapters' moods and the camera framings from the console. Presentation only: nothing
## here touches the run or a battle. `registry` and `mood` change only this session (nothing is saved); a window run with
## `shot` makes a round's comparison shots.
extends DevCommand


func _init() -> void:
	name = "style"
	usage = "style list | show <unit> | mood [<chapter>|off] | registry [<res://path>|default|off] | camera [explore|battle] | reload | check"
	help = "Cube style (spec cube-style): list the looks, show one unit's, show a chapter's mood everywhere, use a variant registry, move the camera, reload, check."
	cheat = false
	arg_kinds.assign(["style_op", "text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	var op := args[0] if args.size() > 0 else "list"
	var registry := UnitStyle.registry()
	match op:
		"list":
			if registry == null:
				return "no style registry in use (today's look; %s)" % UnitStyle.DEFAULT_REGISTRY
			var lines := PackedStringArray(["registry %s" % UnitStyle.source])
			var ids: Array = ctx.content.units.keys() if ctx.content != null else []
			ids.sort()
			for id in ids:
				lines.append("  %-34s %s" % [id, registry.look_source(ctx.content.units[id])])
			for chapter in registry.mood_chapters():
				var mood := registry.mood_for(chapter)
				lines.append("  mood %-29s %s" % [chapter, mood.display_name if mood != null and mood.display_name != "" else "-"])
			return "\n".join(lines)
		"show":
			var found: Resource = ctx.find("unit", args[1] if args.size() > 1 else "")
			if not found is UnitDefinition:
				return ctx.fail(ctx.error if found == null else "%s is not a unit" % args[1])
			var unit := found as UnitDefinition
			if registry == null:
				return "%s: no style registry in use" % unit.id
			return "%s (%s): %s" % [unit.id, registry.look_source(unit), registry.look_for(unit).describe()]
		"mood":
			if args.size() < 2:
				var chapter: StringName = ctx.run.state.chapter_id if ctx.run != null and ctx.run.state != null else &""
				return "mood: %s (room chapter %s)" % [UnitStyle.mood_override if UnitStyle.mood_override != &"" else "each room its own",
					chapter if chapter != &"" else "-"]
			if args[1] == "off":
				UnitStyle.mood_override = &""
			else:
				var found: Resource = ctx.find("chapter", args[1])
				if not found is ChapterDefinition:
					return ctx.fail(ctx.error if found == null else "%s is not a chapter" % args[1])
				UnitStyle.mood_override = (found as ChapterDefinition).id
			_restyle(ctx)
			return "mood: %s" % (UnitStyle.mood_override if UnitStyle.mood_override != &"" else "each room its own")
		"registry":
			if args.size() < 2:
				return "registry: %s" % (UnitStyle.source if UnitStyle.source != "" else "none (today's look)")
			match args[1]:
				"off":
					UnitStyle.use(null)
				"default":
					var problem := UnitStyle.use_path(UnitStyle.DEFAULT_REGISTRY)
					if problem != "":
						return ctx.fail(problem)
				_:
					var problem := UnitStyle.use_path(args[1])
					if problem != "":
						return ctx.fail(problem)
			_restyle(ctx)
			return "registry: %s" % (UnitStyle.source if UnitStyle.source != "" else "none (today's look)")
		"camera":
			var which := args[1] if args.size() > 1 else "explore"
			if not ["explore", "battle"].has(which):
				return ctx.fail("usage: style camera [explore|battle]")
			var camera := ctx.game.get_viewport().get_camera_3d() if ctx.game != null and ctx.game.is_inside_tree() else null
			if camera == null:
				return ctx.fail("no 3D camera (headless or no room view)")
			(UnitStyle.battle_framing() if which == "battle" else UnitStyle.explore_framing()).apply_to(camera)
			return "camera: %s framing" % which
		"reload":
			if UnitStyle.source == "":
				return ctx.fail("no registry in use (today's look); style registry default|<res://path> picks one")
			var path := UnitStyle.source
			var problem := UnitStyle.use_path(path)
			if problem != "":
				return ctx.fail(problem)
			_restyle(ctx)
			return "reloaded %s" % path
		"check":
			if registry == null:
				return "no style registry in use"
			var issues := StyleValidator.validate(registry, ctx.content, UnitStyle.source)
			return ContentValidator.report(issues) if not issues.is_empty() else "style: no problems"
	return ctx.fail("usage: " + usage)


func _restyle(ctx: DevContext) -> void:
	if ctx.game != null and ctx.game.is_inside_tree():
		ctx.game.get_tree().call_group(&"style_listeners", &"restyle")
