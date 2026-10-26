## Test probe for spec gameplay-messages 6: a panel that shows the last Message.Notification, the way the demo's
## message line does (listening, never called by GameMain).
extends UIScreen

var text: String = ""


func bind(_context: UIContext) -> void:
	GameplayMessages.listen(GameplayMessageRouter.NOTIFICATION, func(_channel, message): text = message.text,
		GameplayMessageRouter.Match.EXACT, NotificationMessage, self)
