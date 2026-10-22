## A unit's look (spec animation-sets): its view scene, animation set, which slots are its own and which come from a
## fallback, and the validator's view findings. With a slot, plays it on every view of that unit on screen.
extends DevCommand


func _init() -> void:
	name = "anim"
	usage = "anim <unit> [slot]"
	help = "Shows a unit's view and animation set (own and fallback slots, problems); with a slot (idle, hit, death…) plays it on that unit's views."
	cheat = false
	arg_kinds.assign(["unit", "text"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	var unit: UnitDefinition = ctx.find("unit", args[0] if args.size() > 0 else "")
	if unit == null:
		return ctx.fail(ctx.error)
	var default_scene: PackedScene = ctx.game.unit_view if ctx.game != null else null
	var scene := UnitAnimator.view_scene(unit, default_scene)
	if scene == null:
		return ctx.fail("%s has no view and there is no default view" % unit.id)
	var lines := PackedStringArray()
	lines.append("%s  view: %s%s" % [unit.id, scene.resource_path, "" if unit.view != "" else " (default)"])
	var root := scene.instantiate()
	var animation_set: UnitAnimationSet = root.animation_set if root is UnitAnimator else null
	root.free()
	if animation_set == null:
		lines.append("  no animation set: every slot is silent")
	else:
		lines.append("  set: %s" % animation_set.resource_path)
		var own := animation_set.own_slots()
		for slot in UnitAnimationSet.SLOTS:
			var animation := animation_set.animation_for(slot)
			var source := "own" if slot in own else ("fallback" if animation != null else "empty")
			lines.append("  %-8s %s%s" % [slot, source, "  %.2f s%s" % [animation.length,
				" loop" if animation.loop_mode != Animation.LOOP_NONE else ""] if animation != null else ""])
	if ctx.content != null:
		for issue in ContentValidator.validate(ctx.content, {"tags": false}):
			if issue.code in ["view_missing", "animation_set_loop", "animation_set_profile", "ability_montage_path"] \
					and (issue.path.begins_with(unit.resource_path) or (unit.view != "" and issue.path.begins_with(unit.view))):
				lines.append("  ! " + str(issue))
	if args.size() > 1:
		var slot := StringName(args[1])
		if not slot in UnitAnimationSet.SLOTS:
			return ctx.fail("no slot '%s' (one of %s)" % [slot, ", ".join(UnitAnimationSet.SLOTS)])
		var played := 0
		for view in (Engine.get_main_loop() as SceneTree).get_nodes_in_group(UnitAnimator.GROUP):
			if view.definition_id == unit.id and view.play_slot(slot):
				played += 1
		lines.append("played %s on %d view(s)%s" % [slot, played, "" if played > 0 else " (none on screen: start a sandbox with play)"])
	return "\n".join(lines)
