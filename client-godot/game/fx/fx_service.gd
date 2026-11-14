## The effects manager (spec vfx-framework 2, 3.2). The autoload `FxManager` is this script: it finds an effect by id,
## resolves its parameters, takes a pooled instance, attaches it where the anchor needs it, drives its layers on its own
## clock, and puts the instance back when the effect ends or its anchor is freed.
##
##   var handle := FxManager.play(&"fx.glow_burst", FxAnchor.control(card), {color = Color.GOLD})
##   handle.set_param(&"intensity", 2.0)     # live retune
##   handle.stop(0.3)                        # fade a looping aura out
##
## Presentation only: effects never touch combat or run state, are never hashed or uploaded, and nothing in combat/
## references this. Headless (the verifier, tests, tools) `enabled` is false and play() returns an inert handle; tests
## switch it on and drive the clock by hand (`manual_clock`, `advance`).
class_name FxService
extends Node

signal played(handle: FxHandle)
signal finished(handle: FxHandle)
## The tier changed (a persistent cue that played while effects were off starts its effect again).
signal quality_changed(tier: int)

enum Follow { NONE, COPY_CONTROL, PROJECT, PROJECT_STAGE, SCREEN }

const DEFAULT_REGISTRY: String = "res://presentation/demo/fx/fx_registry.tres"
const SETTINGS_SECTION: String = "settings"
const SETTINGS_KEY: String = "fx_quality"
## Sub-effects nested deeper than this are refused (a cycle guard).
const MAX_DEPTH: int = 4
const META_SERVICE: StringName = &"fx_service"
const META_DEPTH: StringName = &"fx_depth"

## False headless: play() then returns an inert handle.
var enabled: bool = DisplayServer.get_name() != "headless"
## Tests and tools drive the clock themselves with advance().
var manual_clock: bool = false
## off / low / medium / high (FxQuality). Changing it takes effect at once: off stops every live effect, any other tier
## re-applies to the looping ones (layers above the tier stop, layers that now qualify start, particle counts rescale).
## One-shots already playing finish as they started.
var quality: int = FxQuality.HIGH:
	set(value):
		value = clampi(value, FxQuality.OFF, FxQuality.HIGH)
		if value == quality:
			return
		quality = value
		if quality == FxQuality.OFF:
			stop_all()
		else:
			_requalify_live()
		quality_changed.emit(quality)
var registry: FxRegistry
## A battle unit's view by unit id (default: the UnitAnimator group). Tests and other views can set their own.
var unit_resolver: Callable = Callable()
## When true each play and finish is broadcast on Message.Dev.Fx (the console's `fx log on`).
var dev_messages: bool = false
## The 3D world effects without a node anchor play in, and the window-wide 2D layer.
var world_root: Node3D
var screen_layer: CanvasLayer
var screen_root: Control

var _loaded: bool = false
var _definitions: Dictionary = {}
var _runtime: Dictionary = {}
var _pools: Dictionary = {}
var _live: Array[FxHandle] = []
var _warned: Dictionary = {}
var _stats: Dictionary = {"plays": 0, "skipped": 0, "unknown": 0, "recycled": 0, "built": 0, "pool_hits": 0, "finished": 0}
var _plays_by_id: Dictionary = {}
## True while the service leaves the tree: handles still end, but announce nothing.
var _closing: bool = false


func _ready() -> void:
	# A process that draws and plays nothing (the headless verifier, tests, tools) suppresses every GodotGAS cue: no cue
	# scene is loaded and no cue node is made per hit (spec vfx-framework; the patched GameplayCueManager's hook, Unreal's
	# ShouldSuppressGameplayCues). Tests that want real cues switch it off for their duration.
	GameplayCueManager.suppress_cues = DisplayServer.get_name() == "headless"
	# The registry and the host nodes load on first use, so a headless process (the verifier, tests) that never plays an
	# effect pays nothing.
	# Only the autoload reads the player's setting; a service a test adds somewhere else keeps its own.
	if get_parent() == get_tree().root:
		quality = FxQuality.from_text(str(GameMain.load_setting(SETTINGS_SECTION, SETTINGS_KEY, "high")))


