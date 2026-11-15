## Graphics (playtest-fixes B25; opened from Settings on the same layer, Back returns to it): the visual effects quality,
## anti-aliasing and fullscreen, each applied at once and saved in user://game_main.cfg [settings]. Presentation only.
extends UIScreen


func bind(_context: UIContext) -> void:
	# Spec vfx-framework F4: the effects quality tier (off, low, medium, high), applied at once and kept for next time.
	for tier in FxQuality.NAMES:
		%FxQuality.add_item(tier.capitalize())
	%FxQuality.select(FxManager.quality)
	%FxQuality.item_selected.connect(func(index):
		FxManager.quality = index
		GameMain.save_setting(FxService.SETTINGS_SECTION, FxService.SETTINGS_KEY, FxQuality.NAMES[index]))
	# Playtest-fixes B25: anti-aliasing (MSAA smooths the 3D edges) and fullscreen.
	for label in GraphicsSettings.AA_LABELS:
		%AntiAliasing.add_item(label)
	%AntiAliasing.select(GraphicsSettings.AA_MODES.find(GraphicsSettings.saved_aa()))
	%AntiAliasing.item_selected.connect(func(index):
		GraphicsSettings.set_aa(get_viewport(), GraphicsSettings.AA_MODES[index]))
	%Fullscreen.toggled.connect(func(on): GraphicsSettings.set_fullscreen(on))


func refresh() -> void:
	# Things may have changed outside this screen (the OS, the console's `graphics`): show what they are now, without saving. The
	# window's real state; headless there is no window, so the saved choice.
	var windowless := DisplayServer.get_name() == "headless"
	%Fullscreen.set_pressed_no_signal(GraphicsSettings.saved_fullscreen() if windowless else GraphicsSettings.is_fullscreen())
	%AntiAliasing.select(GraphicsSettings.AA_MODES.find(GraphicsSettings.saved_aa()))
