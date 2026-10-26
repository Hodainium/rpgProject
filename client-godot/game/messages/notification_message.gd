## Spec gameplay-messages 3.1: a line for the player (Lyra's FLyraNotificationMessage), on Message.Notification.
class_name NotificationMessage
extends GameplayMessage

var text: String = ""
## Notification.Warning, Notification.Error…
var tags: Array[StringName] = []
## How long a toast may show it; 0 = until the next one replaces it.
var seconds: float = 0.0


static func make(line: String, context_tags: Array = [], show_seconds: float = 0.0) -> NotificationMessage:
	var message := NotificationMessage.new()
	message.text = line
	message.tags.assign(context_tags)
	message.seconds = show_seconds
	return message


func describe() -> String:
	if tags.is_empty():
		return "\"%s\"" % text
	return "\"%s\" [%s]" % [text, ", ".join(tags.map(func(tag) -> String: return String(tag)))]
