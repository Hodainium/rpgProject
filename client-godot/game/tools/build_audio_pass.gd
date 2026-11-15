## Spec audio-pass 3.4 / 3.5: the audio pass over the demo content (approved by the user, 2026-11-15: "builder pass, then review").
## It is the one builder that edits existing design files, and only as narrow TEXT patches (never ResourceSaver, so nothing is
## reformatted or reordered):
##   content/demo/animations/*.tres   the audio track's stream → a bank entry (presentation/audio/sfx/bank/<id>.tres): the user's own
##                                    pick mapped into the bank, or, for a silent active move, the entry its class gets (3.4); a move
##                                    with no audio track gets one at 0 s; the `Audio:volume_db` key → 0 dB (the bank carries the level)
##   content/demo/effects/*.tres      `Cue.Sfx.*` sound cues beside the visual cues (3.5); `Cue.Sfx.Hit` off damage.tres
## Every patched animation is reloaded and compared with the original: its length and every non-audio track (the `execute` keys
## combat reads) must be identical, or the file is left alone and reported. Writes ../build/audio_pass_report.md.
##   godot --headless --path client-godot --quit-after 5000 res://game/tools/build_audio_pass.tscn [-- --dry-run]
class_name BuildAudioPass
extends Node

const ABILITIES := "res://content/demo/abilities/"
const ANIMATIONS := "res://content/demo/animations/"
const EFFECTS := "res://content/demo/effects/"
const ENEMIES := "res://content/demo/enemies/"
const LOADOUTS := "res://content/demo/loadouts/"
const OLD_DIR := "res://presentation/audio/rtp/"
const NEW_EXT_ID := "sfx_bank"

## Visual cue on an effect's list → the sound cue added to the same list (3.5).
const APPLICATION_MAP: Dictionary = {
	&"Cue.Fx.Apply.Buff": &"Cue.Sfx.Apply.Buff", &"Cue.Fx.Apply.Debuff": &"Cue.Sfx.Apply.Debuff", &"Cue.Fx.Heal": &"Cue.Sfx.Heal",
	&"Cue.Fx.Revive": &"Cue.Sfx.Revive", &"Cue.Fx.Cleanse": &"Cue.Sfx.Cleanse",
}
const PERIODIC_MAP: Dictionary = {
	&"Cue.Fx.Tick.Poison": &"Cue.Sfx.Tick.Poison", &"Cue.Fx.Tick.Bleed": &"Cue.Sfx.Tick.Bleed",
	&"Cue.Fx.Tick.Burn": &"Cue.Sfx.Tick.Burn", &"Cue.Fx.Heal": &"Cue.Sfx.Heal",
}
## A status's looping visual → the sound its application plays (a control, a DoT landing, the overtime clock).
const PERSISTENT_TO_APPLICATION: Dictionary = {
	&"Cue.Fx.Status.Freeze": &"Cue.Sfx.Status.Control", &"Cue.Fx.Status.Stun": &"Cue.Sfx.Status.Control",
	&"Cue.Fx.Status.Entangle": &"Cue.Sfx.Status.Control", &"Cue.Fx.Status.Slow": &"Cue.Sfx.Status.Control",
	&"Cue.Fx.Status.Poison": &"Cue.Sfx.Apply.Debuff", &"Cue.Fx.Status.Bleed": &"Cue.Sfx.Apply.Debuff",
	&"Cue.Fx.Status.Burn": &"Cue.Sfx.Apply.Debuff", &"Cue.Fx.Buff.Enrage": &"Cue.Sfx.Overtime",
}
## A more specific sound replaces the generic one on the same effect.
const SUPERSEDES: Dictionary = {&"Cue.Sfx.Overtime": &"Cue.Sfx.Apply.Buff", &"Cue.Sfx.Status.Control": &"Cue.Sfx.Apply.Debuff"}
const REMOVED_CUES: Array[StringName] = [&"Cue.Sfx.Hit"]

