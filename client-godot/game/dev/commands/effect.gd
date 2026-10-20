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
	# Untyped first: any other resource (a room, an item) is refused instead of failing the typed assignment.
	var loaded: Resource = load(args[0]) if args.size() > 0 and ResourceLoader.exists(args[0]) else null
	var slot: Variant = ctx.arg_int(args, 1, 0)
	if not loaded is GameplayEffect or slot == null:
		return ctx.fail("usage: %s (a GameplayEffect .tres)" % usage)
	var effect: GameplayEffect = loaded
	var error := ctx.run.dev_apply("effect", effect, [slot] if slot > 0 else [], false)
	return ctx.fail(error) if error != "" else "applied " + args[0]
