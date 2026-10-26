## HUD overlay (UI.Slot.Hud.Overlay while UI.State.Run.Battle): the battle's call-outs (BROKEN!, ONE MORE!, phases,
## resisted statuses, knocked down, skipped turns, ults unleashed), from the Message.Battle channel (spec
## gameplay-messages). Each line shows for `seconds` (real time, so the battle speed never shortens it); at most
## `max_lines` at once, the oldest first out. The texts are the formats below; a channel without one shows nothing.
extends UIScreen

@export var seconds: float = 2.0
@export var max_lines: int = 3
@export var broken_format: String = "%s is BROKEN!"
@export var one_more_format: String = "ONE MORE! %s acts again"
@export var skipped_format: String = "%s can't act and loses the turn"
@export var resisted_format: String = "%s resisted %s"
@export var phase_format: String = "%s enters phase %d!"
@export var downed_format: String = "%s is KNOCKED DOWN!"
@export var interrupt_format: String = "%s unleashes %s!"


func bind(_context: UIContext) -> void:
	GameplayMessages.listen(&"Message.Battle", _on_message, GameplayMessageRouter.Match.PARTIAL, VerbMessage, self)


func _on_message(channel: StringName, message: VerbMessage) -> void:
	var instigator: String = message.data.get("instigatorName", String(message.instigator))
	var target: String = message.data.get("targetName", String(message.target))
	match channel:
		GameplayMessageRouter.BATTLE_BROKEN:
			_show(broken_format % target)
		GameplayMessageRouter.BATTLE_ONE_MORE:
			_show(one_more_format % instigator)
		GameplayMessageRouter.BATTLE_TURN_SKIPPED:
			_show(skipped_format % target)
		GameplayMessageRouter.BATTLE_RESISTED:
			_show(resisted_format % [target, message.data.get("status", "")])
		GameplayMessageRouter.BATTLE_PHASE:
			_show(phase_format % [target, message.magnitude])
		GameplayMessageRouter.BATTLE_DOWNED:
			_show(downed_format % target)
		GameplayMessageRouter.BATTLE_INTERRUPT:
			_show(interrupt_format % [instigator, message.data.get("abilityName", "")])


func _show(text: String) -> void:
	var line := Label.new()
	line.text = text
	line.theme_type_variation = &"HeaderLarge"
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	%Lines.add_child(line)
	while %Lines.get_child_count() > max_lines:
		var oldest := %Lines.get_child(0)
		%Lines.remove_child(oldest)
		oldest.queue_free()
	await get_tree().create_timer(seconds, true, false, true).timeout
	if is_instance_valid(line):
		line.queue_free()
