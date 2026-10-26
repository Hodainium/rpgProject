## Footer panel (UI.Slot.Footer, always): the last message for the player (run events, battle calls, refusals).
extends UIScreen


func bind(context: UIContext) -> void:
	context.main.message_shown.connect(func(text): %Text.text = text)
	%Text.text = context.main.last_message