## Keyword groups for a move with no role tags (enemies), checked in order on its id and its effects' file names (3.4).
const KEYWORDS: Array = [
	["rtp.raise2", ["revive", "resurrect"]],
	["rtp.recovery5", ["heal", "mend", "regen", "bless", "brew", "hymn", "salve"]],
	["rtp.flash3", ["dispel", "purge"]],
	["rtp.chime2", ["purify", "cleanse", "holy_water"]],
	["rtp.poison", ["poison", "bile", "infect", "malady", "plague", "toxic", "contagion", "outbreak", "spit"]],
	["rtp.darkness3", ["curse", "hex", "doom", "omen", "entropy", "gravity", "void", "silence", "fade", "dim", "null", "chill_touch"]],
	["rtp.barrier", ["fortify", "hide", "wall", "brace", "ward", "shield", "guard", "block", "bastion", "vigil"]],
	["rtp.ice6", ["shatter", "splinter", "fracture", "fault", "shard"]],
	["rtp.buff", ["provoke", "taunt", "haste", "stoke", "greed", "fury", "rage", "anthem", "war_cry"]],
	["rtp.debuff", ["mark", "prey", "quarry", "expose", "appraise", "gaze", "levy", "lockdown", "weaken", "vulnerable", "slow", "stun", "entangle"]],
]
const BITES: PackedStringArray = ["bite", "gnaw", "snap", "latch", "devour", "maw", "fang", "chomp", "swarm", "rend"]
const SHOTS: PackedStringArray = ["shot", "arrow", "needle", "pinprick"]
const HEAVY: PackedStringArray = ["slam", "bash", "hammer", "crush", "piston", "tremor", "quake", "abyss", "smash"]
const SHARDS: PackedStringArray = ["shatter", "splinter", "fracture", "fault", "shard"]
## Name groups that win over any damage type (Silence is dark even when it deals ice damage; Infect is a poison).
const OVER_ELEMENT: PackedStringArray = ["rtp.poison", "rtp.darkness3", "rtp.debuff"]
const ROLE_ENTRIES: Dictionary = {
	&"Ability.Role.Revive": "rtp.raise2", &"Ability.Role.Heal": "rtp.recovery5", &"Ability.Role.RestoreMP": "rtp.recovery8",
	&"Ability.Role.Cleanse": "rtp.chime2", &"Ability.Role.Dispel": "rtp.flash3", &"Ability.Role.Guard": "rtp.barrier",
	&"Ability.Role.Buff": "rtp.buff",
}

var _dry_run: bool = false
## Animations (file names without .tres) to classify again although they already play a bank entry (`--reclassify a,b`). Without
## it a bank entry already on an animation is kept: the user's tuning after the first pass is never overwritten.
var _reclassify: PackedStringArray = []
var _bank: SfxBank
var _report := PackedStringArray()
var _problems := PackedStringArray()
var _changed: int = 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_dry_run = args.has("--dry-run")
	var at := args.find("--reclassify")
	if at >= 0 and at + 1 < args.size():
		_reclassify = args[at + 1].split(",")
	_bank = SfxBank.load_manifest()
	if _bank.problem != "":
		push_error(_bank.problem)
		get_tree().quit(1)
		return
	var uses := _animation_uses()
	_report.append("# Audio pass report (spec audio-pass 3.4)\n")
	_report.append("Generated by `game/tools/build_audio_pass.tscn`%s. One row per animation: the moves that use it, " % (" (dry run)" if _dry_run else "")
		+ "their class, the sound before and after, and why.\n")
	_report.append("| Animation | Moves | Class | Before | After | Why |")
	_report.append("|---|---|---|---|---|---|")
	var files := Array(DirAccess.get_files_at(ANIMATIONS)).filter(func(f): return f.ends_with(".tres"))
	files.sort()
	for file in files:
		Watchdog.beat("audio pass " + file)
		_animation(ANIMATIONS + file, uses.get(ANIMATIONS + file, []))
	_report.append("\n## Effects\n")
	var effect_files := Array(DirAccess.get_files_at(EFFECTS)).filter(func(f): return f.ends_with(".tres"))
	effect_files.sort()
	for file in effect_files:
		_effect(EFFECTS + file)
	if not _problems.is_empty():
		_report.append("\n## Problems (left alone)\n")
		for line in _problems:
			_report.append("- " + line)
	var out := ProjectSettings.globalize_path("res://").path_join("../build/audio_pass_report.md").simplify_path()
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var handle := FileAccess.open(out, FileAccess.WRITE)
	handle.store_string("\n".join(_report) + "\n")
	handle.close()
	print("audio pass: %d files %s, %d problems; report %s" % [_changed, "would change" if _dry_run else "changed", _problems.size(), out])
	get_tree().quit(1 if not _problems.is_empty() else 0)