func _exit_tree() -> void:
	# Pooled instances are not in the tree; free them so nothing leaks at shutdown. No `finished` signals while the tree goes
	# (review fix): a listener (a cue notify handing itself back to GodotGAS's pool) would re-parent nodes mid-teardown.
	_closing = true
	for handle in _live.duplicate():
		_finish(handle)
	for pool in _pools.values():
		for instance in pool:
			instance.free_nodes()
	_pools.clear()
	if get_tree().root.get_node_or_null(^"FxManager") == self:
		FxStencilShaders.clear()  # spec vfx-stencil: the autoload's shutdown drops the cached copies (not a test's own service)


func _process(delta: float) -> void:
	if not manual_clock and not _live.is_empty():
		advance(delta)


# --- Catalog ---------------------------------------------------------------------------------------------------

## Rebuilds the id → definition table from the registry and the runtime registrations.
func reload() -> void:
	_loaded = true
	if registry == null and ResourceLoader.exists(DEFAULT_REGISTRY):
		registry = load(DEFAULT_REGISTRY) as FxRegistry
	_definitions = registry.all() if registry != null else {}
	_definitions.merge(_runtime, true)
	_flush_pools()


func _ensure_loaded() -> void:
	if not _loaded:
		reload()


## Pooled instances are built for one definition; drop them when definitions change.
func _flush_pools() -> void:
	for pool in _pools.values():
		for instance in pool:
			instance.free_nodes()
	_pools.clear()


## Adds an effect at run time (tests, tools, a mod); it overrides a registry entry with the same id.
func register(definition: FxDefinition) -> void:
	if definition != null and definition.id != &"":
		_ensure_loaded()
		_runtime[definition.id] = definition
		_definitions[definition.id] = definition
		for instance in _pools.get(definition.id, []):
			instance.free_nodes()
		_pools.erase(definition.id)


func definition(id: StringName) -> FxDefinition:
	_ensure_loaded()
	return _definitions.get(id)


## Every effect id, sorted.
func catalog() -> Array[StringName]:
	_ensure_loaded()
	var ids: Array[StringName] = []
	for id in _definitions:
		ids.append(id)
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return ids


# --- Playing ---------------------------------------------------------------------------------------------------

## Plays an effect (a definition or its id) at `anchor` with `params` (unknown or ill-typed ones are ignored with a
## warning, values are clamped). Always returns a handle; an inert one when the effect cannot play.
func play(effect: Variant, anchor: FxAnchor = null, params: Dictionary = {}) -> FxHandle:
	return play_nested(effect, anchor, params, 0)


## play() for a sub-effect: `depth` guards against an effect that contains itself.
func play_nested(effect: Variant, anchor: FxAnchor, params: Dictionary, depth: int) -> FxHandle:
	if not enabled or quality == FxQuality.OFF:
		_stats["skipped"] += 1
		return FxHandle.make_inert(effect if effect is FxDefinition else null)  # no lookup, no load: headless pays nothing
	_ensure_loaded()
	var def: FxDefinition = effect if effect is FxDefinition else _definitions.get(StringName(str(effect)))
	if def == null:
		_stats["unknown"] += 1
		_warn_once("fx: unknown effect '%s'" % str(effect))
		return FxHandle.make_inert()
	if depth > MAX_DEPTH:
		_warn_once("fx: %s nests sub-effects deeper than %d (a cycle?)" % [def.id, MAX_DEPTH])
		return FxHandle.make_inert(def)
	_ensure_hosts()
	anchor = _resolve_anchor(anchor if anchor != null else FxAnchor.screen())
	if anchor == null or not anchor.is_valid():
		_stats["skipped"] += 1
		return FxHandle.make_inert(def)
	anchor = anchor.placed(def.socket)  # the socket's place and the unit's radius, for this play
	# Spec vfx-stencil 3.3: a caller may mark another unit than the anchor's (a beam starting on its caster draws over the caster).
	if given_has(params, STENCIL_UNIT_PARAM):
		anchor.stencil_value = int(params[STENCIL_UNIT_PARAM] if params.has(STENCIL_UNIT_PARAM) else params[String(STENCIL_UNIT_PARAM)])
		anchor.stencil_forced = true
	_enforce_max_instances(def)
	var handle := FxHandle.new()
	handle.service = self
	handle.definition = def
	handle.anchor = anchor
	handle.depth = depth
	handle.params = _resolve_params(def, params)
	handle.instance = _acquire(def)
	_attach(handle)
	_prepare_layers(handle)
	_live.append(handle)
	_stats["plays"] += 1
	_plays_by_id[def.id] = int(_plays_by_id.get(def.id, 0)) + 1
	played.emit(handle)
	_dev_message(&"Verb.Start", handle)
	# Layers with no delay show on this frame. Only this handle moves: play() can run inside another handle's tick (a
	# sub-effect starting), and a nested advance() would tick that one again.
	_follow(handle)
	_tick_layers(handle)
	return handle


