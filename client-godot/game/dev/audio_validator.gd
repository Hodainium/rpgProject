## Spec audio-pass 4: the sound bank's checks (`sfx_*` codes), run by validate_content.tscn beside the fx_* and style_* ones, by the
## console's `audio check` and by test_audio_pass. Reads the manifest, the bank, the cue registry, the bus layout and the demo
## content; changes nothing. Dev only (not in the player export).
class_name AudioValidator
extends RefCounted

const ERROR := ValidationIssue.ERROR
const WARNING := ValidationIssue.WARNING
const CUE_DIR := "res://presentation/demo/cues/sfx/"
const BUS_LAYOUT := "res://default_bus_layout.tres"
const BOARD := "res://presentation/demo/sound_board.tscn"
## Folders whose scenes and resources may play sounds (each is checked for a .wav named directly, outside the bank).
const SCANNED: PackedStringArray = ["res://content/", "res://presentation/demo/"]


static func validate(bank: SfxBank = SfxBank.load_manifest(), abilities_dir: String = "res://content/demo/abilities/",
		credits_path: String = "res://../CREDITS.md") -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if bank.problem != "":
		issues.append(ValidationIssue.new(ERROR, "sfx_manifest", SfxBank.MANIFEST, bank.problem))
		return issues
	_cache = _texts()
	issues.append_array(_licences(bank))
	issues.append_array(_files(bank))
	issues.append_array(_loudness(bank))
	issues.append_array(_direct_streams())
	issues.append_array(_reserved(bank))
	issues.append_array(_missing(bank, abilities_dir))
	issues.append_array(_cues())
	issues.append_array(_buses())
	issues.append_array(_persistent())
	issues.append_array(_credits(bank, credits_path))
	return issues


static func _issue(severity: String, code: String, path: String, message: String) -> ValidationIssue:
	return ValidationIssue.new(severity, code, path, message)


static func _licences(bank: SfxBank) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	for name in bank.packs():
		var pack: Dictionary = bank.packs()[name]
		if not SfxBank.ALLOWED_LICENCES.has(str(pack.get("licence", ""))):
			issues.append(_issue(ERROR, "sfx_licence", SfxBank.MANIFEST, "pack %s: licence %s is not CC0 / CC BY 3.0 / CC BY 4.0" % [name, pack.get("licence", "")]))
		if str(pack.get("folder", "")).replace("\\", "/").split("/").has(SfxBank.FORBIDDEN_DIR):
			issues.append(_issue(ERROR, "sfx_licence", SfxBank.MANIFEST, "pack %s comes from %s" % [name, SfxBank.FORBIDDEN_DIR]))
	for row in bank.entries():
		if not bank.packs().has(str(row.get("pack", ""))):
			issues.append(_issue(ERROR, "sfx_licence", SfxBank.MANIFEST, "entry %s: unknown pack %s" % [row.get("id", "?"), row.get("pack", "")]))
	return issues


static func _files(bank: SfxBank) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	for row in bank.entries():
		var id := str(row.get("id", ""))
		for i in (row.get("takes", []) as Array).size():
			if not ResourceLoader.exists(SfxBank.take_path(row, i)):
				issues.append(_issue(ERROR, "sfx_file_missing", SfxBank.take_path(row, i), "entry %s: its take %d is not in the bank (run tools/audio_import.py)" % [id, i + 1]))
		var path := SfxBank.bank_path(id)
		if not ResourceLoader.exists(path):
			issues.append(_issue(ERROR, "sfx_file_missing", path, "entry %s has no bank file (run game/tools/build_audio_bank.tscn)" % id))
		elif not load(path) is AudioStreamRandomizer:
			issues.append(_issue(ERROR, "sfx_file_missing", path, "a bank entry must be an AudioStreamRandomizer"))
	return issues