## animation path -> [{id, ability (BattleAbility), boss}], from every ability scene.
func _animation_uses() -> Dictionary:
	var bosses := _boss_abilities()
	var uses := {}
	var files := Array(DirAccess.get_files_at(ABILITIES)).filter(func(f): return f.ends_with(".tscn"))
	files.sort()
	for file in files:
		var scene := load(ABILITIES + file) as PackedScene
		var ability := scene.instantiate() as BattleAbility if scene != null else null
		if ability == null:
			continue
		if ability.animation != null:
			var path := ability.animation.resource_path
			var list: Array = uses.get(path, [])
			list.append({"id": file.get_basename(), "ability": ability, "boss": bosses.has(ABILITIES + file)})
			uses[path] = list
		else:
			ability.free()
	return uses


## Abilities a boss uses (its own file and its loadouts named after it), by text scan.
func _boss_abilities() -> Dictionary:
	var found := {}
	for file in DirAccess.get_files_at(ENEMIES):
		var text := FileAccess.get_file_as_string(ENEMIES + file)
		if not text.contains("Enemy.Boss"):
			continue
		var sources := [text]
		for loadout in DirAccess.get_files_at(LOADOUTS):
			if loadout.begins_with(file.get_basename()):
				sources.append(FileAccess.get_file_as_string(LOADOUTS + loadout))
		for source in sources:
			var regex := RegEx.create_from_string('path="(res://content/demo/abilities/[^"]+\\.tscn)"')
			for m in regex.search_all(source):
				found[m.get_string(1)] = true
	return found


## The bank entry a move gets, and why (3.4). "" for a move that stays silent.
func classify(id: String, ability: BattleAbility, boss: bool) -> Array:
	if ability.is_ultimate():
		return ["ult." + id, "ultimate: its own signature"]
	if UnitAnimator.plays_nothing(ability):
		return ["", "passive (B21: never animates)"]
	var words := id
	var types := {}
	for row in ability.executions:
		if row == null:
			continue
		for tag in row.tags:
			if String(tag).begins_with("Damage.Type."):
				types[String(tag).trim_prefix("Damage.Type.")] = true
		if row.effect != null:
			words += "_" + row.effect.resource_path.get_file().get_basename()
	# A physical hit sounds like one (Echo Strike is a strike), unless its name makes it a poison, a curse or a mark (Infect, Hex,
	# Mark Prey): those names win over any damage type.
	for group in KEYWORDS:
		if types.is_empty() or not OVER_ELEMENT.has(group[0]):
			continue
		var named := _matching(id, group[1])
		if named != "":
			return [group[0], "name '%s'" % named]
	if types.has("Physical") and not types.has("Fire") and not types.has("Ice"):
		for group in [["rtp.ice6", SHARDS, "shards"], ["rtp.blow2", BITES, "a bite or claw"], ["rtp.shot2", SHOTS, "a shot"],
				["rtp.blow4", HEAVY, "a heavy blow"]]:
			var word := _matching(id, group[1])
			if word != "":
				return [group[0], "physical: %s (%s)" % [group[2], word]]
		return ["rtp.blow4" if boss else "rtp.attack1", "physical%s" % (", boss: heavier" if boss else "")]
	# The move's own name next (Lingering Malady is a poison even with a Buff role; Silence is dark even with ice damage).
	for group in KEYWORDS:
		if (types.has("Fire") or types.has("Ice")) and not OVER_ELEMENT.has(group[0]):
			continue
		var word := _matching(id, group[1])
		if word != "":
			return [group[0], "name '%s'" % word]
	var many := ability.targeting == BattleAbility.Targeting.ALL_ENEMIES
	if types.has("Fire"):
		return ["rtp.fire3" if many else "rtp.fire1", "fire damage"]
	if types.has("Ice"):
		return ["rtp.ice6" if many else "rtp.ice2", "ice damage"]
	for role in ROLE_ENTRIES:
		if ability.asset_tags.has(role):
			return [ROLE_ENTRIES[role], "role %s" % String(role).trim_prefix("Ability.Role.")]
	for group in KEYWORDS:
		var word := _matching(words, group[1])
		if word != "":
			return [group[0], "its effect '%s'" % word]
	if ability.asset_tags.has(&"Ability.Role.Debuff"):
		return ["rtp.debuff", "role Debuff"]
	return ["rtp.magic1", "unclassified: the generic cast"]