## Moves every live effect forward by `dt` seconds. The service's own clock calls this each frame.
func advance(dt: float) -> void:
	for handle in _live.duplicate():
		if handle.done:
			continue
		if not handle.anchor.is_valid() or not handle.instance.is_intact():
			_finish(handle)
			continue
		handle.elapsed += dt
		_follow(handle)
		_tick_layers(handle)
		if handle.done:
			continue
		var all_done := true
		for index in handle.states.size():
			if handle.states[index] == FxHandle.LayerState.PENDING or handle.states[index] == FxHandle.LayerState.RUNNING:
				all_done = false
			elif handle.quality_skipped[index] == 1 and handle.definition.is_looping() and not handle.stopping:
				all_done = false  # a looping effect left out by the tier stays alive: a higher tier brings it back
		if all_done or (handle.stopping and handle.elapsed >= handle.stop_at):
			_finish(handle)


## The tier changed (not to off): re-applies it to the looping effects that are playing. One-shots finish as they started.
func _requalify_live() -> void:
	for handle in _live.duplicate():
		if not handle.done and not handle.stopping and handle.definition.is_looping():
			_requalify(handle)


func _requalify(handle: FxHandle) -> void:
	var def := handle.definition
	for index in def.layers.size():
		var layer := def.layers[index]
		var node := handle.instance.nodes[index]
		if layer == null or node == null:
			continue
		var allowed := int(layer.min_quality) <= quality
		match handle.states[index]:
			FxHandle.LayerState.SKIPPED:
				if handle.quality_skipped[index] == 1 and allowed:
					handle.quality_skipped[index] = 0
					# The same setup as a play (review fix: a revived layer skipped it, so a sub-effect layer had no service and
					# a 3D layer with no host on this anchor ran outside the tree).
					_ready_layer(handle, index, handle.elapsed)
			FxHandle.LayerState.PENDING, FxHandle.LayerState.RUNNING:
				if not allowed:
					if handle.states[index] == FxHandle.LayerState.RUNNING:
						layer.stop(node, 0.0)
						layer.ended(node)
					layer.reset(node)
					handle.states[index] = FxHandle.LayerState.SKIPPED
					handle.quality_skipped[index] = 1
				elif handle.states[index] == FxHandle.LayerState.RUNNING:
					layer.apply(node, handle.params, handle.anchor, quality, def)  # the particle count follows the tier


## Stops every live effect at once (the run ended, a screen closed).
func stop_all() -> void:
	for handle in _live.duplicate():
		_finish(handle)


## Builds `count` pooled instances of an effect ahead of time (avoids a first-play hitch).
func prewarm(id: StringName, count: int = 1) -> void:
	var def := definition(id)
	if def == null:
		return
	var pool: Array = _pools.get(id, [])
	while pool.size() < mini(count, def.pool_size):
		pool.append(FxInstance.build(def))
		_stats["built"] += 1
	_pools[id] = pool


