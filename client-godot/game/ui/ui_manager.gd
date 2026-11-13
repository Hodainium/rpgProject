## Spec ui-framework 2.1–2.4 (Lyra: the UI manager subsystem with CommonUI layer stacks and the UI extension
## subsystem): builds the policy's layout, pushes and pops screens on layer stacks, plugs panels into extension slots,
## and applies the policy's rules whenever the UI state tags change. Holds no game rules: it reads GameMain's mode
## and the run only to compute the state tags.
class_name UIManager
extends Node

## A layer's stack changed (push, pop, remove, clear).
signal stack_changed(layer: StringName)

## The layer whose screens are menus over the run (spec ff7-ui 2.12: while one is open the state has UI.State.Run.Menu).
const GAME_MENU: StringName = &"UI.Layer.GameMenu"
## Run signals after which the UI state may differ.
const RUN_SIGNALS: Array[StringName] = [&"floor_entered", &"room_entered", &"room_cleared", &"battle_requested",
	&"battle_started", &"battle_finished", &"event_page_shown", &"pickups_shown", &"party_changed", &"run_ended",
	&"map_revealed"]

var policy: UIPolicy
var context: UIContext
var layout: UILayout
## Problems found while building or applying the policy (also pushed as warnings).
var problems := PackedStringArray()

var _main: GameMain
var _stacks: Dictionary = {}  # layer tag -> UILayerStack
var _points: Array[UIExtensionPoint] = []
var _rule_screens: Dictionary = {}  # UIScreenRule -> UIScreen
var _panels: Dictionary = {}  # UIExtensionPoint -> {UIExtension: Node}
var _parked: Dictionary = {}  # panel -> true: kept hidden while its extension's state is off (_park)
var _dirty: bool = false


## Builds the layout under `parent` (a CanvasLayer). "" or why it failed.
func setup(main: GameMain, ui_policy: UIPolicy, parent: Node) -> String:
	_main = main
	policy = ui_policy
	if policy == null or policy.layout == null:
		return "the UI policy has no layout"
	var root := policy.layout.instantiate()
	if not root is UILayout:
		root.free()
		return "the UI policy's layout must have a UILayout root (%s)" % policy.layout.resource_path
	layout = root
	if policy.theme != null:
		layout.theme = policy.theme
	parent.add_child(layout)
	for stack in layout.stacks():
		_stacks[stack.layer] = stack
	_register_points(layout)
	context = UIContext.new(main, self)
	stack_changed.connect(func(layer: StringName):
		if layer == GAME_MENU:
			refresh_state())
	if main != null:
		main.mode_changed.connect(func(_mode): refresh_state())
		main.run_changed.connect(_on_run_changed)
		if main.run != null:
			_on_run_changed(main.run)
	apply_now()
	return ""


# --- Stacks (CommonUI) ----------------------------------------------------------------------------------------------

## Pushes `scene` onto `layer`'s stack (the screen below is deactivated and kept). The same scene already on that
## stack moves to the top instead of opening twice. Returns the screen, or null (warning) when it can't.
func push(layer: StringName, scene: PackedScene, payload: Dictionary = {}) -> UIScreen:
	var stack: UILayerStack = _stacks.get(layer)
	if stack == null:
		_problem("no layer %s in the layout" % layer)
		return null
	if scene == null:
		_problem("push to %s: no scene" % layer)
		return null
	for existing in stack.screens():
		if existing.source_scene == scene:
			_raise(stack, existing)
			return existing
	var node := scene.instantiate()
	if not node is UIScreen:
		node.free()
		_problem("%s: its root must extend UIScreen" % scene.resource_path)
		return null
	var screen: UIScreen = node
	screen.source_scene = scene
	var below := stack.top()
	if below != null:
		below._ui_deactivate()
	screen.visible = false
	stack.add_child(screen)
	_register_points(screen)
	screen._ui_bind(context)
	screen.on_pushed(payload)
	screen._ui_activate()
	_apply_extensions()
	stack_changed.emit(layer)
	return screen


## Back (Esc, a UIBackButton): the topmost layer holding a screen decides. Its top screen may consume Back itself;
## a screen a player opened is popped; a screen the policy's rules own is never popped. With nothing to close, the
## first of the policy's back_screens whose state matches is pushed (the run menu). True when something happened.
func back() -> bool:
	var all: Array = layout.stacks() if layout != null else []
	for index in range(all.size() - 1, -1, -1):
		var stack: UILayerStack = all[index]
		var top := stack.top()
		if top == null:
			continue
		if top.handles_back():
			return true
		if not stack.back_pops or top.owned_by_rule:
			# Spec ff7-ui 2.4: a HUD panel with pages of its own (the battle command window) steps back first.
			if _panels_handle_back():
				return true
			break
		remove(top)
		return true
	if policy != null:
		for rule in policy.back_screens:
			if rule != null and TagMatch.matches(rule.active_when, context.state):
				return push(rule.layer, rule.scene) != null
	return false