## The first word of `words` found in `name` as a whole word (split at "_"); a keyword with "_" matches as a phrase.
static func _matching(name: String, words: Array) -> String:
	var tokens := name.split("_")
	for word in words:
		if (String(word).contains("_") and name.contains(word)) or tokens.has(word):
			return word
	return ""


func _animation(path: String, uses: Array) -> void:
	var text := FileAccess.get_file_as_string(path)
	var names := ", ".join(uses.map(func(u): return u["id"]))
	var before := _current_stream(text)
	var target := ""
	var why := ""
	var klass := ""
	# An ult always plays its own signature; any other move keeps a sound it already has (the user's pick, mapped into the bank
	# from the old folder, or a bank entry from an earlier pass or a hand edit) and a silent active move is classified.
	for use in uses:
		var picked: Array = classify(use["id"], use["ability"], use["boss"])
		if use["ability"].is_ultimate():
			target = picked[0]
			why = picked[1]
			klass = "ultimate"
			break
		if picked[0] != "" and klass == "":
			klass = picked[1]
			target = picked[0]
	for use in uses:
		use["ability"].free()
	var keep := not _reclassify.has(path.get_file().get_basename())
	if klass == "ultimate":
		if before != "" and before != SfxBank.bank_path(target):
			why += " (was %s)" % before.get_file()
	elif before.begins_with(SfxBank.BANK_DIR) and keep:
		_report.append("| %s | %s | %s | %s | %s | kept (already in the bank) |" % [path.get_file(), names, klass, before.get_file(), before.get_file().get_basename()])
		return
	elif before.begins_with(OLD_DIR):
		target = "rtp." + before.get_file().get_basename().to_lower()
		why = "kept your pick (%s)" % before.get_file()
	elif target != "":
		why = ("was silent: " if before == "" or before.begins_with(OLD_DIR) else "classified again: ") + klass
	elif before != "":
		_problems.append("%s: a sound (%s) on an animation only passives use; not changed" % [path.get_file(), before])
		return
	if target == "":
		return  # passives only, or no move: nothing plays, nothing to do
	if not _bank.has(target):
		_problems.append("%s: no bank entry %s for %s" % [path.get_file(), target, names])
		return
	var patched := patch_animation(text, SfxBank.bank_path(target))
	if patched == text:
		_report.append("| %s | %s | %s | %s | %s | already set |" % [path.get_file(), names, klass, before.get_file(), target])
		return
	var problem := guard(text, patched)
	if problem != "":
		_problems.append("%s: the patch would change more than sound (%s); not changed" % [path.get_file(), problem])
		return
	_write(path, patched)
	_report.append("| %s | %s | %s | %s | %s | %s |" % [path.get_file(), names, klass, before.get_file() if before != "" else "(silent)", target, why])


## The res:// path the animation's audio track plays now ("" when it has none or a null stream).
static func _current_stream(text: String) -> String:
	var block := _audio_block(text)
	if block.is_empty():
		return ""
	var m := RegEx.create_from_string('"stream": ExtResource\\("([^"]+)"\\)').search(text.substr(block[0], block[1] - block[0]))
	if m == null:
		return ""
	var ext := RegEx.create_from_string('\\[ext_resource [^\\]]*path="([^"]+)" id="%s"\\]' % _escape(m.get_string(1))).search(text)
	return ext.get_string(1) if ext != null else ""


## [start, end] of the audio track's lines, or [] when there is none.
static func _audio_block(text: String) -> Array:
	var m := RegEx.create_from_string('tracks/(\\d+)/type = "audio"').search(text)
	if m == null:
		return []
	var index := m.get_string(1)
	var start := m.get_start()
	var end := start
	var line := RegEx.create_from_string("(?m)^tracks/%s/.*$" % index)
	for found in line.search_all(text):
		end = maxi(end, found.get_end())
	# The keys dictionary spans lines up to its closing brace; the last tracks/<i>/ line (use_blend) comes after it.
	return [start, end]


static func _escape(value: String) -> String:
	var out := ""
	for c in value:
		out += ("\\" + c) if "\\^$.|?*+()[]{}".contains(c) else c
	return out


