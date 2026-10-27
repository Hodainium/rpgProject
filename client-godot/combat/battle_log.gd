## Spec skill-points (the stall hunt): an optional, human-readable log of what a battle does, one line per event: actions
## and their targets, triggered passives and the event that fired them, refused actions, skipped turns, Auto's picks
## with a reason, and the outcome. Off by default; on with the environment variable RPG_BATTLE_LOG=1 (any tool: play
## reports, replays, traces, tests), `seed_report --battle-log` or the console's `battlelog on`. Read-only: it never
## changes combat state, draws from the RNG or enters a hash, so turning it on can't change a battle.
class_name BattleLog
extends RefCounted

static var enabled: bool = OS.has_environment("RPG_BATTLE_LOG")
## When not null, lines are also kept here (tests read them); printing still follows `enabled`.
static var sink: Variant = null


## One line, prefixed with the battle id and turn: "[battle run-4/f7/c82 t12] P1 Ability.Strike -> E1".
static func line(battle: Battle, text: String) -> void:
	if not enabled:
		return
	var entry := "[battle %s t%d] %s" % [battle.battle_id if battle != null else "?", battle.turn if battle != null else 0, text]
	print(entry)
	if sink is Array:
		sink.append(entry)
