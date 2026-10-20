## Cheat: applies any GameplayEffect file to living party members, outside battle.
extends DevCommand


func _init() -> void:
	name = "effect"
	usage = "effect <effect path> [slot]"
	help = "Applies a GameplayEffect .tres to the party (or one member) outside battle."
	cheat = true
	arg_kinds.assign(["text", "slot"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var slot: Variant = ctx.arg_int(args, 1, 0)
	if args.is_empty() or slot == null:
		return ctx.fail("usage: %s (a GameplayEffect .tres)" % usage)
	if not ResourceLoader.exists(args[0]):
		return ctx.fail("could not open effect %s: no such file" % args[0])
	# Untyped first: any other resource (a room, an item) is refused instead of failing the typed assignment.
	var loaded: Resource = load(args[0])
	if loaded == null:
		return ctx.fail("could not open effect %s: the file did not load" % args[0])
	if not loaded is GameplayEffect:
		var kind: String = loaded.get_script().get_global_name() if loaded.get_script() != null else loaded.get_class()
		return ctx.fail("could not use %s as an effect: it is a %s, not a GameplayEffect" % [args[0], kind])
	var effect: GameplayEffect = loaded
	var error := ctx.run.dev_apply("effect", effect, [slot] if slot > 0 else [], false)
	return ctx.fail(error) if error != "" else "applied " + args[0]
