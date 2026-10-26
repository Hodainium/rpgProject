## Spec ui-framework 2.5 (CommonUI: a list view with an entry widget): put this script on any container and set its
## entry scene. set_items() makes one entry per item, in order, reusing the entries it already has; each entry's root
## script has `set_item(item, ctx)` and builds itself from its item (a pickup row, a member card, a route button).
class_name UIList
extends Container

## Emitted with the entry node and its item after the entry was (re)filled, for screens that wire entry signals.
signal entry_filled(entry: Node, item: Variant)

@export var entry_scene: PackedScene


## One entry per item; extra entries are freed. Returns the entries in order.
func set_items(items: Array) -> Array[Node]:
	var context := UIScreen.context_of(self)
	var entries: Array[Node] = []
	var existing := get_children().filter(func(child) -> bool: return not child.is_queued_for_deletion())
	for index in items.size():
		var entry: Node = existing[index] if index < existing.size() else null
		if entry == null:
			if entry_scene == null:
				push_warning("UIList %s: no entry_scene" % get_path())
				break
			entry = entry_scene.instantiate()
			add_child(entry)
		if entry.has_method("set_item"):
			entry.set_item(items[index], context)
		entry_filled.emit(entry, items[index])
		entries.append(entry)
	for index in range(items.size(), existing.size()):
		remove_child(existing[index])
		existing[index].queue_free()
	return entries