func live() -> Array[FxHandle]:
	return _live.duplicate()


func live_count(id: StringName = &"") -> int:
	if id == &"":
		return _live.size()
	var count := 0
	for handle in _live:
		if handle.definition.id == id:
			count += 1
	return count


func pool_size(id: StringName) -> int:
	return (_pools.get(id, []) as Array).size()


## Counters for `fx stats`: plays, skipped, unknown ids, recycled, instances built, pool hits, live now, plays by id.
func stats() -> Dictionary:
	var out := _stats.duplicate()
	out["live"] = _live.size()
	out["pooled"] = 0
	for id in _pools:
		out["pooled"] += (_pools[id] as Array).size()
	out["by_id"] = _plays_by_id.duplicate()
	out["quality"] = FxQuality.NAMES[quality]
	out["enabled"] = enabled
	return out


## Changes a parameter of a live effect (FxHandle.set_param).
func set_handle_param(handle: FxHandle, param_name: StringName, value: Variant) -> void:
	var coerced := _coerce(handle.definition, param_name, value)
	if not coerced["ok"]:
		return
	handle.params[param_name] = coerced["value"]
	for index in handle.definition.layers.size():
		var layer := handle.definition.layers[index]
		if layer != null and handle.states[index] in [FxHandle.LayerState.PENDING, FxHandle.LayerState.RUNNING]:
			layer.rebind(handle.instance.nodes[index], handle.params, handle.definition)


## A parameter value turned into the parameter's type and clamped: {ok, value}. Warns once for an unknown name, text
## that cannot be read, or a value of the wrong type.
func _coerce(def: FxDefinition, param_name: StringName, value: Variant) -> Dictionary:
	var spec := def.param(param_name)
	if spec == null:
		_warn_once("fx: %s has no parameter '%s'" % [def.id, param_name])
		return {"ok": false}
	if value is String and spec.kind != FxParam.Kind.COLOR:
		var parsed := spec.parse_text(value)
		if not parsed["ok"]:
			_warn_once("fx: %s.%s cannot read '%s'" % [def.id, param_name, value])
			return {"ok": false}
		value = parsed["value"]
	if not spec.accepts(value):
		_warn_once("fx: %s.%s is a %s, got %s" % [def.id, param_name, FxParam.Kind.keys()[spec.kind].to_lower(),
			type_string(typeof(value))])
		return {"ok": false}
	return {"ok": true, "value": spec.clamp_value(value)}


## Fades an effect out (FxHandle.stop).
func stop_handle(handle: FxHandle, fade: float) -> void:
	if handle.done or handle.stopping:
		return
	handle.stopping = true
	var wait := maxf(fade, 0.0)
	for index in handle.definition.layers.size():
		var layer := handle.definition.layers[index]
		var node := handle.instance.nodes[index]
		match handle.states[index]:
			FxHandle.LayerState.RUNNING:
				if not is_instance_valid(node):  # playtest-fixes B19: its node left with its anchor (a unit view freed)
					handle.states[index] = FxHandle.LayerState.DONE
					continue
				layer.stop(node, fade)
				wait = maxf(wait, layer.tail(node))
			FxHandle.LayerState.PENDING:
				handle.states[index] = FxHandle.LayerState.DONE
	handle.stop_at = handle.elapsed + wait
	if wait <= 0.0:
		_finish(handle)


# --- Internals ---------------------------------------------------------------------------------------------------

func _ensure_hosts() -> void:
	if world_root == null:
		world_root = Node3D.new()
		world_root.name = "FxWorld"
		add_child(world_root)
	if screen_layer == null:
		screen_layer = CanvasLayer.new()
		screen_layer.name = "FxScreen"
		screen_layer.layer = 100
		add_child(screen_layer)
		screen_root = Control.new()
		screen_root.name = "Root"
		screen_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		screen_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		screen_layer.add_child(screen_root)


