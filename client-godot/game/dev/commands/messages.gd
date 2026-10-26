## Spec gameplay-messages 2.4: logs the GameplayMessages bus. `messages on [channel]` prints every message on that
## channel and its children (default Message: all of them) as "[msg] Message.Battle.Broken Verb.Break P1→E2 0 [...]",
## in the console and the script runner's output (its JSON gets "messages"); `messages off`; `messages last [n]`.
extends DevCommand


func _init() -> void:
	name = "messages"
	usage = "messages [on [channel] | off | last [n]]"
	help = "Log gameplay messages (spec gameplay-messages): on [channel] (default Message), off, last [n]."
	cheat = false
	arg_kinds.assign(["messages_op", "channel"])


func run(ctx: DevContext, args: PackedStringArray) -> String:
	var console := ctx.console
	var op := args[0] if args.size() > 0 else ""
	match op:
		"":
			return "messages: %s, %d logged" % ["on " + String(console.message_channel) if console.message_channel != &""
				else "off", console.message_log.size()]
		"on":
			var channel := args[1] if args.size() > 1 else "Message"
			if not channel.begins_with("Message"):
				return ctx.fail("a channel is a Message.* tag, got '%s'" % channel)
			console.log_messages(StringName(channel))
			return "messages on: logging %s and its children" % channel
		"off":
			console.log_messages(&"")
			return "messages off (%d logged)" % console.message_log.size()
		"last":
			var count: Variant = ctx.arg_int(args, 1, 10)
			if count == null or count < 1:
				return ctx.fail("last takes a positive whole number")
			var lines := console.message_log.slice(maxi(console.message_log.size() - count, 0))
			return "\n".join(PackedStringArray(lines)) if not lines.is_empty() else "no messages logged (messages on first)"
	return ctx.fail("usage: " + usage)
