## Spec gameplay-messages 3.1: what GameplayMessages.listen() returns; unregister() stops the listener at once.
class_name GameplayMessageHandle
extends RefCounted

var _router: WeakRef
var _entry: Dictionary


func _init(router: Object = null, entry: Dictionary = {}) -> void:
	_router = weakref(router) if router != null else null
	_entry = entry


func unregister() -> void:
	var router: Object = _router.get_ref() if _router != null else null
	if router != null:
		router.unregister(_entry)
	_entry = {}


func is_valid() -> bool:
	return not _entry.is_empty() and not _entry.get("removed", true) and _router != null and _router.get_ref() != null