func _resolve_anchor(anchor: FxAnchor) -> FxAnchor:
	if anchor.kind != FxAnchor.Kind.UNIT:
		return anchor
	if anchor.unit_id == &"":
		_warn_once("fx: a unit anchor needs a unit id")
		return null
	var view := unit_view(anchor.unit_id)
	if view == null:
		_warn_once("fx: no view for unit '%s'" % anchor.unit_id)
		return null
	return FxAnchor.node3d(view, anchor.offset)


## The 3D view of a battle unit by its unit id ("P1", "E2"), or null. A GameplayCue's target is an actor; for a unit that is this view.
func unit_view(unit_id: StringName) -> Node3D:
	if unit_resolver.is_valid():
		return unit_resolver.call(unit_id) as Node3D
	for candidate in get_tree().get_nodes_in_group(UnitAnimator.GROUP):
		if candidate.unit_id == unit_id and not candidate.is_queued_for_deletion():
			return candidate  # a view queued for deletion (the last battle's) is not the unit's view
	return null


## Spec vfx-stencil 3.3: a reserved parameter every effect takes, without declaring it: the stencil value to draw over (a beam marks
## its caster). The anchor's own unit when not given.
const STENCIL_UNIT_PARAM: StringName = &"stencil_unit"


## Spec vfx-stencil 3.4: has the renderer compile now the shader copies for `values` (stencil values × the shaders the registry's
## effects draw over their unit with × 2 passes), so no hit compiles one. Called three times, each skipping what an earlier one drew:
## - at boot, on the main menu (GameMain, every position the content can use, `per_frame` copies a batch so the menu never stalls);
## - at run start (GameMain, the same values: whatever boot has not finished yet);
## - at battle start (RoomView3D, no `values`: the battle's own positions, read from its unit views; normally nothing is left).
## Inert headless or with stencil off.
func prepare_stencil(camera: Camera3D, values: Array = [], per_frame: int = 0, label: String = "battle") -> void:
	if not enabled or not FxStencilShaders.enabled():
		return
	_ensure_loaded()
	if values.is_empty():
		for view in get_tree().get_nodes_in_group(UnitAnimator.GROUP):
			var value: int = (view as UnitAnimator).stencil_value
			if StencilIds.is_unit(value) and not value in values:
				values.append(value)
	var definitions: Array = []
	for id in catalog():
		definitions.append(definition(id))
	await FxStencilShaders.prepare(camera, FxStencilShaders.over_unit_shaders(definitions), values, per_frame, label)


static func given_has(params: Dictionary, key: StringName) -> bool:
	return params.has(key) or params.has(String(key))


func _resolve_params(def: FxDefinition, given: Dictionary) -> Dictionary:
	var out := def.default_params()
	for key in given:
		if StringName(str(key)) == STENCIL_UNIT_PARAM:
			continue  # spec vfx-stencil 3.3: reserved, every effect takes it (read by play, never a layer binding)
		var coerced := _coerce(def, StringName(str(key)), given[key])
		if coerced["ok"]:
			out[StringName(str(key))] = coerced["value"]
	return out


func _enforce_max_instances(def: FxDefinition) -> void:
	if def.is_looping():
		return  # the cap is a spam guard for one-shots; recycling a looping aura would take a unit's status visual away
	while live_count(def.id) >= maxi(def.max_instances, 1):
		var oldest: FxHandle = null
		for handle in _live:
			if handle.definition.id == def.id and not handle.ticking:
				oldest = handle
				break
		if oldest == null:
			return  # everything of this effect is mid-tick (a sub-effect chain): the depth cap ends it
		_stats["recycled"] += 1
		_finish(oldest)


func _acquire(def: FxDefinition) -> FxInstance:
	var pool: Array = _pools.get(def.id, [])
	while not pool.is_empty():
		var instance: FxInstance = pool.pop_back()
		if instance.definition == def and instance.is_intact():
			_stats["pool_hits"] += 1
			return instance
		instance.free_nodes()
	_stats["built"] += 1
	return FxInstance.build(def)