func _panels_handle_back() -> bool:
	for placed in _panels.values():
		for panel in placed.values():
			if panel is UIScreen and is_instance_valid(panel) and panel.active and panel.handles_back():
				return true
	return false


## Removes `screen` and every screen above it on its stack; the screen below becomes active again.
func remove(screen: UIScreen) -> void:
	if screen == null or not is_instance_valid(screen):
		return
	var stack := screen.get_parent() as UILayerStack
	if stack == null:
		return
	var screens := stack.screens()
	var at := screens.find(screen)
	for index in range(screens.size() - 1, at - 1, -1):
		_free_screen(screens[index])
	var top := stack.top()
	if top != null:
		top._ui_activate()
	stack_changed.emit(stack.layer)


## Empties a layer.
func clear(layer: StringName) -> void:
	var stack: UILayerStack = _stacks.get(layer)
	if stack == null:
		return
	var screens := stack.screens()
	if screens.is_empty():
		return
	remove(screens[0])


## The top screen of a layer, or null.
func top(layer: StringName) -> UIScreen:
	var stack: UILayerStack = _stacks.get(layer)
	return stack.top() if stack != null else null


## The layer tags, bottom to top.
func layers() -> Array[StringName]:
	var found: Array[StringName] = []
	if layout != null:
		for stack in layout.stacks():
			found.append(stack.layer)
	return found


## A yes/no question on the Modal layer (the policy's confirm_scene, root UIConfirm). Await it: true for yes.
func confirm(text: String, yes_label: String = "Yes", no_label: String = "No") -> bool:
	if policy == null or policy.confirm_scene == null:
		_problem("the UI policy has no confirm_scene")
		return false
	var dialog := push(&"UI.Layer.Modal", policy.confirm_scene, {"text": text, "yes": yes_label, "no": no_label})
	if not dialog is UIConfirm:
		if dialog != null:
			remove(dialog)
		_problem("the confirm_scene's root must extend UIConfirm")
		return false
	var answer: bool = await dialog.decided
	remove(dialog)
	return answer


## The extension point registered for `slot` (the first one), or null. Lets a panel make room for another (spec
## ff7-ui 2.11: the Tab floor toast centres left of the grown map).
func point(slot: StringName) -> UIExtensionPoint:
	for candidate in _points:
		if _live(candidate) and candidate.slot == slot:
			return candidate
	return null


## Each layer's stack and each slot's panels, for the console's `ui` command.
func dump() -> String:
	var lines := PackedStringArray(["state: " + ", ".join(context.state)])
	for stack in layout.stacks():
		var names := PackedStringArray()
		for screen in stack.screens():
			names.append("%s%s" % [screen.name, " (rule)" if screen.owned_by_rule else ""])
		lines.append("%s: %s" % [stack.layer, " > ".join(names) if not names.is_empty() else "-"])
	for point in _points:
		var names := PackedStringArray()
		for child in point.get_children():
			if not child.is_queued_for_deletion() and not _parked.has(child):  # a parked panel is not shown
				names.append(String(child.name))
		lines.append("%s: %s" % [point.slot, ", ".join(names) if not names.is_empty() else "-"])
	return "\n".join(lines)


# --- Rules (the policy) ---------------------------------------------------------------------------------------------

## The state may have changed: rules are applied once, at the end of this frame, on the latest state.
func refresh_state() -> void:
	if _dirty:
		return
	_dirty = true
	apply_now.call_deferred()