static func _loudness(bank: SfxBank) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	var tolerance := float(bank.data.get("tolerance_db", 1.5))
	var ceiling := float(bank.data.get("peak_ceiling_db", -1.0))
	for row in bank.entries():
		var category := str(row.get("category", ""))
		var target := bank.target_of(category)
		var measured: Array = row.get("measured", [])
		if measured.size() != (row.get("takes", []) as Array).size():
			issues.append(_issue(WARNING, "sfx_loudness", SfxBank.MANIFEST, "entry %s: not measured (run tools/audio_import.py)" % row.get("id", "?")))
			continue
		for take in measured:
			if absf(float(take.get("loudness", -120.0)) - target) > tolerance:
				issues.append(_issue(WARNING, "sfx_loudness", SfxBank.MANIFEST, "entry %s: %.1f LUFS, its category %s wants %.1f" % [row.get("id", "?"), take.get("loudness", 0.0), category, target]))
			if float(take.get("peak_db", 0.0)) > ceiling + 0.3:
				issues.append(_issue(WARNING, "sfx_loudness", SfxBank.MANIFEST, "entry %s: peak %.1f dBTP over the ceiling" % [row.get("id", "?"), take.get("peak_db", 0.0)]))
			var max_ms := int(row.get("max_ms", bank.max_ms_of(category)))  # a row may set its own
			if int(take.get("ms", 0)) > max_ms + 5:
				issues.append(_issue(WARNING, "sfx_loudness", SfxBank.MANIFEST, "entry %s: %d ms, longer than its %d ms" % [row.get("id", "?"), take.get("ms", 0), max_ms]))
	return issues


## Every .tres and .tscn under the scanned folders, recursively, with its text.
static func _texts() -> Dictionary:
	var out := {}
	for root in SCANNED:
		_collect(root, out)
	return out


static func _collect(dir: String, out: Dictionary) -> void:
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".tres") or file.ends_with(".tscn"):
			out[dir.path_join(file)] = FileAccess.get_file_as_string(dir.path_join(file))
	for sub in DirAccess.get_directories_at(dir):
		_collect(dir.path_join(sub), out)


static func _direct_streams() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	var wav := RegEx.create_from_string('path="(res://[^"]+\\.wav)"')
	for path in _cache:
		for m in wav.search_all(str(_cache[path])):
			issues.append(_issue(ERROR, "sfx_direct_stream", path, "plays %s directly: point it at a bank entry (presentation/audio/sfx/bank/)" % m.get_string(1)))
	# The bank entries themselves may name WAVs, but only the bank's own (never the old presentation/audio/rtp/).
	for file in DirAccess.get_files_at(SfxBank.BANK_DIR):
		var text := FileAccess.get_file_as_string(SfxBank.BANK_DIR + file)
		for m in wav.search_all(text):
			if not m.get_string(1).begins_with(SfxBank.SFX_DIR):
				issues.append(_issue(ERROR, "sfx_direct_stream", SfxBank.BANK_DIR + file, "names %s, outside the bank's folders" % m.get_string(1)))
	return issues


## path -> text of every scanned scene and resource, read once per validate().
static var _cache: Dictionary = {}


## A reserved pack's entry is used only where the manifest allows it: ult.<id> only by the animation <id>.tres.
static func _reserved(bank: SfxBank) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	for row in bank.entries():
		if not bank.is_reserved(row):
			continue
		var id := str(row.get("id", ""))
		if not bank.reserved_allow().has(id):
			issues.append(_issue(ERROR, "sfx_reserved_source", SfxBank.MANIFEST, "entry %s uses the reserved pack %s and is not in reserved_allow" % [id, row.get("pack", "")]))
		var own := "res://content/demo/animations/%s.tres" % id.trim_prefix("ult.")
		for path in _cache:
			if path != own and str(_cache[path]).contains(SfxBank.bank_path(id)):
				issues.append(_issue(ERROR, "sfx_reserved_source", path, "uses %s, which is reserved for %s" % [id, own.get_file()]))
	return issues


## Every active move (not a passive, not listed silent) plays a bank entry on its animation.
static func _missing(bank: SfxBank, abilities_dir: String) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if not DirAccess.dir_exists_absolute(abilities_dir):
		return issues
	var silent := bank.silent()
	for file in DirAccess.get_files_at(abilities_dir):
		if not file.ends_with(".tscn"):
			continue
		var scene := load(abilities_dir.path_join(file)) as PackedScene
		var ability := scene.instantiate() as BattleAbility if scene != null else null
		if ability == null:
			continue
		var id := file.get_basename()
		var problem := ""
		if not UnitAnimator.plays_nothing(ability) and not silent.has(id):
			problem = _sound_problem(ability.animation)
		ability.free()
		if problem != "":
			issues.append(_issue(ERROR, "sfx_missing", abilities_dir.path_join(file), problem))
	return issues