## Hangs the holders where the anchor needs them and decides how the 2D holder follows.
func _attach(handle: FxHandle) -> void:
	var anchor := handle.anchor
	var instance := handle.instance
	instance.detach()
	if instance.holder_state.get_child_count() > 0:
		add_child(instance.holder_state)  # state-only layers are not tied to the anchor
	if instance.uses_3d():
		var host: Node3D = null
		var local := anchor.offset + anchor.socket_offset
		match anchor.kind:
			FxAnchor.Kind.NODE3D:
				host = anchor.node as Node3D
			FxAnchor.Kind.POSITION3D:
				host = world_root
				local = anchor.position + anchor.offset
			FxAnchor.Kind.SCREEN:
				host = world_root
				local = Vector3.ZERO
			FxAnchor.Kind.STAGE:
				host = anchor.node as Node3D if anchor.node != null else anchor.stage.world_root
		if host != null:
			instance.holder_3d.position = local
			host.add_child(instance.holder_3d)
	if instance.uses_ui():
		var parent: Control = null
		handle.ui_follow = Follow.NONE
		instance.holder_ui.top_level = false
		instance.holder_ui.visible = true  # a projected holder hides itself behind the camera; a reused one starts shown
		instance.holder_ui.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		if handle.definition.space == FxDefinition.Space.SCREEN and anchor.kind != FxAnchor.Kind.CONTROL:
			# A screen effect fills the window (or the stage it was given), wherever it was anchored.
			parent = anchor.stage.overlay if anchor.kind == FxAnchor.Kind.STAGE else screen_root
			handle.ui_follow = Follow.SCREEN
		else:
			match anchor.kind:
				FxAnchor.Kind.CONTROL:
					parent = anchor.node as Control
					instance.holder_ui.top_level = true
					handle.ui_follow = Follow.COPY_CONTROL
				FxAnchor.Kind.SCREEN:
					parent = screen_root
					handle.ui_follow = Follow.SCREEN
				FxAnchor.Kind.STAGE:
					parent = anchor.stage.overlay
					handle.ui_follow = Follow.PROJECT_STAGE if anchor.node != null or anchor.offset != Vector3.ZERO else Follow.SCREEN
				_:
					parent = screen_root
					handle.ui_follow = Follow.PROJECT
		if parent != null:
			parent.add_child(instance.holder_ui)


func _prepare_layers(handle: FxHandle) -> void:
	var def := handle.definition
	var instance := handle.instance
	var count := def.layers.size()
	handle.states.resize(count)
	handle.starts.resize(count)
	handle.ends.resize(count)
	handle.quality_skipped.resize(count)
	for index in count:
		var layer := def.layers[index]
		var node := instance.nodes[index]
		handle.states[index] = FxHandle.LayerState.SKIPPED
		handle.quality_skipped[index] = 0
		if layer != null and node != null and int(layer.min_quality) > quality:
			handle.quality_skipped[index] = 1
			continue
		if layer == null or node == null:
			continue
		_ready_layer(handle, index, 0.0)


## Sets one layer up to run from `at` (the effect's own time): it needs a host for its space on this anchor (a 3D layer on a
## Control has none and stays SKIPPED), then its service and depth, its parameters, and its start and end.
func _ready_layer(handle: FxHandle, index: int, at: float) -> void:
	var layer := handle.definition.layers[index]
	var node := handle.instance.nodes[index]
	var holder: Node = handle.instance.holder_of(index)
	if holder == null or holder.get_parent() == null:
		return  # no host for this space on this anchor (a 3D layer on a Control)
	node.set_meta(META_SERVICE, self)
	node.set_meta(META_DEPTH, handle.depth)
	layer.apply(node, handle.params, handle.anchor, quality, handle.definition)
	handle.starts[index] = at + layer.start_delay
	handle.ends[index] = handle.starts[index] + layer.length(node, handle.params)
	handle.states[index] = FxHandle.LayerState.PENDING


func _tick_layers(handle: FxHandle) -> void:
	handle.ticking = true
	_tick_layers_inner(handle)
	handle.ticking = false


