## Cheat (spec keys-and-gear 3.2): the golden key (every lock on this floor opens for free).
extends DevCommand


func _init() -> void:
	name = "goldkey"
	usage = "goldkey"
	help = "Gives the golden key: locked rooms and chests open for free until the stairs."
	cheat = true


func run(ctx: DevContext, _args: PackedStringArray) -> String:
	if ctx.need_run() != "":
		return ctx.fail(ctx.need_run())
	var error := ctx.run.dev_golden_key()
	return ctx.fail(error) if error != "" else "golden key: on"
