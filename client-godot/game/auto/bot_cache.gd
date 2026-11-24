## Spec bot-play 2.7 (user, 2026-11-22): the party stats and field options the bot reads, kept until the run changes.
## RunController builds a whole field battle for each read; every change to a run is a logged action, so two reads at the
## same run_log size are the same read. On only between begin() and end() (RunPlayer.play with a bot): code that changes
## the state without logging (tests, tools) reads fresh. Kept on the run itself (Object metadata), so runs never share
## one. Callers must not change what they get back.
class_name BotCache
extends RefCounted

const META: StringName = &"bot_cache"


static func begin(run: RunController) -> void:
	run.set_meta(META, {"at": -1})


static func end(run: RunController) -> void:
	run.remove_meta(META)


## RunController.party_stats().
static func party_stats(run: RunController) -> Dictionary:
	var kept := _kept(run)
	if kept.is_empty():
		return run.party_stats()
	if not kept.has("stats"):
		kept["stats"] = run.party_stats()
	return kept["stats"]


## RunController.field_options().
static func field_options(run: RunController) -> Array[Dictionary]:
	var kept := _kept(run)
	if kept.is_empty():
		return run.field_options()
	if not kept.has("options"):
		kept["options"] = run.field_options()
	return kept["options"]


## This run's reads at its current log size; {} when the cache is off.
static func _kept(run: RunController) -> Dictionary:
	if not run.has_meta(META):
		return {}
	var kept: Dictionary = run.get_meta(META)
	if kept["at"] != run.run_log.size():
		kept.clear()
		kept["at"] = run.run_log.size()
	return kept
