## Spec battle-death-fade 3.1: how an enemy leaves the battle when it dies, as in FF7: an optional white flash, a turn to red
## (with a glow), then a fade to nothing. The battle's end waits for it plus end_beat. Presentation only: never in a hash.
class_name DeathFade
extends Resource

@export var color: Color = Color(0.85, 0.08, 0.08)
## A white flash before the tint; 0 = none.
@export_range(0.0, 2.0) var flash_seconds: float = 0.0
@export_range(0.0, 5.0) var tint_seconds: float = 0.35
@export_range(0.0, 5.0) var fade_seconds: float = 0.6
## The red glow while it fades (emission energy); 0 = none.
@export_range(0.0, 16.0) var emission: float = 1.5
## The extra pause the battle's end waits after this fade.
@export_range(0.0, 3.0) var end_beat: float = 0.3


## The defaults for an ordinary enemy.
static func enemy_default() -> DeathFade:
	return DeathFade.new()


## The defaults for a boss (user, 2026-11-13: "a longer more dramatic one").
static func boss_default() -> DeathFade:
	var fade := DeathFade.new()
	fade.flash_seconds = 0.12
	fade.tint_seconds = 0.8
	fade.fade_seconds = 1.4
	fade.emission = 3.0
	fade.end_beat = 0.2  # user, 2026-11-13: 0.6 waited too long once the boss was gone
	return fade


## How long the fade shows (flash + tint + fade), without the end beat.
func visible_seconds() -> float:
	return flash_seconds + tint_seconds + fade_seconds


## How long it holds the battle's end.
func hold_seconds() -> float:
	return visible_seconds() + end_beat