## The animation text with its audio track playing `bank_path` and its Audio:volume_db key at 0 (3.4). Pure text; static for tests.
static func patch_animation(text: String, bank_path: String) -> String:
	var out := text
	var block := _audio_block(out)
	if block.is_empty():
		var count := RegEx.create_from_string('(?m)^tracks/\\d+/type = ').search_all(out).size()
		out = _add_ext(out, bank_path)
		if not out.ends_with("\n"):
			out += "\n"
		out += ('tracks/{i}/type = "audio"\ntracks/{i}/imported = false\ntracks/{i}/enabled = true\ntracks/{i}/path = NodePath("Audio")\n'
			+ 'tracks/{i}/keys = {\n"clips": [{\n"end_offset": 0.0,\n"start_offset": 0.0,\n"stream": ExtResource("{id}")\n}],\n'
			+ '"times": PackedFloat32Array(0)\n}\ntracks/{i}/use_blend = true\n').format({"i": count, "id": NEW_EXT_ID})
	else:
		var segment := out.substr(block[0], block[1] - block[0])
		var m := RegEx.create_from_string('"stream": ExtResource\\("([^"]+)"\\)').search(segment)
		if m != null:
			var ext := RegEx.create_from_string('\\[ext_resource type="AudioStream"([^\\]]*) path="[^"]+" id="%s"\\]' % _escape(m.get_string(1)))
			out = ext.sub(out, '[ext_resource type="AudioStream"$1 path="%s" id="%s"]' % [bank_path, m.get_string(1)])
		elif segment.contains('"stream": null'):
			out = _add_ext(out, bank_path)
			block = _audio_block(out)
			segment = out.substr(block[0], block[1] - block[0])
			out = out.substr(0, block[0]) + segment.replace('"stream": null', '"stream": ExtResource("%s")' % NEW_EXT_ID) + out.substr(block[1])
	# The level now comes from the bank: the Audio:volume_db key goes to 0 dB (the track stays, so no track renumbers).
	var volume := RegEx.create_from_string('tracks/(\\d+)/path = NodePath\\("Audio:volume_db"\\)').search(out)
	if volume != null:
		var values := RegEx.create_from_string('(?s)(tracks/%s/keys = \\{.*?"values": \\[)([^\\]]*)(\\])' % volume.get_string(1))
		var vm := values.search(out)
		if vm != null:
			var zeros := ", ".join(Array(vm.get_string(2).split(",")).map(func(_v): return "0.0"))
			out = out.substr(0, vm.get_start()) + vm.get_string(1) + zeros + vm.get_string(3) + out.substr(vm.get_end())
	return out


static func _add_ext(text: String, bank_path: String) -> String:
	var line := '[ext_resource type="AudioStream" path="%s" id="%s"]\n' % [bank_path, NEW_EXT_ID]
	var last := -1
	for m in RegEx.create_from_string("(?m)^\\[ext_resource [^\\n]*\\n").search_all(text):
		last = m.get_end()
	if last >= 0:
		return text.substr(0, last) + line + text.substr(last)
	var at := text.find("\n[resource]")
	return text.substr(0, at + 1) + line + text.substr(at)


## "" when `patched` differs from `original` only in sound: same length and the same non-audio tracks with the same keys.
static func guard(original: String, patched: String) -> String:
	var a := _parse(original)
	var b := _parse(patched)
	if a == null or b == null:
		return "does not load"
	if a.length != b.length:
		return "length %s → %s" % [a.length, b.length]
	var kept_a := _non_audio(a)
	var kept_b := _non_audio(b)
	if kept_a.size() != kept_b.size():
		return "%d non-audio tracks → %d" % [kept_a.size(), kept_b.size()]
	for i in kept_a.size():
		if _track_text(a, kept_a[i]) != _track_text(b, kept_b[i]):
			return "track %s changed" % a.track_get_path(kept_a[i])
	return ""


static func _parse(text: String) -> Animation:
	var path := "user://audio_pass_probe_%d.tres" % Time.get_ticks_usec()
	var handle := FileAccess.open(path, FileAccess.WRITE)
	# The bank path may not exist yet in a test; a missing stream loads as null, which the guard ignores (audio tracks only).
	handle.store_string(text)
	handle.close()
	var animation := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Animation
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return animation


