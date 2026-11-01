## Settings (opened from the run menu on the same layer; Back returns to it): the battle panel's defaults, saved in
## user://game_main.cfg [settings]. Presentation only: nothing here changes a run or a battle.
extends UIScreen

@export var speeds: Array[float] = [1.0, 2.0]
@export var speed_format: String = "%d×"
## Spec main-menu M7: shown instead of the switch while a run is playing.
@export var run_note: String = "Switch modes from the main menu"


func bind(context: UIContext) -> void:
	for speed in speeds:
		%Speed.add_item(speed_format % int(speed))
	%Speed.select(maxi(speeds.find(float(GameMain.load_setting("settings", "battle_speed", speeds[0]))), 0))
	%Speed.item_selected.connect(func(index): GameMain.save_setting("settings", "battle_speed", speeds[index]))
	%Skip.button_pressed = GameMain.load_setting("settings", "skip_animations", false)
	%Skip.toggled.connect(func(on): GameMain.save_setting("settings", "skip_animations", on))
	# Spec auto-battle: whether a new run starts on Auto (A1), and whether Auto casts ults (A2, applies at once).
	%AutoBattle.button_pressed = GameMain.load_setting("settings", "auto_battle", false)
	%AutoBattle.toggled.connect(func(on): GameMain.save_setting("settings", "auto_battle", on))
	%AutoUlts.button_pressed = GameMain.load_setting("settings", "auto_ults", true)
	%AutoUlts.toggled.connect(func(on):
		GameMain.save_setting("settings", "auto_ults", on)
		context.main.auto_ults = on)
	# Spec main-menu M7: the server switch; editable only while no run is playing.
	%Url.text = str(GameMain.load_setting(ServerLink.SETTINGS_SECTION, "url", "")) if context.main.server == null \
		else context.main.server.url
	%Player.text = str(GameMain.load_setting(ServerLink.SETTINGS_SECTION, "player", "")) if context.main.server == null \
		else context.main.server.player
	%Connect.pressed.connect(func():
		%ServerNote.text = context.main.connect_server(%Url.text, %Player.text)
		refresh())
	%Disconnect.pressed.connect(func():
		context.main.disconnect_server()
		%ServerNote.text = ""
		refresh())
	context.main.server_changed.connect(_on_server_changed)


func _on_server_changed(_link: ServerLink) -> void:
	refresh()


func refresh() -> void:
	if ctx == null:
		return
	var in_run: bool = ctx.main.mode == "run"
	%ModeLine.text = ctx.main.mode_line()
	%Url.editable = not in_run
	%Player.editable = not in_run
	%Connect.disabled = in_run
	%Disconnect.disabled = in_run or ctx.main.server == null
	if in_run:
		%ServerNote.text = run_note
