## One console command (spec dev-tools 3.2). One file per command in res://game/dev/commands/ (or, in debug builds,
## a throwaway one in user://dev_commands/); the console finds them on its own. Copy commands/_template.gd to start.
##
## Rules: change units through GAS (effects, items) and the run through RunController (cheats use its dev_* methods,
## or call run.dev_log() first); never draw from another RNG stream. Return the reply; use ctx.fail() for errors.
class_name DevCommand
extends RefCounted

## What you type, lower case.
var name: String = ""
## E.g. "give <item> [slot]".
var usage: String = ""
## One line.
var help: String = ""
## Changes run state: logged as dev and refused while cheats are off.
var cheat: bool = false
## Per argument position, for Tab: "item", "equipment", "encounter", "event", "room", "layout", "character", "unit",
## "chapter", "command", "slot", "attribute", "play_kind", "type", "grid_op", "place", "side", "target", "ability",
## "on_off", "int", "seed", "text".
var arg_kinds: Array[String] = []


## The reply (may await). Errors: return ctx.fail("why").
func run(_ctx: DevContext, _args: PackedStringArray) -> String:
	return ""
