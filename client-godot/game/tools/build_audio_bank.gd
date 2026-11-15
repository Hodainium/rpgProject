## Spec audio-pass 2.2 / 3.3 / 3.5: builds the sound bank's Godot side with ResourceSaver, NEW FILES ONLY (like build_fx_set):
##   presentation/audio/sfx/bank/<id>.tres   an AudioStreamRandomizer per manifest row (its imported takes, random pitch and volume)
##   presentation/demo/cues/sfx/<name>.tscn   a SfxCue scene per Cue.Sfx.* tag (section 3.5), playing its bank entry on bus Sfx
##   presentation/demo/fx/sfx_rules.tres     the message → sound-cue rules (an FxRuleSet; RegistryPatch adds it to the registry)
##   default_bus_layout.tres                 Master (hard limiter, ceiling −1 dB) → Sfx and Ui
## Run the import first (tools/audio_import.py) and `godot --import` so the WAVs are imported. `--force` rewrites this builder's
## own files (discards tuning in them). The cue registry entries are added by hand (godot_gas/ is edited through Edit only).
##   godot --headless --path client-godot --quit-after 2000 res://game/tools/build_audio_bank.tscn [-- --force]
extends Node

const CUE_DIR := "res://presentation/demo/cues/sfx/"
const RULES := "res://presentation/demo/fx/sfx_rules.tres"
const BUS_LAYOUT := "res://default_bus_layout.tres"

## Cue.Sfx tag -> [bank id, scene file, max voices]. Spec audio-pass 3.5.
const CUES: Dictionary = {
	&"Cue.Sfx.Hit.Physical": ["hit.physical", "hit_physical", 3],
	&"Cue.Sfx.Hit.Fire": ["hit.fire", "hit_fire", 3],
	&"Cue.Sfx.Hit.Ice": ["hit.ice", "hit_ice", 3],
	&"Cue.Sfx.Hit.Crit": ["hit.crit", "hit_crit", 2],
	&"Cue.Sfx.Hit.Weakness": ["hit.weakness", "hit_weakness", 2],
	&"Cue.Sfx.Hit.Resisted": ["hit.resisted", "hit_resisted", 2],
	&"Cue.Sfx.Hit.Drained": ["hit.drained", "hit_drained", 2],
	&"Cue.Sfx.Break": ["break", "break", 2],
	&"Cue.Sfx.Recovered": ["recovered", "recovered", 2],
	&"Cue.Sfx.Tick.Poison": ["tick.poison", "tick_poison", 2],
	&"Cue.Sfx.Tick.Bleed": ["tick.bleed", "tick_bleed", 2],
	&"Cue.Sfx.Tick.Burn": ["tick.burn", "tick_burn", 2],
	&"Cue.Sfx.Status.Control": ["status.control", "status_control", 2],
	&"Cue.Sfx.Apply.Buff": ["apply.buff", "apply_buff", 2],
	&"Cue.Sfx.Apply.Debuff": ["apply.debuff", "apply_debuff", 2],
	&"Cue.Sfx.Cleanse": ["cleanse", "cleanse", 2],
	&"Cue.Sfx.Heal": ["heal", "heal", 2],
	&"Cue.Sfx.Revive": ["revive", "revive", 2],
	&"Cue.Sfx.Death": ["death", "death", 2],
	&"Cue.Sfx.Downed": ["downed", "downed", 2],
	&"Cue.Sfx.PhaseShift": ["phase_shift", "phase_shift", 1],
	&"Cue.Sfx.OneMore": ["one_more", "one_more", 1],
	&"Cue.Sfx.Resisted": ["resisted", "resisted", 2],
	&"Cue.Sfx.Overtime": ["overtime", "overtime", 1],
}

## [channel, cue, require tags, exclude tags]: the message → sound rules (section 2.3 / 2.4). Anchored on the message's target.
const RULE_ROWS: Array = [
	[&"Message.Battle.Damage", &"Cue.Sfx.Hit.Physical", [&"Damage.Type.Physical"], [&"Hit.Drained"]],
	[&"Message.Battle.Damage", &"Cue.Sfx.Hit.Fire", [&"Damage.Type.Fire"], [&"Hit.Drained"]],
	[&"Message.Battle.Damage", &"Cue.Sfx.Hit.Ice", [&"Damage.Type.Ice"], [&"Hit.Drained"]],
	[&"Message.Battle.Damage", &"Cue.Sfx.Hit.Crit", [&"Hit.Critical"], []],
	[&"Message.Battle.Damage", &"Cue.Sfx.Hit.Weakness", [&"Hit.Weakness"], []],
	[&"Message.Battle.Damage", &"Cue.Sfx.Hit.Resisted", [&"Hit.Resisted"], []],
	[&"Message.Battle.Drained", &"Cue.Sfx.Hit.Drained", [], []],
	[&"Message.Battle.Broken", &"Cue.Sfx.Break", [], []],
	[&"Message.Battle.Recovered", &"Cue.Sfx.Recovered", [], []],
	[&"Message.Battle.Downed", &"Cue.Sfx.Downed", [], []],
	[&"Message.Battle.Phase", &"Cue.Sfx.PhaseShift", [], []],
	[&"Message.Battle.OneMore", &"Cue.Sfx.OneMore", [], []],
	[&"Message.Battle.UnitDied", &"Cue.Sfx.Death", [], []],
	[&"Message.Battle.Resisted", &"Cue.Sfx.Resisted", [], []],
]

