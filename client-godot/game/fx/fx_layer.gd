## One layer of an FxDefinition (spec vfx-framework 3.1): the Niagara emitter / renderer in one resource. This is the
## base class; each kind is a small script that extends it and overrides build / apply / start / stop / reset (new
## kinds never touch the manager). A layer resource is stateless and shared: everything that belongs to one playing
## instance lives on the Node `build()` made (node metadata), so a pooled instance can be reused.
##
## Lifecycle, driven by FxService on its clock: build() once → apply(params) at each play → start() when the layer's
## delay is over → update(local_time) every tick → stop(fade) when the effect is stopped or the layer's length is up →
## reset() back in the pool. Presentation only.
class_name FxLayer
extends Resource

## Where the layer's node lives. INHERIT: the kind decides, else the definition's space.
enum Space { INHERIT, UI, WORLD_3D }
## The lowest quality tier the layer plays at (the setting's tiers are off / low / medium / high).
enum Quality { LOW = 1, MEDIUM = 2, HIGH = 3 }

const META_ANCHOR: StringName = &"fx_anchor"
const META_PARAMS: StringName = &"fx_params"
const META_ORIGINALS: StringName = &"fx_originals"
const META_QUALITY: StringName = &"fx_quality"

@export var id: StringName
@export var space: Space = Space.INHERIT
@export var start_delay: float = 0.0
## -1: the layer's natural length (particle lifetime, sound length…).
@export var duration: float = -1.0
@export var loop: bool = false
## A looping layer repeats its tracks' 0..1 time every this many seconds.
@export var loop_period: float = 1.0
@export var min_quality: Quality = Quality.LOW
@export var bindings: Array[FxBinding] = []
@export var tracks: Array[FxCurveTrack] = []


# --- What a kind overrides --------------------------------------------------------------------------------------

## The kind's name for stats, the validator and the console.
func kind() -> StringName:
	return &"layer"


## UI or WORLD_3D when the kind's node only works in one of them; INHERIT when it works anywhere.
func native_space() -> int:
	return Space.INHERIT


## The layer's node, made once per pooled instance (unparented, hidden). A kind that needs unique sub-resources (a
## material, a particle process material) duplicates them here, never shares the layer's.
func build() -> Node:
	return Node.new()


## Called at each play: copy the parameters through the bindings. A kind extends this (and calls super) to set its own
## per-play things; `quality` is the setting's tier (1 low … 3 high) for scalability.
func apply(node: Node, params: Dictionary, anchor: FxAnchor, quality: int, definition: FxDefinition) -> void:
	node.set_meta(META_ANCHOR, anchor)
	node.set_meta(META_PARAMS, params)
	node.set_meta(META_QUALITY, quality)
	rebind(node, params, definition)


## Re-runs the bindings (a parameter changed on a live effect).
func rebind(node: Node, params: Dictionary, definition: FxDefinition) -> void:
	for binding in bindings:
		binding.apply_to(node, params, definition)


## The layer's delay is over: show the node and begin.
func start(node: Node) -> void:
	node.set_meta(META_ORIGINALS, _capture_tracks(node))
	set_node_visible(node, true)


## Every tick while running. `local_time` is seconds since the layer started, `length` the layer's length (INF when it
## loops). The default runs the curve tracks.
func update(node: Node, local_time: float, length: float, params: Dictionary) -> void:
	_run_tracks(node, local_time, length, params)


## Stop (fade seconds) without waiting for the natural end: a particle layer stops emitting, a sound fades.
func stop(_node: Node, _fade: float) -> void:
	pass


## The layer's time is up (or it was stopped): put back what it changed on the anchor, now rather than when the whole
## effect ends. Kinds that change the anchor extend this.
func ended(node: Node) -> void:
	_restore_tracks(node)


## Back to rest in the pool: restore what the layer changed on the anchor, hide the node.
func reset(node: Node) -> void:
	ended(node)
	set_node_visible(node, false)


## A layer of unknown length (a sub-effect) says here that it is over.
func is_finished(_node: Node) -> bool:
	return false


## Seconds a stopped layer still needs before it is gone (particles already in the air).
func tail(_node: Node) -> float:
	return 0.0


## The layer's natural length with these parameters (read from the built node, so a bound lifetime counts).
func natural_length(_node: Node, _params: Dictionary) -> float:
	return 0.0


## Where the curve tracks write: the layer's own node, or (FxTweenLayer) the anchor's.
func track_target(node: Node) -> Object:
	return node


## Problems an author should fix, for the validator (spec 6, item 8). `definition` is the owning effect.
func extra_problems(_definition: FxDefinition, _probe: Node) -> PackedStringArray:
	return PackedStringArray()


# --- Shared behaviour ---------------------------------------------------------------------------------------------

## The layer's length: forever when it loops, else `duration`, else the natural length.
func length(node: Node, params: Dictionary) -> float:
	if loop:
		return INF
	return duration if duration >= 0.0 else natural_length(node, params)


