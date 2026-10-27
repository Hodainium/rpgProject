## Spec ui-framework 3.1: the base of every screen and panel (Lyra / CommonUI: an activatable widget). The UIManager
## pushes screens onto layer stacks and adds panels to extension slots; it calls, in order:
##   bind(ctx)            once, after the screen is in the tree (@onready vars are set): connect to ctx.on_run(...)
##   on_pushed(payload)   once, with what the pusher passed (a UIPushButton's payload, ctx.ui.push(..., payload))
##   on_activated()       each time the screen becomes the top of its stack (or its slot shows it)
##   on_deactivated()     each time another screen covers it, or before it is removed
## A covered screen is hidden and keeps its state; Back returns to it as it was. A screen never changes the run except
## through RunController's public methods, and never changes combat state.
class_name UIScreen
extends Control

## Node to focus each time the screen activates (keyboard and gamepad start here). Empty: no focus change.
@export var focus_on_activate: NodePath

var ctx: UIContext
## True while the screen is the active top of its stack (or shown in its slot).
var active: bool = false
## Set by the UIManager when a policy rule (not a player action) pushed this screen: Back never pops it.
var owned_by_rule: bool = false
## The scene this screen was made from (no duplicates on one stack).
var source_scene: PackedScene


## Override: connect to the run with ctx.on_run(self, "signal", callable), read ctx.main, ctx.run, ctx.state.
func bind(_context: UIContext) -> void:
	pass


## Override: the data this screen was opened with ({} when none).
func on_pushed(_payload: Dictionary) -> void:
	pass


## Override: the screen is shown and on top; refresh what it shows.
func on_activated() -> void:
	refresh()


## Override: the screen is covered or about to be removed.
func on_deactivated() -> void:
	pass


## Override: true when the screen consumed Back itself (closing its own picker); false lets the stack pop it.
func handles_back() -> bool:
	return false


## Override: rebuild what the screen shows from ctx. Called on activation; call it yourself after changes.
func refresh() -> void:
	pass


## The context of the screen `node` sits in (the nearest UIScreen ancestor that is bound), or null.
static func context_of(node: Node) -> UIContext:
	var current := node
	while current != null:
		if current is UIScreen and current.ctx != null:
			return current.ctx
		current = current.get_parent()
	return null


# --- Called by UIManager only ---------------------------------------------------------------------------------------

func _ui_bind(context: UIContext) -> void:
	if ctx != null:
		return
	ctx = context
	bind(context)


func _ui_activate() -> void:
	if active:
		return
	active = true
	visible = true
	on_activated()
	if not focus_on_activate.is_empty():
		var target := get_node_or_null(focus_on_activate) as Control
		if target != null and target.is_visible_in_tree():
			_focus_later.call_deferred(target)


## The focus lands a frame later; by then a rule may have taken the screen (or its button) out of the tree.
## Untyped on purpose: a freed target can't be passed as a typed Control.
static func _focus_later(target: Variant) -> void:
	if is_instance_valid(target) and target.is_inside_tree() and target.is_visible_in_tree():
		target.grab_focus()


func _ui_deactivate() -> void:
	if not active:
		return
	active = false
	on_deactivated()
	visible = false