var _force: bool = false
var _written := PackedStringArray()
var _kept := PackedStringArray()


func _ready() -> void:
	_force = OS.get_cmdline_user_args().has("--force")
	var bank := SfxBank.load_manifest()
	if bank.problem != "":
		push_error(bank.problem)
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SfxBank.BANK_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CUE_DIR))
	var failed := false
	for row in bank.entries():
		failed = not _save_entry(row) or failed
	for tag in CUES:
		failed = not _save_cue(tag, CUES[tag]) or failed
	_save_rules()
	_save_bus_layout()
	for line in RegistryPatch.add_missing_effects():
		print("registry: " + line)
	print("written (%d):\n  %s" % [_written.size(), "\n  ".join(_written)])
	if not _kept.is_empty():
		print("kept (%d, exist; --force rewrites): %s" % [_kept.size(), ", ".join(_kept)])
	get_tree().quit(1 if failed else 0)


func _writable(path: String) -> bool:
	if FileAccess.file_exists(path) and not _force:
		_kept.append(path.get_file())
		return false
	return true


func _save_entry(row: Dictionary) -> bool:
	var path := SfxBank.bank_path(str(row["id"]))
	if not _writable(path):
		return true
	var stream := AudioStreamRandomizer.new()
	var takes: Array = row.get("takes", [])
	for i in takes.size():
		var take := load(SfxBank.take_path(row, i)) as AudioStream
		if take == null:
			push_error("build_audio_bank: %s: its take %s is not imported (run tools/audio_import.py, then godot --import)" % [row["id"], SfxBank.take_path(row, i)])
			return false
		stream.add_stream(i, take, 1.0)
	var variation := SfxBank.default_variation(str(row.get("category", "")))
	stream.random_pitch = float(row.get("pitch_random", variation.x))
	stream.random_volume_offset_db = float(row.get("volume_random_db", variation.y))
	stream.playback_mode = AudioStreamRandomizer.PLAYBACK_RANDOM_NO_REPEATS if takes.size() > 1 else AudioStreamRandomizer.PLAYBACK_SEQUENTIAL
	stream.resource_name = str(row["id"])
	return _save(stream, path)


func _save_cue(tag: StringName, spec: Array) -> bool:
	var path := CUE_DIR + "cue_sfx_%s.tscn" % spec[1]
	if not _writable(path):
		return true
	var sound := load(SfxBank.bank_path(spec[0])) as AudioStream
	if sound == null:
		push_error("build_audio_bank: %s: no bank entry %s" % [tag, spec[0]])
		return false
	var root := SfxCue.new()
	root.name = "Sfx" + String(tag).trim_prefix("Cue.Sfx.").replace(".", "")
	root.sound = sound
	root.max_voices = spec[2]
	var scene := PackedScene.new()
	scene.pack(root)
	root.free()
	return _save(scene, path)


func _save_rules() -> void:
	if not _writable(RULES):
		return
	var rules := FxRuleSet.new()
	for row in RULE_ROWS:
		var listener := FxListener.new()
		listener.channel = row[0]
		listener.cue = row[1]
		listener.anchor_rule = FxListener.AnchorRule.TARGET_UNIT
		listener.require_tags.assign(row[2])
		listener.exclude_tags.assign(row[3])
		rules.rules.append(listener)
	_save(rules, RULES)


func _save_bus_layout() -> void:
	if not _writable(BUS_LAYOUT):
		return
	# Built on the running AudioServer (the layout Godot writes itself), then put back as it was.
	while AudioServer.bus_count > 1:
		AudioServer.remove_bus(AudioServer.bus_count - 1)
	for name in [&"Sfx", &"Ui"]:
		AudioServer.add_bus()
		var index := AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, name)
		AudioServer.set_bus_send(index, &"Master")
	while AudioServer.get_bus_effect_count(0) > 0:
		AudioServer.remove_bus_effect(0, 0)
	var limiter := AudioEffectHardLimiter.new()
	limiter.ceiling_db = -1.0
	AudioServer.add_bus_effect(0, limiter)
	# Headless runs mute Master (Watchdog, RPG_MUTE): never save that mute into the game's layout.
	var muted := AudioServer.is_bus_mute(0)
	AudioServer.set_bus_mute(0, false)
	var layout := AudioServer.generate_bus_layout()
	AudioServer.set_bus_mute(0, muted)
	_save(layout, BUS_LAYOUT)


func _save(resource: Resource, path: String) -> bool:
	var error := ResourceSaver.save(resource, path)
	if error != OK:
		push_error("build_audio_bank: could not save %s (%s)" % [path, error_string(error)])
		return false
	_written.append(path)
	return true
