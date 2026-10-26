## Run menu (GameMenu layer; Esc on the map, from the policy's back_screens): Resume (Back), Settings (a UIPushButton
## onto this layer), Abandon run (asks first, on the Modal layer).
extends UIScreen

@export var abandon_question: String = "Abandon this run? It can't be resumed."


func bind(_context: UIContext) -> void:
	%Abandon.pressed.connect(_abandon)


func _abandon() -> void:
	if await ctx.ui.confirm(abandon_question, "Abandon", "Keep playing"):
		ctx.ui.remove(self)
		ctx.main.back_to_menu()