## The space the layer's node goes in for a definition in `definition_space` (an FxDefinition.Space).
func resolved_space(definition_space: int) -> int:
	if space != Space.INHERIT:
		return space
	var native := native_space()
	if native != Space.INHERIT:
		return native
	return Space.WORLD_3D if definition_space == FxDefinition.Space.WORLD_3D else Space.UI


## 0..1 progress of the layer's tracks.
func progress(local_time: float, length_seconds: float) -> float:
	if is_inf(length_seconds) or length_seconds <= 0.0:
		return fposmod(local_time / maxf(loop_period, 0.001), 1.0) if is_inf(length_seconds) else 1.0
	return clampf(local_time / length_seconds, 0.0, 1.0)


## A node's metadata value, or null when it has none (get_meta with a null default logs an error).
static func meta_of(node: Object, key: StringName) -> Variant:
	return node.get_meta(key) if node.has_meta(key) else null


static func set_node_visible(node: Node, shown: bool) -> void:
	if "visible" in node:
		node.visible = shown


## Problems found by building a probe node (bindings that do not resolve, parameters not declared, tracks on nothing).
func problems(definition: FxDefinition) -> PackedStringArray:
	var out := PackedStringArray()
	if id == &"":
		out.append("fx_layer_id: a layer has no id")
	if loop and duration >= 0.0:
		out.append("fx_layer_loop: layer '%s' loops, so its duration is ignored" % id)
	for binding in bindings:
		if definition.param(binding.param) == null:
			out.append("fx_param_missing: layer '%s': binding on '%s' uses the undeclared parameter '%s'" % [id, binding.property, binding.param])
	for track in tracks:
		if track.property == "":
			out.append("fx_track_invalid: layer '%s': a curve track has no property" % id)
		elif track.scale_param != &"" and definition.param(track.scale_param) == null:
			out.append("fx_param_missing: layer '%s': track '%s' uses the undeclared parameter '%s'" % [id, track.property, track.scale_param])
	var probe := build()
	if probe == null:
		out.append("fx_layer_build: layer '%s' builds no node" % id)
		return out
	for binding in bindings:
		if not binding.resolves_on(probe):
			out.append("fx_binding_invalid: layer '%s': binding property '%s' does not exist on the %s node" % [id, binding.property, probe.get_class()])
	if track_target(probe) == probe:
		for track in tracks:
			if track.property != "" and not FxBinding.property_resolves(probe, track.property):
				out.append("fx_track_invalid: layer '%s': track property '%s' does not exist on the %s node" % [id, track.property, probe.get_class()])
	out.append_array(extra_problems(definition, probe))
	probe.free()
	return out


func _capture_tracks(node: Node) -> Dictionary:
	var originals := {}
	var target := track_target(node)
	if target == null:
		return originals
	for index in tracks.size():
		if tracks[index].property != "":
			originals[index] = acquire_original(target, "track:" + tracks[index].property, target.get_indexed(NodePath(tracks[index].property)))
	return originals


## Metadata names must be identifiers: ":" and "/" in property paths become underscores.
static func _origin_key(key: String) -> StringName:
	return StringName("fx_origin_" + key.replace(":", "_").replace("/", "_").replace(" ", "_"))


## The value a property had before any effect moved it. Effects that overlap on one target (two tweens, two shakes) share
## it: the first to start records it, the last to end puts it back, so none restores another's displaced value.
static func acquire_original(target: Object, key: String, current: Variant) -> Variant:
	var meta_key := _origin_key(key)
	var entry: Dictionary = target.get_meta(meta_key) if target.has_meta(meta_key) else {"count": 0, "value": current}
	entry["count"] += 1
	target.set_meta(meta_key, entry)
	return entry["value"]


## Gives the original back: returns {"last": true, "value": v} when this was the last effect using it (restore it now).
static func release_original(target: Object, key: String) -> Dictionary:
	var meta_key := _origin_key(key)
	if not target.has_meta(meta_key):
		return {"last": false}
	var entry: Dictionary = target.get_meta(meta_key)
	entry["count"] -= 1
	if entry["count"] > 0:
		return {"last": false}
	target.remove_meta(meta_key)
	return {"last": true, "value": entry["value"]}


func _run_tracks(node: Node, local_time: float, length_seconds: float, params: Dictionary) -> void:
	var originals: Dictionary = node.get_meta(META_ORIGINALS, {})
	var target := track_target(node)
	if target == null or originals.is_empty():
		return
	var u := progress(local_time, length_seconds)
	for index in originals:
		target.set_indexed(NodePath(tracks[index].property), tracks[index].evaluate(originals[index], u, params))


func _restore_tracks(node: Node) -> void:
	var originals: Dictionary = node.get_meta(META_ORIGINALS, {})
	var target := track_target(node)
	if target != null and is_instance_valid(target):
		for index in originals:
			var released := release_original(target, "track:" + tracks[index].property)
			if released["last"]:
				target.set_indexed(NodePath(tracks[index].property), released["value"])
	node.set_meta(META_ORIGINALS, {})
