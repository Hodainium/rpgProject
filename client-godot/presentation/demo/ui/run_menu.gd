## Run menu (GameMenu layer; Esc on the map, from the policy's back_screens): Resume (Back), Settings (a UIPushButton
## onto this layer), Abandon run (asks first, on the Modal layer).
extends UIScreen

@export var abandon_question: String = "Abandon this run? Its save is deleted and it can't be continued."


func bind(_context: UIContext) -> void:
	%SaveQuit.pressed.connect(_save_and_quit)
	%Abandon.pressed.connect(_abandon)


## Spec main-menu M9: Abandon run is local mode only (there is no server abandon yet).
func refresh() -> void:
	%Abandon.visible = ctx.main.server == null


func _save_and_quit() -> void:
	ctx.ui.remove(self)
	ctx.main.save_and_quit()


func _abandon() -> void:
	if await ctx.ui.confirm(abandon_question, "Abandon", "Keep playing"):
		ctx.ui.remove(self)
		ctx.main.abandon_local_run()
