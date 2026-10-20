## Clears the console scrollback (the Dev overlay listens for the reply).
extends DevCommand


func _init() -> void:
	name = "clear"
	usage = "clear"
	help = "Clears the scrollback."
	cheat = false
	arg_kinds.assign([])


func run(_ctx: DevContext, _args: PackedStringArray) -> String:
	return "<clear>"  # the Dev overlay empties its scrollback on this reply
