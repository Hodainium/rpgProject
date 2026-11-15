## Playtest-fixes B25: graphics settings (GraphicsSettings: anti-aliasing and fullscreen), the Graphics and Audio screens
## opened from Settings, and the console's `graphics`. Nothing here
## saves: the tests never write the player's user://game_main.cfg.
extends TestCase


func test_each_mode_applies_to_a_viewport_and_reads_back() -> void:
	var viewport := SubViewport.new()
	host.add_child(viewport)
	for mode in GraphicsSettings.AA_MODES:
		eq(GraphicsSettings.apply_aa(viewport, mode), "", "%s applies" % mode)
		eq(GraphicsSettings.current_aa(viewport), mode, "and reads back as %s" % mode)
	GraphicsSettings.apply_aa(viewport, "msaa_4x")
	eq(viewport.msaa_3d, Viewport.MSAA_4X, "MSAA 4× sets the 3D MSAA")
	eq(viewport.screen_space_aa, Viewport.SCREEN_SPACE_AA_DISABLED, "and no screen filter")
	GraphicsSettings.apply_aa(viewport, "fxaa")
	eq(viewport.msaa_3d, Viewport.MSAA_DISABLED, "FXAA turns MSAA off")
	eq(viewport.screen_space_aa, Viewport.SCREEN_SPACE_AA_FXAA, "and the filter on")
	viewport.free()


func test_an_unknown_mode_is_refused_and_changes_nothing() -> void:
	var viewport := SubViewport.new()
	host.add_child(viewport)
	GraphicsSettings.apply_aa(viewport, "msaa_2x")
	check(GraphicsSettings.apply_aa(viewport, "taa").contains("unknown anti-aliasing mode"), "an unknown mode is a problem")
	check(GraphicsSettings.set_aa(viewport, "ssaa").contains("unknown anti-aliasing mode"), "set_aa refuses it before saving")
	eq(GraphicsSettings.current_aa(viewport), "msaa_2x", "the viewport keeps its mode")
	viewport.free()


func test_the_lists_line_up_and_the_default_is_msaa_4x() -> void:
	eq(GraphicsSettings.AA_LABELS.size(), GraphicsSettings.AA_MODES.size(), "one label per mode")
	eq(GraphicsSettings.AA_DEFAULT, "msaa_4x", "the default smooths the 3D edges")
	check(GraphicsSettings.AA_MODES.has(GraphicsSettings.saved_aa()), "the saved mode is always a known one")


func _game() -> GameMain:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	return game


func test_the_graphics_screen_has_the_rows() -> void:
	var game := _game()
	await host.get_tree().process_frame
	var screen: UIScreen = game.ui.push(&"UI.Layer.Menu", load("res://presentation/demo/ui/graphics_settings.tscn"))
	await host.get_tree().process_frame
	var row: OptionButton = screen.get_node("%AntiAliasing")
	eq(row.item_count, GraphicsSettings.AA_MODES.size(), "the anti-aliasing row lists every mode")
	eq(row.get_item_text(GraphicsSettings.AA_MODES.find("msaa_4x")), "MSAA 4×", "with its label")
	eq(row.selected, GraphicsSettings.AA_MODES.find(GraphicsSettings.saved_aa()), "the saved mode is selected")
	check(row.item_selected.get_connections().size() > 0, "a pick is wired (applies and saves)")
	var fullscreen: CheckBox = screen.get_node("%Fullscreen")
	eq(fullscreen.button_pressed, GraphicsSettings.saved_fullscreen(), "fullscreen shows the saved choice (headless: no window)")
	check(fullscreen.toggled.get_connections().size() > 0, "the toggle is wired (applies and saves)")
	check(screen.get_node_or_null("%FxQuality") != null, "the visual effects quality moved here")
	game.free()


