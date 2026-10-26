## Settings (opened from the run menu on the same layer; Back returns to it): the battle panel's defaults, saved in
## user://game_main.cfg [settings]. Presentation only: nothing here changes a run or a battle.
extends UIScreen

@export var speeds: Array[float] = [1.0, 2.0]
@export var speed_format: String = "%d×"


func bind(_context: UIContext) -> void:
	for speed in speeds:
		%Speed.add_item(speed_format % int(speed))
	%Speed.select(maxi(speeds.find(float(GameMain.load_setting("settings", "battle_speed", speeds[0]))), 0))
	%Speed.item_selected.connect(func(index): GameMain.save_setting("settings", "battle_speed", speeds[index]))
	%Skip.button_pressed = GameMain.load_setting("settings", "skip_animations", false)
	%Skip.toggled.connect(func(on): GameMain.save_setting("settings", "skip_animations", on))