## Recomputes the state tags and applies every rule now.
func apply_now() -> void:
	_dirty = false
	if context == null or not is_instance_valid(layout):
		return
	var tags := UIState.compute(_main.mode if _main != null else "menu", context.run)
	var menu: UILayerStack = _stacks.get(GAME_MENU)
	if tags.has(UIState.RUN) and menu != null and menu.top() != null:
		tags.append(UIState.MENU_OPEN)
		tags.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	var changed := tags != context.state
	context.state = tags
	# Removals first, then pushes: remove() also drops every screen above the one removed, so a screen pushed earlier in
	# the same pass onto the same layer (the title menu over the run-end screen) would vanish with it.
	for rule in policy.screens:
		if rule == null:
			continue
		var screen: UIScreen = _rule_screens.get(rule)
		if screen != null and (not is_instance_valid(screen) or screen.get_parent() == null):
			_rule_screens.erase(rule)
		elif screen != null and not TagMatch.matches(rule.active_when, tags):
			_rule_screens.erase(rule)
			remove(screen)
	for rule in policy.screens:
		if rule == null or _rule_screens.has(rule) or not TagMatch.matches(rule.active_when, tags):
			continue
		if rule.clears_layer != &"":
			clear(rule.clears_layer)
		var pushed := push(rule.layer, rule.scene)
		if pushed != null:
			pushed.owned_by_rule = true
			_rule_screens[rule] = pushed
	_apply_extensions()
	if changed:
		context.state_changed.emit(tags)


func _apply_extensions() -> void:
	if policy == null:
		return
	_points = _points.filter(func(point) -> bool: return _live(point))
	for panel in _parked.keys():
		if not is_instance_valid(panel):
			_parked.erase(panel)
	for point in _panels.keys():
		if not _points.has(point):
			_panels.erase(point)
	for point in _points:
		var placed: Dictionary = _panels.get(point, {})
		for extension in policy.extensions:
			if extension == null or extension.slot != point.slot:
				continue
			var wanted := TagMatch.matches(extension.active_when, context.state)
			var panel: Node = placed.get(extension)
			if panel != null and not is_instance_valid(panel):
				placed.erase(extension)
				panel = null
			if wanted and panel != null and _parked.has(panel):
				_unpark(panel)
			elif wanted and panel == null and extension.scene != null:
				panel = extension.scene.instantiate()
				panel.set_meta("ui_order", extension.order)
				point.add_child(panel)
				_sort(point)
				placed[extension] = panel
				_register_points(panel)
				if panel is UIScreen:
					panel._ui_bind(context)
					panel.on_pushed({})
					panel._ui_activate()
			elif not wanted and panel != null and not _parked.has(panel):
				if panel is CanvasItem:
					_park(panel)  # kept, hidden, for the next time its state comes back
				else:
					placed.erase(extension)
					point.remove_child(panel)
					panel.queue_free()
		_panels[point] = placed


## Spec ui-framework 3.4 (playtest fix 2026-11-13, the battle-to-room hitch): a panel whose state ends is hidden and kept,
## not freed, so the next battle or room shows it again without building it (building the HUD cost about 23 ms plus a
## heavy first frame). A UIScreen panel is deactivated (on_deactivated, hidden) and activated again (on_activated
## refreshes it); the panel keeps its run connections, which it made once in bind().
func _park(panel: CanvasItem) -> void:
	_parked[panel] = true
	if panel is UIScreen:
		panel._ui_deactivate()
	panel.visible = false


func _unpark(panel: CanvasItem) -> void:
	_parked.erase(panel)
	if panel is UIScreen:
		panel._ui_activate()  # shows it, then on_activated() refreshes it once
	else:
		panel.visible = true


## True when `panel` is kept hidden while its state is off.
func is_parked(panel: Node) -> bool:
	return _parked.has(panel)


static func _live(point: Node) -> bool:
	return is_instance_valid(point) and point.is_inside_tree() and not point.is_queued_for_deletion()


static func _sort(point: UIExtensionPoint) -> void:
	var children := point.get_children()
	children.sort_custom(func(a, b) -> bool: return int(a.get_meta("ui_order", 0)) < int(b.get_meta("ui_order", 0)))
	for index in children.size():
		point.move_child(children[index], index)


func _register_points(root: Node) -> void:
	if root is UIExtensionPoint and not _points.has(root):
		_points.append(root)
	for child in root.get_children():
		_register_points(child)


func _raise(stack: UILayerStack, screen: UIScreen) -> void:
	if stack.top() == screen:
		return
	stack.top()._ui_deactivate()
	stack.move_child(screen, -1)
	screen._ui_activate()
	stack_changed.emit(stack.layer)


func _free_screen(screen: UIScreen) -> void:
	screen._ui_deactivate()
	screen.get_parent().remove_child(screen)
	screen.queue_free()


func _on_run_changed(run: RunController) -> void:
	for signal_name in RUN_SIGNALS:
		if run.has_signal(signal_name):
			run.connect(signal_name, func(_a = null, _b = null): refresh_state())
	context._set_run(run)
	refresh_state()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") and layout != null and back():
		get_viewport().set_input_as_handled()


func _problem(text: String) -> void:
	problems.append(text)
	push_warning("UI: " + text)
