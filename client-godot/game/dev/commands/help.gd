## Lists the commands, or one command's usage.
extends DevCommand


func _init() -> void:
	name = "help"
	usage = "help [command]"
	help = "Lists the commands, or one command's usage."
	cheat = false
	arg_kinds.assign(["command"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if args.size() > 0:
		var command: DevCommand = ctx.console.commands.get(args[0])
		if command == null:
			return ctx.fail("unknown command '%s'" % args[0])
		return "%s%s\n  %s" % [command.usage, "  (cheat)" if command.cheat else "", command.help]
	var lines := PackedStringArray()
	for command_name in ctx.console.sorted_names():
		var command: DevCommand = ctx.console.commands[command_name]
		lines.append("%-34s %s%s" % [command.usage, command.help, "  (cheat)" if command.cheat else ""])
	for warning in ctx.console.warnings:
		lines.append("warning: " + warning)
	return "\n".join(lines)
