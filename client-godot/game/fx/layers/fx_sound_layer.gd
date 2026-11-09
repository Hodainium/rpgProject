## A sound (spec vfx-framework 3.1): an AudioStreamPlayer (an AudioStreamPlayer3D when `space` is WORLD_3D), with
## random pitch and volume so repeats do not sound alike. The randomness is a player-local generator (never the
## battle's). The layer lasts as long as the stream. Bind "volume_db" or "pitch_scale".
class_name FxSoundLayer
extends FxLayer

@export var stream: AudioStream
@export var volume_db: float = 0.0
@export var pitch_min: float = 1.0
@export var pitch_max: float = 1.0
@export var volume_jitter_db: float = 0.0
@export var bus: StringName = &"Master"

const TWEEN: StringName = &"fx_fade_tween"

var _rng: RandomNumberGenerator


func kind() -> StringName:
	return &"sound"


func native_space() -> int:
	return Space.WORLD_3D if space == Space.WORLD_3D else Space.INHERIT


func build() -> Node:
	var player: Node = AudioStreamPlayer3D.new() if space == Space.WORLD_3D else AudioStreamPlayer.new()
	player.stream = stream
	player.bus = bus
	player.volume_db = volume_db
	return player


func apply(node: Node, params: Dictionary, anchor: FxAnchor, quality: int, definition: FxDefinition) -> void:
	if _rng == null:
		_rng = RandomNumberGenerator.new()
		_rng.randomize()
	node.volume_db = volume_db + (_rng.randf_range(-volume_jitter_db, volume_jitter_db) if volume_jitter_db > 0.0 else 0.0)
	node.pitch_scale = _rng.randf_range(minf(pitch_min, pitch_max), maxf(pitch_min, pitch_max)) \
		if pitch_max != pitch_min else pitch_min
	super(node, params, anchor, quality, definition)


func start(node: Node) -> void:
	super(node)
	if node.stream != null:
		node.play()


func stop(node: Node, fade: float) -> void:
	if not is_instance_valid(node) or not node.is_inside_tree():
		return
	if fade > 0.0 and node.playing:
		var tween := node.create_tween()
		tween.tween_property(node, "volume_db", -60.0, fade)
		tween.tween_callback(node.stop)
		node.set_meta(TWEEN, tween)
	else:
		node.stop()


func reset(node: Node) -> void:
	var tween: Tween = FxLayer.meta_of(node, TWEEN)
	if tween != null and tween.is_valid():
		tween.kill()  # a fade still running must not silence the next play of this pooled node
	node.set_meta(TWEEN, null)
	node.stop()
	node.volume_db = volume_db
	super(node)


func natural_length(node: Node, _params: Dictionary) -> float:
	return node.stream.get_length() if node.stream != null else 0.0