static func _non_audio(animation: Animation) -> Array[int]:
	var out: Array[int] = []
	for i in animation.get_track_count():
		if animation.track_get_type(i) == Animation.TYPE_AUDIO or String(animation.track_get_path(i)) == "Audio:volume_db":
			continue
		out.append(i)
	return out


static func _track_text(animation: Animation, track: int) -> String:
	var parts := PackedStringArray([str(animation.track_get_type(track)), str(animation.track_get_path(track)),
		str(animation.track_is_enabled(track))])
	for k in animation.track_get_key_count(track):
		parts.append("%s=%s" % [animation.track_get_key_time(track, k), var_to_str(animation.track_get_key_value(track, k))])
	return "|".join(parts)


func _effect(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var patched := patch_effect(text)
	if patched == text:
		return
	_write(path, patched)
	var added := PackedStringArray()
	for m in RegEx.create_from_string('&"(Cue\\.Sfx\\.[A-Za-z.]+)"').search_all(patched):
		if not added.has(m.get_string(1)):
			added.append(m.get_string(1))
	var removed := text.contains('&"Cue.Sfx.Hit"')
	_report.append("- %s: %s%s" % [path.get_file(), ", ".join(added) if not added.is_empty() else "(no sound cue)",
		" (Cue.Sfx.Hit removed: impacts now play by damage type)" if removed else ""])


## The effect text with its sound cues added beside the visual ones (3.5). Pure text, idempotent; static for tests.
static func patch_effect(text: String) -> String:
	var lists := {}
	var line_re := RegEx.create_from_string('(?m)^(application|periodic|persistent|removal)_cue_tags = Array\\[StringName\\]\\(\\[(.*)\\]\\)$')
	for m in line_re.search_all(text):
		var tags: Array[StringName] = []
		for t in RegEx.create_from_string('&"([^"]+)"').search_all(m.get_string(2)):
			tags.append(StringName(t.get_string(1)))
		lists[m.get_string(1)] = tags
	if lists.is_empty():
		return text
	var application: Array[StringName] = lists.get("application", [] as Array[StringName]).duplicate()
	var periodic: Array[StringName] = lists.get("periodic", [] as Array[StringName]).duplicate()
	for tag in REMOVED_CUES:
		application.erase(tag)
		periodic.erase(tag)
	var sounds: Array[StringName] = []
	for tag in lists.get("application", []):
		if APPLICATION_MAP.has(tag):
			sounds.append(APPLICATION_MAP[tag])
	for tag in lists.get("persistent", []):
		if PERSISTENT_TO_APPLICATION.has(tag):
			sounds.append(PERSISTENT_TO_APPLICATION[tag])
	for tag in SUPERSEDES:
		if sounds.has(tag):
			sounds.erase(SUPERSEDES[tag])
	var has_sound := application.any(func(t): return String(t).begins_with("Cue.Sfx."))
	if not has_sound:
		for sound in sounds:
			if not application.has(sound):
				application.append(sound)
	for tag in lists.get("periodic", []):
		if PERIODIC_MAP.has(tag) and not periodic.has(PERIODIC_MAP[tag]):
			periodic.append(PERIODIC_MAP[tag])
	var out := text
	out = _set_list(out, "application", application, lists.has("application"))
	out = _set_list(out, "periodic", periodic, lists.has("periodic"))
	return out


static func _set_list(text: String, kind: String, tags: Array[StringName], existed: bool) -> String:
	var line_re := RegEx.create_from_string('(?m)^%s_cue_tags = Array\\[StringName\\]\\(\\[.*\\]\\)\\n' % kind)
	var value := "%s_cue_tags = Array[StringName]([%s])\n" % [kind, ", ".join(tags.map(func(t): return '&"%s"' % t))]
	if existed:
		return line_re.sub(text, value if not tags.is_empty() else "")
	if tags.is_empty():
		return text
	# A new list goes right after the persistent one (where the status's visual is), else after the [resource] line.
	var persistent := RegEx.create_from_string('(?m)^persistent_cue_tags = .*\\n').search(text)
	var at := persistent.get_end() if persistent != null else text.find("\n", text.find("[resource]")) + 1
	return text.substr(0, at) + value + text.substr(at)


func _write(path: String, text: String) -> void:
	_changed += 1
	if _dry_run:
		return
	var handle := FileAccess.open(path, FileAccess.WRITE)
	handle.store_string(text)
	handle.close()
