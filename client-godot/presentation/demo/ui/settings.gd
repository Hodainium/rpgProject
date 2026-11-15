## Settings (opened from the main menu and the run menu; Back returns to it): the Graphics and Audio sub-menus and the server
## switch, saved in user://game_main.cfg. Presentation only: nothing here changes a run or a battle. Playtest-fixes B25: no
## battle rows (speed, pacing, skip, Auto): the battle HUD's own buttons are the player's controls for those.
extends UIScreen

## Spec main-menu M7: shown instead of the switch while a run is playing.
@export var run_note: String = "Switch modes from the main menu"


func bind(context: UIContext) -> void:
	# Playtest-fixes B25: the visual effects quality, anti-aliasing and fullscreen live on the Graphics screen (graphics_settings),
	# opened by the Graphics button; the Audio button opens audio_settings (5e audio-pass fills it).
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
