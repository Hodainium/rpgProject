## Footer panel (UI.Slot.Footer, always): the last line for the player (run events, level-ups, drops, refusals), from
## the Message.Notification channel (spec gameplay-messages). Battle call-outs are the battle_callouts panel's; the
## battle's end ("Battle: Victory") comes from Message.Battle.Ended.
extends UIScreen

@export var battle_end_format: String = "Battle: %s"


func bind(_context: UIContext) -> void:
	GameplayMessages.listen(GameplayMessageRouter.NOTIFICATION, func(_channel, message: NotificationMessage):
		%Text.text = message.text, GameplayMessageRouter.Match.EXACT, NotificationMessage, self)
	GameplayMessages.listen(GameplayMessageRouter.BATTLE_ENDED, _on_battle_ended, GameplayMessageRouter.Match.EXACT,
		VerbMessage, self)


func _on_battle_ended(_channel: StringName, message: VerbMessage) -> void:
	%Text.text = battle_end_format % message.data.get("outcome", "")
