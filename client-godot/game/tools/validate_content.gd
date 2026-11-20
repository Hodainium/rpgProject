## Headless content validator (spec dev-tools 2.7). Prints every issue and exits 0 (no errors), 3 (content errors) or
## 1 (tool error):
##   godot --headless --path client-godot --quit-after 3000 res://game/tools/validate_content.tscn
##     [-- --content-root res://content/] [--seeds 20]
extends Node


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var root := _arg(args, "--content-root", "res://content/")
	if not DirAccess.dir_exists_absolute(root):
		print("validate_content: no content root ", root)
		get_tree().quit(1)
		return
	var content := ContentIndex.new(root)
	var issues := ContentValidator.validate(content, {"generate_seeds": int(_arg(args, "--seeds", "20"))})
	# Spec ui-framework 3.5: the game's UI policy too (it's presentation, so only with the game's own content root).
	if root == "res://content/" and ResourceLoader.exists(GameMain.UI_POLICY):
		issues.append_array(UIPolicyCheck.validate(load(GameMain.UI_POLICY), content))
	# Spec class-pick 3.2: the recommended parties (presentation, like the UI policy).
	if root == "res://content/":
		issues.append_array(ClassPickCheck.validate_screen(content))
	# Spec vfx-framework 6: the effects registry too (presentation, like the UI policy).
	FxManager.reload()  # the registry loads on first use
	if root == "res://content/" and FxManager.registry != null:
		issues.append_array(FxValidator.validate(FxManager.registry))
		# Registries are edited by hand (builders never rewrite them): this catches a forgotten line.
		issues.append_array(FxValidator.sync_problems("res://presentation/demo/fx/", "res://presentation/demo/cues/",
			FxManager.registry, load("res://godot_gas/cue_registry.tres") as GameplayCueRegistry))
		# Spec vfx-stencil: stencil words and values in the shaders and materials (the game's and the designer's).
		issues.append_array(FxValidator.stencil_problems(["res://game/fx/shaders/", "res://presentation/", "res://content/"]))
	# Spec cube-style 3.8: the style registry (presentation, like the UI policy; loaded explicitly, UnitStyle loads nothing headless).
	if root == "res://content/" and ResourceLoader.exists(UnitStyle.DEFAULT_REGISTRY):
		issues.append_array(StyleValidator.validate(load(UnitStyle.DEFAULT_REGISTRY) as StyleRegistry, content, UnitStyle.DEFAULT_REGISTRY))
		# Playtest-fixes B23: an attachment face where a skin status's shell lies flickers.
		var grows := FxValidator.skin_grows(FxManager.registry, load("res://godot_gas/cue_registry.tres") as GameplayCueRegistry)
		issues.append_array(StyleValidator.skin_tie_problems(load(UnitStyle.DEFAULT_REGISTRY) as StyleRegistry, grows,
			UnitStyle.DEFAULT_REGISTRY))
		for variant in StyleValidator.registries_under(UnitStyle.DEFAULT_REGISTRY.get_base_dir().path_join("variants")):
			issues.append_array(StyleValidator.validate(load(variant) as StyleRegistry, content, variant))
			issues.append_array(StyleValidator.skin_tie_problems(load(variant) as StyleRegistry, grows, variant))
	# Spec audio-pass 4: the sound bank (presentation, like the effects registry).
	if root == "res://content/":
		issues.append_array(AudioValidator.validate())
	# Spec card-ui 6: the card style (faces, rarity looks, every card's art).
	if root == "res://content/" and ResourceLoader.exists(CardStyle.DEFAULT_PATH):
		var registry: StyleRegistry = load(UnitStyle.DEFAULT_REGISTRY) if ResourceLoader.exists(UnitStyle.DEFAULT_REGISTRY) else null
		issues.append_array(CardStyleValidator.validate(load(CardStyle.DEFAULT_PATH) as CardStyle, content, registry))
	print("validate_content: ", root)
	print(ContentValidator.report(issues))
	get_tree().quit(3 if ContentValidator.error_count(issues) > 0 else 0)


static func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