static func _sound_problem(animation: Animation) -> String:
	if animation == null:
		return "no animation, so no sound"
	var has_track := false
	for i in animation.get_track_count():
		if animation.track_get_type(i) != Animation.TYPE_AUDIO:
			continue
		has_track = true
		for k in animation.track_get_key_count(i):
			var stream := animation.audio_track_get_key_stream(i, k)
			if stream != null and stream.resource_path.begins_with(SfxBank.BANK_DIR):
				return ""  # any audio track playing a bank entry is enough
	if has_track:
		return "its animation %s has no audio track playing a bank entry" % animation.resource_path.get_file()
	return "its animation %s plays no sound (silent move)" % animation.resource_path.get_file()


## Each sound cue scene has a registry entry and plays a bank entry.
static func _cues() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	var registry := load("res://godot_gas/cue_registry.tres") as GameplayCueRegistry
	var scenes := {}
	for entry in registry.entries:
		if String(entry.tag).begins_with("Cue.Sfx."):
			scenes[entry.scene_path()] = entry.tag
	if not DirAccess.dir_exists_absolute(CUE_DIR):
		return issues
	for file in DirAccess.get_files_at(CUE_DIR):
		if not file.ends_with(".tscn"):
			continue
		var path := CUE_DIR + file
		if not scenes.has(path):
			issues.append(_issue(ERROR, "sfx_cue_unregistered", path, "this sound cue has no entry in godot_gas/cue_registry.tres"))
		var node := (load(path) as PackedScene).instantiate()
		if not node is SfxCue or (node as SfxCue).sound == null or not (node as SfxCue).sound.resource_path.begins_with(SfxBank.BANK_DIR):
			issues.append(_issue(ERROR, "sfx_cue_sound", path, "a sound cue's root must be an SfxCue playing a bank entry"))
		node.free()
	return issues


## A sound cue is instant only: GodotGAS's add_persistent_cue turns auto_destroy off on the pooled node for good, so a Cue.Sfx.*
## tag in an effect's persistent_cue_tags would leave that node out of the pool afterwards.
static func _persistent() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	var line := RegEx.create_from_string('(?m)^persistent_cue_tags = .*&"Cue\\.Sfx\\.')
	for path in _cache:
		if line.search(str(_cache[path])) != null:
			issues.append(_issue(ERROR, "sfx_persistent", path, "a Cue.Sfx.* sound cue in persistent_cue_tags: list it in application_cue_tags"))
	return issues


## Every bus a player names exists in the layout.
static func _buses() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if not ResourceLoader.exists(BUS_LAYOUT):
		issues.append(_issue(ERROR, "sfx_bus_unknown", BUS_LAYOUT, "no bus layout"))
		return issues
	var names := {&"Master": true}
	for m in RegEx.create_from_string('bus/\\d+/name = &"([^"]+)"').search_all(FileAccess.get_file_as_string(BUS_LAYOUT)):
		names[StringName(m.get_string(1))] = true
	var named := RegEx.create_from_string('(?m)^bus = &"([^"]+)"')
	for path in _cache:
		for m in named.search_all(str(_cache[path])):
			if not names.has(StringName(m.get_string(1))):
				issues.append(_issue(ERROR, "sfx_bus_unknown", path, "plays on the bus %s, which the layout does not have" % m.get_string(1)))
	return issues


## CREDITS.md (in the repo, beside the project) names every pack the bank uses. Skipped where the file is not there (an export).
static func _credits(bank: SfxBank, credits_path: String) -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	var path := ProjectSettings.globalize_path(credits_path).simplify_path() if credits_path.begins_with("res://") else credits_path
	if not FileAccess.file_exists(path):
		return issues
	var text := FileAccess.get_file_as_string(path)
	var used := {}
	for row in bank.entries():
		used[str(row.get("pack", ""))] = true
	for name in used:
		var title := str(bank.packs().get(name, {}).get("title", name))
		if not text.contains(title):
			issues.append(_issue(ERROR, "sfx_credit_missing", "CREDITS.md", "the bank uses %s but CREDITS.md does not credit it (run tools/audio_import.py)" % title))
		for file in bank.packs().get(name, {}).get("file_authors", {}):
			var author := str(bank.packs()[name]["file_authors"][file].get("author", ""))
			if not text.contains(author):
				issues.append(_issue(ERROR, "sfx_credit_missing", "CREDITS.md", "%s's author %s is not credited" % [file, author]))
	return issues
