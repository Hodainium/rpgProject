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
@export var anchor_rule: AnchorRule = AnchorRule.SCREEN
@export var params: Dictionary = {}
## A float parameter filled from a VerbMessage's magnitude (e.g. damage → intensity).
@export var magnitude_param: StringName
## Multiplies the magnitude first. Battle numbers are fixed-point ×100 (damage 15.00 is 1500): use 0.01 for those; run
## messages (a level) are plain numbers.
@export var magnitude_scale: float = 1.0


## Starts listening for `owner` (a Node: its Control or Node3D anchors OWNER, and the listener leaves with it).
func attach(owner: Node) -> GameplayMessageHandle:
	return GameplayMessages.listen(channel, _on_message.bind(owner),
		GameplayMessageRouter.Match.PARTIAL if partial else GameplayMessageRouter.Match.EXACT, null, owner)


func _on_message(_heard: StringName, message: GameplayMessage, owner: Node) -> void:
	if effect == null or not is_instance_valid(owner):
		return
	var service: FxService = FxCueNotify.service_override if FxCueNotify.service_override != null \
		else Engine.get_main_loop().root.get_node_or_null("FxManager") as FxService
	if service == null:
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
	if magnitude_param != &"" and message is VerbMessage:
		given[magnitude_param] = float(message.magnitude) * magnitude_scale
	service.play(effect, anchor, given)
