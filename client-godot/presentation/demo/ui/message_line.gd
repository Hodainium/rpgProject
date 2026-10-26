## Footer panel (UI.Slot.Footer, always): the last line for the player (run events, level-ups, drops, refusals), from
## the Message.Notification channel (spec gameplay-messages). Battle call-outs are the battle_callouts panel's.
extends UIScreen


func bind(_context: UIContext) -> void:
	GameplayMessages.listen(GameplayMessageRouter.NOTIFICATION, func(_channel, message: NotificationMessage):
		%Text.text = message.text, GameplayMessageRouter.Match.EXACT, NotificationMessage, self)
