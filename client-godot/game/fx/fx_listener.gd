## "When this message is broadcast, play that effect" as data (spec vfx-framework 2): a screen gives itself a list of
## these and calls attach(). It registers on the GameplayMessages bus and goes away with its node, like any listener.
##   var listener := FxListener.new(); listener.channel = &"Message.Run.LevelUp"; listener.effect = level_up_fx
##   listener.attach(self)
## Presentation only: the listener never changes the run or a battle.
class_name FxListener
extends Resource

enum AnchorRule { SCREEN, OWNER, TARGET_UNIT, INSTIGATOR_UNIT }

@export var channel: StringName
## Hear child channels too (Message.Battle hears Message.Battle.Broken).
@export var partial: bool = false
@export var effect: FxDefinition
## A GameplayCue tag to execute instead of playing `effect` directly (Lyra's way: a message becomes cue parameters, and the cue notify decides
## what plays). The cue runs on the anchor's unit view with the message as its payload (MessageCueParams). Set one of `effect` and `cue`.
@export var cue: StringName = &""
@export var anchor_rule: AnchorRule = AnchorRule.SCREEN
@export var params: Dictionary = {}
## A float parameter filled from a VerbMessage's magnitude (e.g. damage → intensity).
@export var magnitude_param: StringName
## Multiplies the magnitude first. Battle numbers are fixed-point ×100 (damage 15.00 is 1500): use 0.01 for those; run
## messages (a level) are plain numbers.
@export var magnitude_scale: float = 1.0
## Spec vfx-content-pass 3.2. Only messages whose tags include ALL of require_tags and NONE of exclude_tags play (a tag
## matches itself and its children: "Damage.Type" hears Damage.Type.Fire). Empty = no filter.
@export var require_tags: Array[StringName] = []
@export var exclude_tags: Array[StringName] = []
## Only a VerbMessage with this verb plays (Verb.Heal vs Verb.Damage on one channel). Empty = any.
@export var require_verb: StringName
## Parameters that depend on the message's tags: {tag: {param: value}}. Every tag the message carries adds its parameters
## on top of `params` (later entries win), so one effect serves every element: {"Damage.Type.Fire": {"color": orange}}.
@export var tag_params: Dictionary = {}
## Which tag wins when two set the same parameter: tags listed here apply last, in this order (later = stronger), after the
## ones not listed. A saved Dictionary does not keep its order, so anything that must override (a crit over a weakness) is listed.
@export var tag_order: Array[StringName] = []
## A STRING parameter filled with the message's magnitude as a whole number (magnitude / text_divisor), between the
## prefix and suffix: 2345 with divisor 100 and prefix "+" gives "+23". Battle numbers are x100.
@export var text_param: StringName
@export var text_divisor: float = 100.0
@export var text_prefix: String = ""
@export var text_suffix: String = ""


## Starts listening for `owner` (a Node: its Control or Node3D anchors OWNER, and the listener leaves with it).
func attach(owner: Node) -> GameplayMessageHandle:
	return GameplayMessages.listen(channel, _on_message.bind(owner),
		GameplayMessageRouter.Match.PARTIAL if partial else GameplayMessageRouter.Match.EXACT, null, owner)


func _on_message(_heard: StringName, message: GameplayMessage, owner: Node) -> void:
	if (effect == null and cue == &"") or not is_instance_valid(owner) or not accepts(message):
		return
	var service: FxService = FxCueNotify.service_override if FxCueNotify.service_override != null \
		else Engine.get_main_loop().root.get_node_or_null("FxManager") as FxService
	if service == null:
		return
	if cue != &"":
		_execute_cue(service, message)
		return
	var anchor := FxAnchor.screen()
	match anchor_rule:
		AnchorRule.OWNER:
			if owner is Control:
				anchor = FxAnchor.control(owner)
			elif owner is Node3D:
				anchor = FxAnchor.node3d(owner)
		AnchorRule.TARGET_UNIT:
			if message is VerbMessage:
				anchor = FxAnchor.unit(message.target)
		AnchorRule.INSTIGATOR_UNIT:
			if message is VerbMessage:
				anchor = FxAnchor.unit(message.instigator)
	var given := params.duplicate()
	if message is VerbMessage:
		for tag in _ordered_tags():
			if tag_matches(message.tags, tag):
				given.merge(tag_params[tag], true)
		if text_param != &"":
			given[text_param] = "%s%d%s" % [text_prefix, int(float(message.magnitude) / text_divisor), text_suffix]
	if magnitude_param != &"" and message is VerbMessage:
		given[magnitude_param] = float(message.magnitude) * magnitude_scale
	service.play(effect, anchor, given)


## Executes the cue on the unit view the anchor rule names (the target or the instigator), through GodotGAS's cue manager.
func _execute_cue(service: FxService, message: GameplayMessage) -> void:
	if not message is VerbMessage:
		return
	var unit_id: StringName = message.instigator if anchor_rule == AnchorRule.INSTIGATOR_UNIT else message.target
	var view := service.unit_view(unit_id)
	if view != null:
		GameplayCueManager.execute_cue(cue, view, MessageCueParams.from_message(message))


## Whether the message passes the tag and verb filters.
func accepts(message: GameplayMessage) -> bool:
	if require_tags.is_empty() and exclude_tags.is_empty() and require_verb == &"":
		return true
	if not message is VerbMessage:
		return false
	if require_verb != &"" and message.verb != require_verb:
		return false
	for tag in require_tags:
		if not tag_matches(message.tags, tag):
			return false
	for tag in exclude_tags:
		if tag_matches(message.tags, tag):
			return false
	return true


## True when `tags` has `wanted` or one of its children (Hit.Weakness is found by "Hit.Weakness" or "Hit").
static func tag_matches(tags: Array, wanted: StringName) -> bool:
	for tag in tags:
		if tag == wanted or String(tag).begins_with(String(wanted) + "."):
			return true
	return false


## The tag_params keys: the unlisted ones first, then tag_order (the last has the final say).
func _ordered_tags() -> Array[StringName]:
	var result: Array[StringName] = []
	for tag in tag_params:
		if not tag_order.has(StringName(tag)):
			result.append(StringName(tag))
	for tag in tag_order:
		if tag_params.has(tag) or tag_params.has(String(tag)):
			result.append(tag)
	return result
