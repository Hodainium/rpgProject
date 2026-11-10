## Runs the FxTagCue rules on a battle's units (spec vfx-content-pass): listens to each unit's ability system for `tag_added` / `tag_removed`
## and executes the rule's cues through GodotGAS's cue manager on the unit's view. One per battle shown; the connections end with the
## battle's units. Presentation only: it never changes a unit, and a headless run makes none.
class_name FxTagCues
extends RefCounted

var _rules: Array = []
## "unit_id|tag" -> the persistent cue node playing for it.
var _live: Dictionary = {}
## [asc, added Callable, removed Callable] per watched unit, so detach() can let go.
var _connections: Array = []


## Watches every unit of `battle`.
func attach(battle: Battle, rules: Array) -> void:
	for unit in battle.units():
		attach_unit(unit.asc, unit.unit_id, rules)


## Watches one ability system whose unit is `unit_id` (the unit's view is found through the effects service). A tag the unit
## already has (a member carried over dead, a status from the battle's start) starts its present cue now; its added cue is a
## moment that already passed and does not play (review fix).
func attach_unit(asc: AbilitySystemComponent, unit_id: StringName, rules: Array) -> void:
	_rules = rules
	var added := _on_added.bind(unit_id, asc)
	var removed := _on_removed.bind(unit_id, asc)
	asc.tag_added.connect(added)
	asc.tag_removed.connect(removed)
	_connections.append([asc, added, removed])
	for rule in _rules:
		if rule is FxTagCue and rule.present_cue != &"" and asc.has_tag_exact(rule.tag):
			_start_present(rule, rule.tag, unit_id, asc)


## Stops watching and ends every look still playing (the battle is over, another one starts).
func detach() -> void:
	for entry in _connections:
		if is_instance_valid(entry[0]):
			if entry[0].tag_added.is_connected(entry[1]):
				entry[0].tag_added.disconnect(entry[1])
			if entry[0].tag_removed.is_connected(entry[2]):
				entry[0].tag_removed.disconnect(entry[2])
	_connections.clear()
	for key in _live:
		if is_instance_valid(_live[key]):
			GameplayCueManager.remove_persistent_cue(_live[key])
	_live.clear()


func _on_added(tag: StringName, unit_id: StringName, asc: AbilitySystemComponent) -> void:
	for rule in _rules:
		if rule is FxTagCue and rule.tag == tag:
			var view := _view(unit_id)
			if view == null:
				continue
			if rule.added_cue != &"":
				GameplayCueManager.execute_cue(rule.added_cue, view, _payload(tag, unit_id, asc))
			if rule.present_cue != &"":
				_start_present(rule, tag, unit_id, asc)


func _start_present(rule: FxTagCue, tag: StringName, unit_id: StringName, asc: AbilitySystemComponent) -> void:
	var key := "%s|%s" % [unit_id, tag]
	var view := _view(unit_id)
	if view == null or (_live.has(key) and is_instance_valid(_live[key])):
		return
	var cue := GameplayCueManager.add_persistent_cue(rule.present_cue, view, _payload(tag, unit_id, asc))
	if cue != null:
		_live[key] = cue


## A tag cue's payload: the tag, the unit, and its ability system (so FxCueBinding's TARGET_TAGS can read the unit's tags).
static func _payload(tag: StringName, unit_id: StringName, asc: AbilitySystemComponent) -> Dictionary:
	return {"tag": tag, "unit": unit_id, "asc": asc}


func _on_removed(tag: StringName, unit_id: StringName, asc: AbilitySystemComponent) -> void:
	var key := "%s|%s" % [unit_id, tag]
	if _live.has(key):
		var cue: GameplayCueNotify = _live[key]
		_live.erase(key)
		if is_instance_valid(cue):
			GameplayCueManager.remove_persistent_cue(cue)
	for rule in _rules:
		if rule is FxTagCue and rule.tag == tag and rule.removed_cue != &"":
			var view := _view(unit_id)
			if view != null:
				GameplayCueManager.execute_cue(rule.removed_cue, view, _payload(tag, unit_id, asc))


func _view(unit_id: StringName) -> Node3D:
	var service: FxService = FxCueNotify.service_override if FxCueNotify.service_override != null \
		else Engine.get_main_loop().root.get_node_or_null("FxManager") as FxService
	return service.unit_view(unit_id) if service != null else null