func _tick_layers_inner(handle: FxHandle) -> void:
	var def := handle.definition
	for index in def.layers.size():
		var layer := def.layers[index]
		var node := handle.instance.nodes[index]
		match handle.states[index]:
			FxHandle.LayerState.PENDING:
				if handle.elapsed >= handle.starts[index] and not handle.stopping:
					handle.states[index] = FxHandle.LayerState.RUNNING
					layer.start(node)
				else:
					continue
		if handle.states[index] == FxHandle.LayerState.RUNNING:
			var length := handle.ends[index] - handle.starts[index]
			layer.update(node, handle.elapsed - handle.starts[index], length, handle.params)
			if handle.elapsed >= handle.ends[index] or layer.is_finished(node):
				layer.stop(node, 0.0)
				layer.ended(node)
				handle.states[index] = FxHandle.LayerState.DONE


## Keeps the 2D holder on the anchor (a control's rectangle, or a 3D node projected to the screen).
func _follow(handle: FxHandle) -> void:
	var holder := handle.instance.holder_ui
	if handle.instance.holder_ui.get_parent() == null:
		return
	match handle.ui_follow:
		Follow.COPY_CONTROL:
			var target := handle.anchor.node as Control
			var transform := target.get_global_transform()
			holder.size = target.size
			holder.pivot_offset = target.pivot_offset
			holder.rotation = transform.get_rotation()
			holder.scale = transform.get_scale()
			holder.global_position = target.global_position
		Follow.SCREEN:
			holder.size = holder.get_parent().size
			holder.position = Vector2.ZERO
		Follow.PROJECT:
			var place: Variant = handle.anchor.world_position()
			var camera := get_viewport().get_camera_3d()
			var node := handle.anchor.node
			if node != null and is_instance_valid(node) and node.get_viewport() != get_viewport():
				camera = null  # a node inside another viewport (not a stage) has no place on the window's screen layer
			holder.size = Vector2.ZERO
			holder.visible = place != null and camera != null and not camera.is_position_behind(place)
			if holder.visible:
				holder.position = camera.unproject_position(place)
		Follow.PROJECT_STAGE:
			var place: Variant = handle.anchor.world_position()
			holder.size = Vector2.ZERO
			holder.visible = place != null and not handle.anchor.stage.is_behind_camera(place)
			if holder.visible:
				holder.position = handle.anchor.stage.project(place)


## Ends an effect now: layers back to rest, nodes back to the pool.
func _finish(handle: FxHandle) -> void:
	if handle.done:
		return
	handle.done = true
	var def := handle.definition
	var instance := handle.instance
	if instance != null and instance.is_intact():
		for index in def.layers.size():
			var layer := def.layers[index]
			if layer != null and instance.nodes[index] != null:
				layer.reset(instance.nodes[index])
		instance.detach()
		var pool: Array = _pools.get(def.id, [])
		if pool.size() < def.pool_size:
			pool.append(instance)
			_pools[def.id] = pool
		else:
			instance.free_nodes()
	elif instance != null:
		# The anchor (and the holders it carried) is gone: give back what layers changed outside their own nodes (a camera
		# offset, a shared original) before dropping the instance.
		for index in def.layers.size():
			var layer := def.layers[index]
			if layer != null and index < instance.nodes.size() and is_instance_valid(instance.nodes[index]):
				layer.ended(instance.nodes[index])
		instance.free_nodes()
	_live.erase(handle)
	_stats["finished"] += 1
	handle.service = null
	if _closing:
		return
	_dev_message(&"Verb.Stop", handle)
	handle.finished.emit()
	finished.emit(handle)


func _warn_once(text: String) -> void:
	if not _warned.has(text):
		_warned[text] = true
		push_warning(text)


func _dev_message(verb: StringName, handle: FxHandle) -> void:
	if dev_messages and handle.definition != null:
		GameplayMessages.broadcast(GameplayMessageRouter.DEV_FX, VerbMessage.make(verb, handle.definition.id,
			StringName(handle.anchor.describe()) if handle.anchor != null else &"", 0, [], {"params": handle.params}))