func test_settings_opens_graphics_and_audio_on_its_own_layer() -> void:
	var game := _game()
	game.content_root = "res://tests/fixtures/"
	game.load_content()
	await host.get_tree().process_frame
	for layer in [&"UI.Layer.Menu", &"UI.Layer.GameMenu"]:  # the main menu and the run menu open Settings on these
		if layer == &"UI.Layer.GameMenu":  # the run menu exists during a run (the main menu then leaves the Menu layer)
			game.start_run(["fixture.character.knight", "fixture.character.medic"], "7", &"fixture.run.two_floors")
			for frame in 2:
				await host.get_tree().process_frame
		var settings: UIScreen = game.ui.push(layer, load("res://presentation/demo/ui/settings.tscn"))
		await host.get_tree().process_frame
		check(settings.get_node_or_null("%FxQuality") == null and settings.get_node_or_null("%AntiAliasing") == null,
			"Settings no longer holds the graphics rows")
		for pair in [["%Graphics", "graphics_settings.tscn"], ["%Audio", "audio_settings.tscn"]]:
			var button: UIPushButton = settings.get_node(pair[0])
			eq(button.target_layer(), layer, "%s opens on Settings' own layer (%s)" % [pair[0], layer])
			button.pressed.emit()
			await host.get_tree().process_frame
			var top := game.ui.top(layer)
			check(top != null and top.source_scene.resource_path.ends_with(pair[1]), "%s opens %s" % [pair[0], pair[1]])
			game.ui.back()
			await host.get_tree().process_frame
			eq(game.ui.top(layer), settings, "Back returns to Settings")
		game.ui.back()
		await host.get_tree().process_frame
	game.free()


func test_a_push_button_outside_a_stack_uses_its_layer() -> void:
	var button := UIPushButton.new()
	button.same_layer = true
	button.layer = &"UI.Layer.Modal"
	eq(button.target_layer(), &"UI.Layer.Modal", "no stack above it: the button's own layer")
	button.free()


func test_the_console_command_shows_and_refuses() -> void:
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	var shown: Dictionary = await console.execute("graphics")
	check(str(shown["text"]).begins_with("anti-aliasing: ") and str(shown["text"]).contains("fullscreen: "),
		"graphics shows both settings: %s" % shown["text"])
	var refused: Dictionary = await console.execute("graphics aa sharp")
	check(str(refused["text"]).contains("unknown anti-aliasing mode"), "an unknown mode is refused: %s" % refused["text"])
	var bad: Dictionary = await console.execute("graphics fullscreen maybe")
	check(not bad["ok"], "fullscreen takes on or off")


func test_a_same_layer_button_on_a_stack_that_never_pops_keeps_its_layer() -> void:
	var stack := UILayerStack.new()
	stack.layer = &"UI.Layer.Game"
	stack.back_pops = false
	var screen := UIScreen.new()
	var button := UIPushButton.new()
	button.same_layer = true
	button.layer = &"UI.Layer.Menu"
	screen.add_child(button)
	stack.add_child(screen)
	eq(button.target_layer(), &"UI.Layer.Menu", "a HUD panel's button opens on its own layer (Back can close that)")
	stack.back_pops = true
	eq(button.target_layer(), &"UI.Layer.Game", "on a stack that pops it follows the stack")
	stack.free()


func test_a_new_sample_count_makes_the_stencil_prepare_draw_again() -> void:
	var viewport := SubViewport.new()
	host.add_child(viewport)
	GraphicsSettings.apply_aa(viewport, "msaa_4x")
	var probe := Shader.new()
	FxStencilShaders._prepared[probe] = true
	GraphicsSettings.apply_aa(viewport, "msaa_4x")
	check(FxStencilShaders._prepared.has(probe), "the same sample count keeps what was prepared")
	GraphicsSettings.apply_aa(viewport, "fxaa")
	check(not FxStencilShaders._prepared.has(probe), "a new sample count forgets it (pipelines are per sample count)")
	viewport.free()


func test_the_stage_follows_the_saved_anti_aliasing() -> void:
	eq(GraphicsSettings.msaa_of("msaa_8x"), Viewport.MSAA_8X, "8×")
	eq(GraphicsSettings.msaa_of("fxaa"), Viewport.MSAA_DISABLED, "FXAA has no MSAA")
	eq(GraphicsSettings.msaa_of("nonsense"), Viewport.MSAA_DISABLED, "an unknown mode has none")
	var stage := FxStage.new()
	host.add_child(stage)
	eq(stage.viewport.msaa_3d, GraphicsSettings.msaa_of(GraphicsSettings.saved_aa()), "a card stage takes the player's MSAA")
	stage.free()
