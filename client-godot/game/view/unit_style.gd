## Spec cube-style 3.6: the game's StyleRegistry, loaded on first use. A headless process (the verifier, the replay, trace and step
## runners, tests and tools) loads nothing (the rule FxManager follows), so it never touches presentation/demo/style/; tests and the
## console set a registry explicitly with use(). Presentation only.
class_name UnitStyle
extends RefCounted

const DEFAULT_REGISTRY: String = "res://presentation/demo/style/style_registry.tres"

## The registry in use (null = today's look everywhere).
static var _registry: StyleRegistry
static var _loaded: bool = false
## Where the registry came from ("" = none), for the console.
static var source: String = ""
## The console's `style mood <chapter>`: every room shows this chapter's mood; &"" = each room its own.
static var mood_override: StringName = &""


## The registry, loading DEFAULT_REGISTRY the first time outside a headless process.
static func registry() -> StyleRegistry:
	if not _loaded:
		_loaded = true
		if DisplayServer.get_name() != "headless" and ResourceLoader.exists(DEFAULT_REGISTRY):
			_registry = load(DEFAULT_REGISTRY) as StyleRegistry
			source = DEFAULT_REGISTRY if _registry != null else ""
	return _registry


## Uses `registry` from now on (null = today's look), also headless. `from` names it for the console.
static func use(registry: StyleRegistry, from: String = "") -> void:
	_loaded = true
	_registry = registry
	source = from


## Loads the registry at `path` (any res:// path, a round's variant included) and uses it. "" or the error.
static func use_path(path: String) -> String:
	if not ResourceLoader.exists(path):
		return "no file %s" % path
	# REPLACE re-reads this file (a reload after editing it) but keeps its dependencies (a variant's base, the scripts) cached:
	# a deep replace would reload the scripts and the shared main registry under the live views.
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as StyleRegistry
	if loaded == null:
		return "%s is not a StyleRegistry" % path
	# A variant's base files are re-read too (in place, so the variant's `base` sees them): a reload after editing the main
	# registry shows the edit while a variant over it is in use.
	for registry in loaded.chain().slice(1):
		if registry.resource_path != "" and ResourceLoader.exists(registry.resource_path):
			ResourceLoader.load(registry.resource_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	use(loaded, path)
	return ""


## Forgets the registry: the next registry() loads the default again (headless: nothing).
static func reset() -> void:
	_loaded = false
	_registry = null
	source = ""
	mood_override = &""


## The look of `definition`, or null when no registry is in use (a view then paints today's look).
static func look_for(definition: UnitDefinition) -> UnitLook:
	var current := registry()
	return current.look_for(definition) if current != null else null


## The mood of `chapter_id` (or of the console's override), or null (today's look).
static func mood_for(chapter_id: StringName) -> StageMood:
	var current := registry()
	if current == null:
		return null
	return current.mood_for(mood_override if mood_override != &"" else chapter_id)


static func explore_framing() -> CameraFraming:
	var current := registry()
	return current.explore_framing() if current != null else CameraFraming.today()


static func battle_framing() -> CameraFraming:
	var current := registry()
	return current.battle_framing() if current != null else CameraFraming.today()
