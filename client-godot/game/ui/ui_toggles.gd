## Playtest-fixes B28: input actions that toggle a view on each press instead of showing it while held (Tab: the grown map
## and the floor toast). One state per action, shared by every panel that reads it, so a panel that was hidden at the press
## still agrees. UIManager registers the actions and flips them; the console's `tab on|off` sets them. Presentation only.
class_name UIToggles
extends RefCounted

static var _on: Dictionary = {}


## Makes `action` a toggle (off at first). Idempotent.
static func register(action: StringName) -> void:
	if not _on.has(action):
		_on[action] = false


static func is_toggle(action: StringName) -> bool:
	return _on.has(action)


static func is_on(action: StringName) -> bool:
	return bool(_on.get(action, false))


static func set_on(action: StringName, on: bool) -> void:
	_on[action] = on


static func toggle(action: StringName) -> bool:
	_on[action] = not is_on(action)
	return _on[action]
