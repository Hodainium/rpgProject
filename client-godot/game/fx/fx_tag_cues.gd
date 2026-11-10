## Runs the FxTagCue rules on a battle's units (spec vfx-content-pass): listens to each unit's ability system for `tag_added` / `tag_removed`
## and executes the rule's cues through GodotGAS's cue manager on the unit's view. One per battle shown; the connections end with the
## battle's units. Presentation only: it never changes a unit, and a headless run makes none.
class_name FxTagCues
extends RefCounted

var _rules: Array = []
## "unit_id|tag" -> the persistent cue node playing for it.
var _live: Dictionary = {}


## Watches every unit of `battle`.
func attach(battle: Battle, rules: Array) -> void:
	for unit in battle.units():
		attach_unit(unit.asc, unit.unit_id, rules)


## Watches one ability system whose unit is `unit_id` (the unit's view is found through the effects service).
func attach_unit(asc: AbilitySystemComponent, unit_id: StringName, rules: Array) -> void:
	_rules = rules
	asc.tag_added.connect(_on_added.bind(unit_id))
	asc.tag_removed.connect(_on_removed.bind(unit_id))


func _on_added(tag: StringName, unit_id: StringName) -> void:
	for rule in _rules:
		if rule is FxTagCue and rule.tag == tag:
			var view := _view(unit_id)
			if view == null:
				continue
			if rule.added_cue != &"":
				GameplayCueManager.execute_cue(rule.added_cue, view, {"tag": tag, "unit": unit_id})
			if rule.present_cue != &"":
				var cue := GameplayCueManager.add_persistent_cue(rule.present_cue, view, {"tag": tag, "unit": unit_id})
				if cue != null:
					_live["%s|%s" % [unit_id, tag]] = cue


func _on_removed(tag: StringName, unit_id: StringName) -> void:
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
				GameplayCueManager.execute_cue(rule.removed_cue, view, {"tag": tag, "unit": unit_id})


func _view(unit_id: StringName) -> Node3D:
	var service: FxService = FxCueNotify.service_override if FxCueNotify.service_override != null \
		else Engine.get_main_loop().root.get_node_or_null("FxManager") as FxService
	return service.unit_view(unit_id) if service != null else null
