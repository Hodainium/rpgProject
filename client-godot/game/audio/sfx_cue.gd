## Spec audio-pass 2.4 / 3.2: a GameplayCue that plays one sound from the bank (a `Cue.Sfx.*` scene in presentation/demo/cues/sfx/).
## Separate from the effects' cues on purpose (decision D1): FxManager stops every effect at fx quality `off`, and turning visual
## effects off must not mute the game. The sound plays on a voice under /root/SfxVoices, not under the cue: a cue is pooled at once
## and a unit's view may be freed while its death sound still rings (the last blow of a battle), so the sound outlives both and
## ends on its own `finished`. Voices are pooled per cue tag (at most `max_voices` players each, reused when idle), so a battle
## makes no player per hit. Throttled so a hit on four units is not four full-level copies: the same cue plays at most once per
## `min_interval` on one unit, and at most `max_voices` copies sound at once. Presentation only: never touches combat state, never
## draws from a battle RNG (the bank's AudioStreamRandomizer varies pitch on its own), never in a hash or a log.
class_name SfxCue
extends GameplayCueNotify

const VOICES := "SfxVoices"

## A bank entry (presentation/audio/sfx/bank/<id>.tres), never a .wav directly (validator `sfx_direct_stream`).
@export var sound: AudioStream
@export var bus: StringName = &"Sfx"
@export var volume_db: float = 0.0
## Seconds: a second play of this cue on the same unit inside this window is skipped.
@export var min_interval: float = 0.04
## Copies of this cue that may sound at once, across units.
@export var max_voices: int = 3

## Counters for the console's `audio stats` and the tests: plays started, plays skipped by the throttle, plays per cue tag.
static var plays: int = 0
static var throttled: int = 0
static var plays_by_tag: Dictionary = {}
## Tests set a clock (a Callable returning seconds) so the throttle is deterministic; the engine clock otherwise.
static var clock_override: Callable
## cue tag -> unit instance id -> the last time it played there (pruned as it is read).
static var _last: Dictionary = {}
## cue tag -> its pooled voices (AudioStreamPlayers under /root/SfxVoices; busy while they sound).
static var _pool: Dictionary = {}
const BUSY := "sfx_busy"
const STARTED := "sfx_started"
## Seconds after which a voice still marked busy counts as free (one that stopped without `finished` must not block its cue).
const STALE_AFTER := 10.0


static func reset_stats() -> void:
	plays = 0
	throttled = 0
	plays_by_tag.clear()
	_last.clear()
	for tag in _pool:
		for player in _voices_for(tag):
			player.set_meta(BUSY, false)


static func _busy(player: AudioStreamPlayer) -> bool:
	return player.get_meta(BUSY, false) and _now() - float(player.get_meta(STARTED, 0.0)) < STALE_AFTER


## Copies of a cue sounding now.
static func voices_of(tag: StringName) -> int:
	var count := 0
	for player in _voices_for(tag):
		if _busy(player):
			count += 1
	return count


## A tag's pooled voices that still exist (a freed one leaves the pool).
static func _voices_for(tag: StringName) -> Array:
	var live: Array = (_pool.get(tag, []) as Array).filter(func(p): return is_instance_valid(p) and not p.is_queued_for_deletion())
	_pool[tag] = live
	return live


static func _now() -> float:
	return float(clock_override.call()) if clock_override.is_valid() else Time.get_ticks_msec() / 1000.0


func execute_cue(target: Node, _payload: Dictionary = {}) -> void:
	if not _replayed(target) and _allowed(target):
		play_cue()
	# The base execute_cue would call play_cue() again (bypassing the throttle). The sound lives on its own voice, so the cue
	# goes back to the pool at once.
	if auto_destroy and is_inside_tree():
		finish_cue.call_deferred()


## True for a unit of a battle that a silent run replays (ServerLink's resume tail): that battle already happened.
static func _replayed(target: Node) -> bool:
	var at := target
	while at != null:
		if at is RunController and (at as RunController).silent:
			return true
		at = at.get_parent()
	return false


## Whether the throttle lets this play happen now (and records it when it does).
func _allowed(target: Node) -> bool:
	var tag := gameplay_cue_tag
	var now := _now()
	var per_unit: Dictionary = _last.get(tag, {})
	for key in per_unit.keys():
		if now - float(per_unit[key]) >= min_interval:
			per_unit.erase(key)  # pruned: only the units heard inside the window are kept
	var unit := target.get_instance_id() if target != null else 0
	if per_unit.has(unit) or voices_of(tag) >= max_voices:
		throttled += 1
		_last[tag] = per_unit
		return false
	per_unit[unit] = now
	_last[tag] = per_unit
	return true


func play_cue() -> void:
	if sound == null or not is_inside_tree():
		return
	var tag := gameplay_cue_tag
	var player: AudioStreamPlayer = null
	for idle in _voices_for(tag):
		if not _busy(idle):
			player = idle
			break
	if player == null:  # the throttle keeps busy voices under max_voices, so the pool never grows past it
		player = AudioStreamPlayer.new()
		player.name = "Voice"
		_voice_host(get_tree()).add_child(player, true)
		player.finished.connect(func(): player.set_meta(BUSY, false))
		(_pool.get_or_add(tag, []) as Array).append(player)
	player.stream = sound
	player.bus = bus
	player.volume_db = volume_db
	player.set_meta(BUSY, true)
	player.set_meta(STARTED, _now())
	plays += 1
	plays_by_tag[tag] = int(plays_by_tag.get(tag, 0)) + 1
	player.play()


## The node every sound cue's voices play under (made on first use, under the scene root, so it outlives battles and views).
static func _voice_host(tree: SceneTree) -> Node:
	var host := tree.root.get_node_or_null(VOICES)
	if host == null:
		host = Node.new()
		host.name = VOICES
		tree.root.add_child(host)
	return host


## Voices sounding now (for the tests and `audio stats`).
static func live_voices(tree: SceneTree) -> Array[AudioStreamPlayer]:
	var out: Array[AudioStreamPlayer] = []
	var host := tree.root.get_node_or_null(VOICES)
	if host != null:
		for child in host.get_children():
			if child is AudioStreamPlayer and not child.is_queued_for_deletion() and _busy(child):
				out.append(child)
	return out


## Every pooled voice, idle or not (for the tests).
static func pooled_voices(tree: SceneTree) -> int:
	var host := tree.root.get_node_or_null(VOICES)
	return host.get_child_count() if host != null else 0
