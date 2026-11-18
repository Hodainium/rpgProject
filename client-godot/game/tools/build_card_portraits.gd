## Spec card-ui 3.5: shoots every character card's portrait. A window tool (it needs the renderer, not --headless): each
## character's real view (its main StyleRegistry look, attachments and look effect, facing the camera) stands alone in the
## portrait studio (presentation/demo/cards/portrait_studio.tscn), lit in its rim colour, and is saved as
## presentation/demo/cards/portraits/<character id>.png; then card_portraits.tres (a CardArtSet) lists them. New files only: an
## existing PNG or set is kept unless --force. Re-run after a look changes (the validator's card_portrait_stale says when).
##   godot --path client-godot --screen 2 res://game/tools/build_card_portraits.tscn [-- --only <id,id>] [--force]
##     [--content-root res://content/] [--settle <seconds, default 1.5>] [--size <px, default 768>]
## Then `godot --headless --path client-godot --import` so the PNGs become textures.
extends Node

const STUDIO: String = "res://presentation/demo/cards/portrait_studio.tscn"
const UNIT_VIEW: String = "res://presentation/demo/unit_view.tscn"
const OUT_DIR: String = "res://presentation/demo/cards/portraits"


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("build_card_portraits: needs a window (the renderer); run it without --headless")
		get_tree().quit(3)
		return
	var args := OS.get_cmdline_user_args()
	var content := ContentIndex.new(_arg(args, "--content-root", "res://content/"))
	var only := _arg(args, "--only", "").split(",", false)
	var force := args.has("--force")
	var settle := float(_arg(args, "--settle", "1.5"))
	var size := int(_arg(args, "--size", "768"))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(size, size)
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var preview := TextureRect.new()  # what is being shot, in the tool's window
	preview.texture = viewport.get_texture()
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(preview)
	var studio: PortraitStudio = load(STUDIO).instantiate()
	viewport.add_child(studio)
	var registry := UnitStyle.registry()
	var facing := registry.facing_degrees if registry != null else -1.0
	if registry != null:
		registry.facing_degrees = 0.0  # in memory only: a cube turned away from the camera breaks its face (user, 2026-11-15)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var ids: Array = content.characters.keys().map(func(id: StringName) -> String: return String(id))
	ids.sort()
	var shot := 0
	for id in ids:
		if not only.is_empty() and not only.has(id):
			continue
		var path := OUT_DIR.path_join(id + ".png")
		if FileAccess.file_exists(path) and not force:
			print("kept ", path)
			continue
		var definition: CharacterDefinition = content.characters[StringName(id)]
		studio.light_for(StringName(id))
		var view := UnitAnimator.instantiate_for(definition, load(UNIT_VIEW))
		studio.stand().add_child(view)
		if view.has_method("setup"):
			view.setup("", definition.display_color)
		if view.has_method("set_stats"):
			view.set_stats("")
		Watchdog.beat("portrait " + id)
		await get_tree().create_timer(settle).timeout
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		var error := image.save_png(ProjectSettings.globalize_path(path))
		print("shot %s%s" % [path, "" if error == OK else " (error %d)" % error])
		shot += 1
		view.queue_free()
		await get_tree().process_frame
	if registry != null:
		registry.facing_degrees = facing
	_write_set(ids, force)
	print("build_card_portraits: %d shot; run godot --import so they become textures" % shot)
	get_tree().quit(0)


## card_portraits.tres listing every portrait PNG there is (new file only unless forced).
func _write_set(ids: Array, force: bool) -> void:
	var out := CardArtSet.PORTRAITS_PATH
	if FileAccess.file_exists(out) and not force:
		print("kept ", out)
		return
	var present: Array[String] = []
	for id in ids:
		if FileAccess.file_exists(OUT_DIR.path_join(id + ".png")):
			present.append(id)
	var lines := PackedStringArray(['[gd_resource type="Resource" script_class="CardArtSet" load_steps=%d format=3]' % (present.size() + 2), "",
		'[ext_resource type="Script" path="res://game/cards/card_art_set.gd" id="1_set"]'])
	for index in present.size():
		lines.append('[ext_resource type="Texture2D" path="%s" id="%d_portrait"]' % [OUT_DIR.path_join(present[index] + ".png"), index + 2])
	lines.append("")
	lines.append("[resource]")
	lines.append('script = ExtResource("1_set")')
	var entries := PackedStringArray()
	for index in present.size():
		entries.append('&"%s": ExtResource("%d_portrait")' % [present[index], index + 2])
	lines.append("textures = Dictionary[StringName, Texture2D]({\n%s\n})" % ",\n".join(entries))
	var file := FileAccess.open(out, FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()
	print("wrote ", out)


func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback
