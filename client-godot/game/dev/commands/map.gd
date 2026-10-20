## Prints the current floor: every room with its role, content, pickups and whether it can be entered.
extends DevCommand


func _init() -> void:
	name = "map"
	usage = "map"
	help = "Prints the floor (ENTER marks the rooms you can enter)."
	cheat = false
	arg_kinds.assign([])


func run(ctx: DevContext, _args: PackedStringArray) -> String:
	return DevReport.map_text(ctx.run)
