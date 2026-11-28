## Spec audio-pass 6: the sound bank, its buses and volumes, the sound cues and their throttle, the message routing, the audio pass's
## text patches and their guard, the sound board, the Audio and Credits screens, the console's `audio`, and the validator over the
## shipped bank. Presentation only: nothing here touches a battle's state or a hash. Nothing here saves the player's settings.
extends TestCase

var _services: Array[FxService] = []
var _nodes: Array[Node] = []
## The rule set stays referenced while its listeners live (in the game the effect registry holds it).
var _rules: FxRuleSet


func after_each() -> void:
	FxCueNotify.service_override = null
	SfxCue.clock_override = Callable()
	SfxCue.reset_stats()
	for service in _services:
		if is_instance_valid(service):
			service.stop_all()
			service.free()
	for node in _nodes:
		if is_instance_valid(node):
			node.free()
	var voices := host.get_tree().root.get_node_or_null(SfxCue.VOICES)
	if voices != null:
		for voice in voices.get_children():
			voice.free()
	_services.clear()
	_nodes.clear()
	_rules = null
	super()


# --- Buses and volumes (3.3) ---

func test_the_bus_layout_has_master_sfx_and_ui_with_a_limiter_and_no_mute() -> void:
	var layout := load("res://default_bus_layout.tres") as AudioBusLayout
	check(layout != null, "the bus layout exists")
	var text := FileAccess.get_file_as_string("res://default_bus_layout.tres")
	check(text.contains('bus/1/name = &"Sfx"') and text.contains('bus/2/name = &"Ui"'), "Sfx and Ui buses")
	check(not text.contains('bus/3/'), "exactly three buses (no Music: there is no music)")
	check(text.contains("AudioEffectHardLimiter") and text.contains("bus/0/effect/0/effect"), "a hard limiter on Master")
	check(not text.contains("mute = true"), "no bus is saved muted (the headless mute must never ship)")
	for bus in [&"Sfx", &"Ui"]:
		check(AudioServer.get_bus_index(bus) >= 0, "the running game has the %s bus" % bus)
		eq(AudioServer.get_bus_send(AudioServer.get_bus_index(bus)), &"Master", "%s sends to Master" % bus)


func test_volumes_map_to_bus_gain_and_zero_is_silent() -> void:
	eq(AudioSettings.db_of(100), 0.0, "100 is unity gain")
	check(absf(AudioSettings.db_of(50) - linear_to_db(0.5)) < 0.001, "50 is half the amplitude")
	eq(AudioSettings.db_of(0), AudioSettings.SILENT_DB, "0 is silent (by volume, never by mute)")
	var index := AudioServer.get_bus_index(&"Ui")
	var before := AudioServer.get_bus_volume_db(index)
	eq(AudioSettings.apply("ui", 40), "", "a volume applies to its bus")
	eq(AudioSettings.current("ui"), 40, "and reads back")
	eq(AudioSettings.apply("ui", 0), "", "0 applies")
	eq(AudioSettings.current("ui"), 0, "and reads back as 0")
	check(not AudioServer.is_bus_mute(index), "0 never mutes the bus")
	check(AudioSettings.apply("music", 50).contains("unknown volume"), "an unknown volume is refused")
	AudioServer.set_bus_volume_db(index, before)


func test_the_saved_volumes_default_to_full() -> void:
	for volume_name in AudioSettings.names():
		var saved := AudioSettings.saved(volume_name)
		check(saved >= 0 and saved <= 100, "%s is saved in range" % volume_name)
	eq(Array(AudioSettings.names()), ["master", "sfx", "ui"], "Master, Effects, Interface")


# --- The bank (2.2, 3.1, 3.2) ---

func test_every_manifest_row_has_its_takes_and_its_randomizer() -> void:
	var bank := SfxBank.load_manifest()
	eq(bank.problem, "", "the manifest reads")
	check(bank.entries().size() >= 90, "the bank has its entries (%d)" % bank.entries().size())
	for row in bank.entries():
		var stream := load(SfxBank.bank_path(str(row["id"]))) as AudioStreamRandomizer
		check(stream != null, "%s has its AudioStreamRandomizer" % row["id"])
		if stream == null:
			continue
		eq(stream.streams_count, (row["takes"] as Array).size(), "%s holds every take" % row["id"])
		for i in stream.streams_count:
			check(stream.get_stream(i) != null and stream.get_stream(i).resource_path == SfxBank.take_path(row, i),
				"%s take %d is its imported WAV" % [row["id"], i + 1])


func test_the_bank_is_balanced_short_and_licensed() -> void:
	var bank := SfxBank.load_manifest()
	var tolerance := float(bank.data["tolerance_db"])
	for row in bank.entries():
		var category := str(row["category"])
		check(SfxBank.ALLOWED_LICENCES.has(str(bank.packs()[row["pack"]]["licence"])), "%s's pack has an allowed licence" % row["id"])
		for take in row.get("measured", []):
			check(absf(float(take["loudness"]) - bank.target_of(category)) <= tolerance,
				"%s at %.1f LUFS is within %.1f dB of %s's %.1f" % [row["id"], take["loudness"], tolerance, category, bank.target_of(category)])
			check(float(take["peak_db"]) <= float(bank.data["peak_ceiling_db"]) + 0.3, "%s peaks under the ceiling" % row["id"])
			check(int(take["ms"]) <= bank.max_ms_of(category) + 5, "%s is no longer than %s's %d ms" % [row["id"], category, bank.max_ms_of(category)])
	check(bank.max_ms_of("ui") <= 350, "interface sounds are very short (user, 2026-11-15)")
	for pack in bank.packs().values():
		check(not str(pack["folder"]).contains(SfxBank.FORBIDDEN_DIR), "no pack comes from do_not_include")


func test_retro_anime_is_only_for_death_ray_and_oblivion() -> void:
	var bank := SfxBank.load_manifest()
	eq(Array(bank.reserved_allow()), ["ult.death_ray", "ult.oblivion"], "the allow-list (user, 2026-11-15)")
	for row in bank.entries():
		if bank.is_reserved(row):
			check(bank.reserved_allow().has(str(row["id"])), "%s uses the reserved pack only by permission" % row["id"])


func test_the_shipped_bank_passes_its_checks() -> void:
	if skip_in_export():
		return
	var issues := AudioValidator.validate()
	eq(ContentValidator.report(issues), "0 error(s), 0 warning(s)", "the sfx_* checks pass on the shipped bank and content")


func test_the_validator_catches_a_bad_licence_and_a_reserved_misuse() -> void:
	var bank := SfxBank.new()
	bank.data = {"packs": {"bad": {"folder": "x", "licence": "CC-BY-SA-4.0"}, "anime": {"folder": "a", "licence": "CC0-1.0", "reserved": true}},
		"entries": [{"id": "x.one", "pack": "bad", "takes": ["a.wav"], "category": "ui"},
			{"id": "ult.nope", "pack": "anime", "takes": ["b.wav"], "category": "signature"}],
		"reserved_allow": [], "targets": {"ui": -22, "signature": -15}, "max_ms": {"ui": 350, "signature": 3000}}
	var codes := AudioValidator.validate(bank, "res://tests/fixtures/none/").map(func(i): return i.code)
	check(codes.has("sfx_licence"), "CC BY-SA is refused")
	check(codes.has("sfx_reserved_source"), "a reserved pack outside the allow-list is refused")
	check(codes.has("sfx_file_missing"), "an entry with no files is reported")


# --- The sound cues (2.4, 3.2) ---

func _cue(tag: StringName, max_voices: int = 3) -> SfxCue:
	var cue := SfxCue.new()
	cue.sound = load(SfxBank.bank_path("hit.physical"))
	cue.max_voices = max_voices
	cue.auto_destroy = false
	cue.gameplay_cue_tag = tag
	host.add_child(cue)
	_nodes.append(cue)
	return cue


func test_a_cue_plays_its_bank_entry_on_the_sfx_bus() -> void:
	var target := Node.new()
	host.add_child(target)
	_nodes.append(target)
	var cue := _cue(&"Cue.Sfx.Test")
	cue.execute_cue(target)
	eq(SfxCue.plays, 1, "it played once (the base class's second play_cue is not called)")
	var voices := SfxCue.live_voices(host.get_tree())
	eq(voices.size(), 1, "on one voice")
	if voices.is_empty():
		return
	eq(voices[0].bus, &"Sfx", "on the Sfx bus")
	eq(voices[0].stream, cue.sound, "its bank entry")
	check(voices[0].get_parent() != cue and voices[0].get_parent() != target, "the voice lives under SfxVoices, not under the cue or the unit")
	target.free()
	cue.free()
	await host.get_tree().process_frame
	eq(SfxCue.live_voices(host.get_tree()).size(), 1, "the sound outlives its cue and its unit (a death sound at a battle's end)")
	voices[0].finished.emit()
	await host.get_tree().process_frame
	eq(SfxCue.live_voices(host.get_tree()).size(), 0, "and is idle when it has finished")
	_cue(&"Cue.Sfx.Test").execute_cue(null)
	eq(SfxCue.pooled_voices(host.get_tree()), 1, "the next play reuses the idle voice (no player per hit)")


func test_the_throttle_skips_repeats_on_one_unit_and_caps_the_voices() -> void:
	var now := [10.0]
	SfxCue.clock_override = func() -> float: return now[0]
	var targets: Array[Node] = []
	for i in 4:
		var target := Node.new()
		host.add_child(target)
		_nodes.append(target)
		targets.append(target)
	var first := _cue(&"Cue.Sfx.Test", 3)
	first.execute_cue(targets[0])
	_cue(&"Cue.Sfx.Test", 3).execute_cue(targets[0])
	eq(SfxCue.plays, 1, "a repeat on the same unit inside min_interval does not play")
	eq(SfxCue.throttled, 1, "and is counted as throttled")
	for i in range(1, 4):
		_cue(&"Cue.Sfx.Test", 3).execute_cue(targets[i])
	eq(SfxCue.plays, 3, "four units hit at once: at most max_voices copies sound")
	eq(SfxCue.voices_of(&"Cue.Sfx.Test"), 3, "three voices are sounding")
	SfxCue.live_voices(host.get_tree())[0].finished.emit()
	eq(SfxCue.voices_of(&"Cue.Sfx.Test"), 2, "a finished sound frees its voice")
	now[0] = 10.5
	_cue(&"Cue.Sfx.Test", 3).execute_cue(targets[0])
	eq(SfxCue.plays, 4, "later, the same unit plays again")


func test_every_sound_cue_is_registered_and_plays_a_bank_entry() -> void:
	var registry := load("res://godot_gas/cue_registry.tres") as GameplayCueRegistry
	var tags := {}
	for entry in registry.entries:
		tags[entry.tag] = entry.scene_path()
	check(not tags.has(&"Cue.Sfx.Hit"), "the old generic hit cue is gone")
	for tag in ["Cue.Sfx.Hit.Physical", "Cue.Sfx.Hit.Fire", "Cue.Sfx.Hit.Ice", "Cue.Sfx.Hit.Crit", "Cue.Sfx.Hit.Weakness",
			"Cue.Sfx.Hit.Resisted", "Cue.Sfx.Hit.Drained", "Cue.Sfx.Break", "Cue.Sfx.Recovered", "Cue.Sfx.Tick.Poison",
			"Cue.Sfx.Tick.Bleed", "Cue.Sfx.Tick.Burn", "Cue.Sfx.Status.Control", "Cue.Sfx.Apply.Buff", "Cue.Sfx.Apply.Debuff",
			"Cue.Sfx.Cleanse", "Cue.Sfx.Heal", "Cue.Sfx.Revive", "Cue.Sfx.Death", "Cue.Sfx.Downed", "Cue.Sfx.PhaseShift",
			"Cue.Sfx.OneMore", "Cue.Sfx.Resisted", "Cue.Sfx.Overtime"]:
		check(tags.has(StringName(tag)), "%s is registered" % tag)
		if not tags.has(StringName(tag)):
			continue
		var node := (load(tags[StringName(tag)]) as PackedScene).instantiate()
		check(node is SfxCue and (node as SfxCue).sound != null and (node as SfxCue).sound.resource_path.begins_with(SfxBank.BANK_DIR),
			"%s plays a bank entry" % tag)
		check(node is SfxCue and (node as SfxCue).bus == &"Sfx", "%s plays on Sfx" % tag)
		node.free()


func test_damage_no_longer_lists_the_generic_hit_and_statuses_list_their_sounds() -> void:
	var damage := load("res://content/demo/effects/damage.tres") as GameplayEffect
	check(not damage.application_cue_tags.has(&"Cue.Sfx.Hit"), "damage.tres has no generic hit sound (impacts play by type)")
	var freeze := load("res://content/demo/effects/freeze.tres") as GameplayEffect
	check(freeze.application_cue_tags.has(&"Cue.Sfx.Status.Control"), "a control status plays its sound when it lands")
	var poison := load("res://content/demo/effects/poison.tres") as GameplayEffect
	check(poison.periodic_cue_tags.has(&"Cue.Sfx.Tick.Poison"), "a DoT tick plays its tick sound")
	var enrage := load("res://content/demo/effects/enrage.tres") as GameplayEffect
	check(enrage.application_cue_tags.has(&"Cue.Sfx.Overtime"), "the overtime enrage plays the clock")


# --- Message routing (2.3, 2.4) ---

func _routing() -> Array:
	var service := FxService.new()
	service.enabled = true
	service.manual_clock = true
	host.add_child(service)
	_services.append(service)
	FxCueNotify.service_override = service
	var view := Node3D.new()
	host.add_child(view)
	_nodes.append(view)
	service.unit_resolver = func(_unit_id: StringName) -> Node3D: return view
	var owner_node := Node.new()
	host.add_child(owner_node)
	_nodes.append(owner_node)
	_rules = load("res://presentation/demo/fx/sfx_rules.tres") as FxRuleSet
	_rules.attach(owner_node)
	return [service, view]


func _sounding(_view: Node) -> Array:
	return SfxCue.plays_by_tag.keys()


func test_battle_messages_play_their_sound_cues() -> void:
	if skip_in_export():
		return
	var parts := _routing()
	var view: Node3D = parts[1]
	var was_suppressed: bool = GameplayCueManager.suppress_cues
	GameplayCueManager.suppress_cues = false
	GameplayMessages.broadcast(&"Message.Battle.Damage", VerbMessage.make(&"Verb.Damage", &"P1", &"E1", 900, [&"Damage.Type.Fire"]))
	check(_sounding(view).has(&"Cue.Sfx.Hit.Fire"), "a fire hit plays the fire impact")
	check(not _sounding(view).has(&"Cue.Sfx.Hit.Physical"), "and not the physical one")
	GameplayMessages.broadcast(&"Message.Battle.Damage", VerbMessage.make(&"Verb.Damage", &"P1", &"E2", 900,
		[&"Damage.Type.Ice", &"Hit.Critical"]))
	check(_sounding(view).has(&"Cue.Sfx.Hit.Ice") and _sounding(view).has(&"Cue.Sfx.Hit.Crit"), "a crit layers its accent on the ice impact")
	for pair in [[&"Message.Battle.Broken", &"Cue.Sfx.Break"], [&"Message.Battle.Downed", &"Cue.Sfx.Downed"],
			[&"Message.Battle.Phase", &"Cue.Sfx.PhaseShift"], [&"Message.Battle.OneMore", &"Cue.Sfx.OneMore"],
			[&"Message.Battle.UnitDied", &"Cue.Sfx.Death"], [&"Message.Battle.Resisted", &"Cue.Sfx.Resisted"]]:
		GameplayMessages.broadcast(pair[0], VerbMessage.make(&"Verb.Use", &"P1", &"E3", 0, []))
		check(_sounding(view).has(pair[1]), "%s plays %s" % [pair[0], pair[1]])
	GameplayCueManager.suppress_cues = was_suppressed


func test_sounds_still_play_with_visual_effects_off() -> void:
	if skip_in_export():
		return
	var parts := _routing()
	var service: FxService = parts[0]
	service.quality = FxQuality.OFF
	var was_suppressed: bool = GameplayCueManager.suppress_cues
	GameplayCueManager.suppress_cues = false
	GameplayMessages.broadcast(&"Message.Battle.Damage", VerbMessage.make(&"Verb.Damage", &"P1", &"E1", 900, [&"Damage.Type.Physical"]))
	check(_sounding(parts[1]).has(&"Cue.Sfx.Hit.Physical"), "turning visual effects off does not mute the game (D1)")
	GameplayCueManager.suppress_cues = was_suppressed


func test_ult_charge_and_ult_presses_make_no_sound() -> void:
	for rule in (load("res://presentation/demo/fx/sfx_rules.tres") as FxRuleSet).rules:
		check(not String(rule.channel).contains("Ult"), "no sound rule listens to ult charge or presses (%s)" % rule.channel)
	var board := FileAccess.get_file_as_string("res://presentation/demo/sound_board.gd")
	check(not board.contains("UI_ULT_PRESSED") and not board.contains("UltPressed"), "nor does the sound board (user, 2026-11-15)")


func test_headless_suppresses_the_sound_cues() -> void:
	if DisplayServer.get_name() != "headless":
		return
	check(GameplayCueManager.suppress_cues, "headless runs (the verifier) execute no cue, so no sound scene loads")


# --- The audio pass's patches (3.4) ---

const ANIMATION := """[gd_resource type="Animation" format=3]

[resource]
resource_name = "probe"
length = 0.6
tracks/0/type = "method"
tracks/0/imported = false
tracks/0/enabled = true
tracks/0/path = NodePath(".")
tracks/0/interp = 1
tracks/0/loop_wrap = true
tracks/0/keys = {
"times": PackedFloat32Array(0.3),
"transitions": PackedFloat32Array(1),
"values": [{
"args": [&"hit"],
"method": &"execute"
}]
}
"""


func test_the_pass_adds_a_sound_to_a_silent_animation_and_touches_nothing_else() -> void:
	var bank_path := SfxBank.bank_path("rtp.attack1")
	var patched := BuildAudioPass.patch_animation(ANIMATION, bank_path)
	check(patched.contains('[ext_resource type="AudioStream" path="%s" id="sfx_bank"]' % bank_path), "the bank entry is referenced")
	check(patched.contains('tracks/1/type = "audio"') and patched.contains('"stream": ExtResource("sfx_bank")'), "an audio track was added")
	eq(BuildAudioPass.guard(ANIMATION, patched), "", "the execute keys and length are unchanged")
	eq(BuildAudioPass.patch_animation(patched, bank_path), patched, "a second pass changes nothing")


func test_the_pass_maps_a_stream_fills_a_null_one_and_zeroes_the_volume_key() -> void:
	var with_sound := ANIMATION.replace("[resource]", '[ext_resource type="AudioStream" path="res://presentation/audio/rtp/Fire1.wav" id="1_sfx"]\n\n[resource]') + \
		'tracks/1/type = "audio"\ntracks/1/imported = false\ntracks/1/enabled = true\ntracks/1/path = NodePath("Audio")\ntracks/1/keys = {\n"clips": [{\n"end_offset": 0.0,\n"start_offset": 0.0,\n"stream": ExtResource("1_sfx")\n}],\n"times": PackedFloat32Array(0)\n}\ntracks/1/use_blend = true\n' + \
		'tracks/2/type = "value"\ntracks/2/imported = false\ntracks/2/enabled = true\ntracks/2/path = NodePath("Audio:volume_db")\ntracks/2/interp = 1\ntracks/2/loop_wrap = true\ntracks/2/keys = {\n"times": PackedFloat32Array(0),\n"transitions": PackedFloat32Array(1),\n"update": 1,\n"values": [16.5]\n}\n'
	var patched := BuildAudioPass.patch_animation(with_sound, SfxBank.bank_path("rtp.fire1"))
	check(patched.contains('path="%s" id="1_sfx"' % SfxBank.bank_path("rtp.fire1")), "the old stream's reference now names the bank entry")
	check(not patched.contains("audio/rtp/"), "nothing points at the old folder")
	check(patched.contains('"values": [0.0]') and not patched.contains("16.5"), "the volume key is 0 dB (the bank carries the level)")
	var null_stream := with_sound.replace('"stream": ExtResource("1_sfx")', '"stream": null').replace('[ext_resource type="AudioStream" path="res://presentation/audio/rtp/Fire1.wav" id="1_sfx"]\n\n', "")
	var filled := BuildAudioPass.patch_animation(null_stream, SfxBank.bank_path("rtp.blow2"))
	check(filled.contains('"stream": ExtResource("sfx_bank")') and not filled.contains('"stream": null'), "an empty stream gets the entry")


func test_the_guard_refuses_a_patch_that_moves_an_execute_key() -> void:
	var moved := ANIMATION.replace('"times": PackedFloat32Array(0.3)', '"times": PackedFloat32Array(0.4)')
	check(BuildAudioPass.guard(ANIMATION, moved) != "", "an execute key that moved is caught (combat reads them)")
	check(BuildAudioPass.guard(ANIMATION, ANIMATION.replace("length = 0.6", "length = 0.7")) != "", "a new length is caught")


func test_the_effect_patch_adds_sounds_beside_the_visual_cues_once() -> void:
	var freeze := '[resource]\npersistent_cue_tags = Array[StringName]([&"Cue.Fx.Status.Freeze"])\n'
	var patched := BuildAudioPass.patch_effect(freeze)
	check(patched.contains('application_cue_tags = Array[StringName]([&"Cue.Sfx.Status.Control"])'), "a control gets its landing sound")
	eq(BuildAudioPass.patch_effect(patched), patched, "a second pass changes nothing")
	var burn := '[resource]\npersistent_cue_tags = Array[StringName]([&"Cue.Fx.Status.Burn"])\napplication_cue_tags = Array[StringName]([&"Cue.Fx.Apply.Debuff"])\nperiodic_cue_tags = Array[StringName]([&"Cue.Fx.Tick.Burn"])\n'
	var burned := BuildAudioPass.patch_effect(burn)
	check(burned.contains('[&"Cue.Fx.Apply.Debuff", &"Cue.Sfx.Apply.Debuff"]'), "one debuff sound, not two")
	check(burned.contains('[&"Cue.Fx.Tick.Burn", &"Cue.Sfx.Tick.Burn"]'), "the tick plays its sound")
	var damage := '[resource]\napplication_cue_tags = Array[StringName]([&"Cue.Sfx.Hit"])\nexecutions = []\n'
	check(not BuildAudioPass.patch_effect(damage).contains("application_cue_tags"), "the generic hit goes, and its empty list with it")


func test_every_active_move_in_the_demo_makes_a_sound() -> void:
	if skip_in_export():
		return
	var issues := AudioValidator._missing(SfxBank.load_manifest(), "res://content/demo/abilities/")
	eq(issues.size(), 0, "no silent active move (incl. the boss ults Overheat, Twin Beat, Black Mass, Systole): %s" % ContentValidator.report(issues))


# --- The sound board, the screens, the credits, the console (3.3, 3.5, 3.6, 5) ---

func test_the_sound_board_plays_bank_entries_on_the_ui_bus() -> void:
	var board := (load("res://presentation/demo/sound_board.tscn") as PackedScene).instantiate()
	_nodes.append(board)
	for sound_name in ["Hover", "Confirm", "Back", "Refused", "PopupOpen", "PopupNo", "MenuOpen", "MenuClose", "Advance", "Item",
			"Coin", "Key", "LevelUp", "Move", "Floor", "BattleStart"]:
		var player := board.get_node_or_null(sound_name) as AudioStreamPlayer
		check(player != null, "the board has %s" % sound_name)
		if player == null:
			continue
		eq(player.bus, &"Ui", "%s plays on Ui" % sound_name)
		check(player.stream != null and player.stream.resource_path.begins_with(SfxBank.BANK_DIR), "%s plays a bank entry" % sound_name)
		eq(player.volume_db, 0.0, "%s plays at 0 dB (the bank carries the level)" % sound_name)
	check(board.get_node_or_null("Death") == null, "death moved to its cue on the unit")


func _game() -> GameMain:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	return game


func test_the_audio_screen_has_three_sliders_showing_the_saved_volumes() -> void:
	var game := _game()
	await host.get_tree().process_frame
	var screen: UIScreen = game.ui.push(&"UI.Layer.Menu", load("res://presentation/demo/ui/audio_settings.tscn"))
	await host.get_tree().process_frame
	for pair in [["%MasterVolume", "master"], ["%SfxVolume", "sfx"], ["%UiVolume", "ui"]]:
		var slider := screen.get_node_or_null(pair[0]) as HSlider
		check(slider != null, "the %s slider" % pair[1])
		if slider == null:
			continue
		eq(int(slider.value), AudioSettings.saved(pair[1]), "%s shows the saved volume" % pair[1])
		eq(slider.max_value, 100.0, "%s goes to 100" % pair[1])
		check(slider.value_changed.get_connections().size() > 0, "%s is wired (applies and saves)" % pair[1])
	game.free()


func test_the_credits_screen_and_file_name_every_pack_and_author() -> void:
	var bank := SfxBank.load_manifest()
	var text: String = load("res://presentation/demo/ui/credits.gd").text_of(bank, "Sound effects", "a note")
	for row in bank.entries():
		var pack: Dictionary = bank.packs()[row["pack"]]
		check(text.contains(str(pack["title"])), "the screen credits %s" % pack["title"])
	check(text.contains("lumiscosity"), "EasyRPG's CC BY author is named")
	check(text.contains("Helton Yan"), "Pixel Combat's author is named")
	var menu := FileAccess.get_file_as_string("res://presentation/demo/ui/main_menu.tscn")
	check(menu.contains("credits.tscn") and menu.contains('text = "Credits"'), "the main menu has a Credits button (D4)")
	if skip_in_export():
		return
	var credits := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://../CREDITS.md").simplify_path())
	check(credits.contains("FREE Pixel Combat SFX") and credits.contains("EasyRPG RTP") and credits.contains("lumiscosity"),
		"CREDITS.md credits the packs and EasyRPG's per-file authors")


func test_the_console_command_shows_lists_and_checks() -> void:
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)
	var shown: Dictionary = await console.execute("audio")
	check(str(shown["text"]).contains("Master") and str(shown["text"]).contains("Effects") and str(shown["text"]).contains("Interface"),
		"audio shows the three volumes: %s" % shown["text"])
	var listed: Dictionary = await console.execute("audio list ui")
	check(str(listed["text"]).contains("ui.cursor"), "audio list shows the bank: %s" % listed["text"])
	var bad: Dictionary = await console.execute("audio volume loud 50")
	check(not bad["ok"], "an unknown volume is refused")
	var missing: Dictionary = await console.execute("audio play nope.nothing")
	check(not missing["ok"], "an unknown bank entry is refused")
	var stats: Dictionary = await console.execute("audio stats")
	check(str(stats["text"]).contains("sound cues:"), "audio stats counts the cues")


func _board(game: GameMain) -> Node:
	return game.get_tree().get_first_node_in_group("sound_board")


func test_the_board_hears_the_ui_once_it_exists() -> void:
	var game := _game()
	await host.get_tree().process_frame
	var board := _board(game)
	check(board != null, "the game has its sound board")
	check(game.ui.confirm_opened.get_connections().size() > 0, "the board listens for confirm dialogs (connected after the UI is built)")
	check(game.ui.stack_changed.get_connections().any(func(c): return c["callable"].get_object() == board), "and for the run menu")
	board.history.clear()
	game.ui.confirm_opened.emit()
	check(board.history.has("PopupOpen"), "a confirm dialog plays PopupOpen")
	game.free()


func test_a_resumed_run_replays_no_change_sounds() -> void:
	var game := _game()
	game.content_root = "res://tests/fixtures/"
	game.load_content()
	await host.get_tree().process_frame
	game.start_run(["fixture.character.knight", "fixture.character.medic"], "7", &"fixture.run.two_floors")
	for frame in 2:
		await host.get_tree().process_frame
	var board := _board(game)
	game.run.state.coins += 40  # as a restored save would hold
	board.history.clear()
	game.run.announce_resumed()
	await host.get_tree().process_frame
	check(not board.history.has("Coin") and not board.history.has("Key") and not board.history.has("Advance"),
		"announce_resumed re-sends signals for old things, and the board plays none of them: %s" % ", ".join(board.history))
	check(not game.run.announcing, "the flag is down again")
	game.run.add_coins(5)
	check(board.history.has("Coin"), "coins gained afterwards play Coin")
	game.free()


## Spec audio-pass 6.15: the import tool refuses a share-alike licence, a do_not_include folder and a reserved pack outside its
## allow-list before it reads anything (Python + ffmpeg live outside Godot; skipped where Python is missing).
func test_the_import_tool_refuses_what_may_not_be_committed() -> void:
	if skip_in_export():
		return
	var tool := ProjectSettings.globalize_path("res://../tools/audio_import.py").simplify_path()
	var probe: Array = []
	if OS.execute("python", ["--version"], probe) != 0:
		skipped = "python is not on PATH"
		return
	for pair in [["refused_licence.json", "licence"], ["refused_forbidden.json", "do_not_include"], ["refused_reserved.json", "reserved"]]:
		var output: Array = []
		var code := OS.execute("python", ["-I", tool, "--manifest", ProjectSettings.globalize_path("res://tests/fixtures/audio/" + pair[0]),
			"--check"], output, true)
		eq(code, 2, "%s is refused (exit 2)" % pair[0])
		check(str(output).contains("refused") and str(output).contains(pair[1]), "and says why (%s): %s" % [pair[1], str(output).left(200)])


## Review fix: a battle replayed inside a silent run (ServerLink's resume tail) plays no sound; the player's own run does.
func test_a_silent_replay_plays_no_sound_cue() -> void:
	var replay := RunController.new()
	replay.silent = true
	host.add_child(replay)
	_nodes.append(replay)
	var unit := Node.new()
	replay.add_child(unit)
	_cue(&"Cue.Sfx.Test").execute_cue(unit)
	eq(SfxCue.plays, 0, "a unit under a silent run plays nothing")
	replay.silent = false
	_cue(&"Cue.Sfx.Test").execute_cue(unit)
	eq(SfxCue.plays, 1, "the same unit in a normal run plays")


## The run says what happened (spec audio-pass review): coins gained, a room unlocked and one level-up message per action, so the
## board plays from messages instead of guessing from state.
func test_the_board_plays_run_messages() -> void:
	var game := _game()
	game.content_root = "res://tests/fixtures/"
	game.load_content()
	await host.get_tree().process_frame
	game.start_run(["fixture.character.knight", "fixture.character.medic"], "7", &"fixture.run.two_floors")
	for frame in 2:
		await host.get_tree().process_frame
	var board := _board(game)
	var heard := []
	GameplayMessages.listen(GameplayMessageRouter.RUN_LEVELS_GAINED, func(_c, m): heard.append(m.magnitude), GameplayMessageRouter.Match.EXACT, null, board)
	board.history.clear()
	game.run.add_coins(3)
	check(board.history.has("Coin"), "Message.Run.CoinsGained plays Coin")
	board.history.clear()
	game.run.add_coins(-2)
	check(not board.history.has("Coin"), "spending coins plays no Coin")
	board.history.clear()
	GameplayMessages.broadcast(GameplayMessageRouter.RUN_ROOM_UNLOCKED, VerbMessage.make(&"Verb.Enter", &"", &"room", 0))
	game.run.room_entered.emit(game.run.state.current_cell)
	await host.get_tree().process_frame
	check(board.history.has("Key") and not board.history.has("Move"), "a room opened with a key plays Key instead of Move")
	board.history.clear()
	game.run.room_entered.emit(game.run.state.current_cell)
	await host.get_tree().process_frame
	check(not board.history.has("Key"), "the next room is a plain move again")
	# The fixtures have no XP curve: a copy of the run's structure gets one (as test_dev_console does).
	var structure: RunStructure = game.run.structure.duplicate()
	var curve: Array[int] = [100, 300, 600]
	structure.xp_to_level = curve
	game.run.structure = structure
	board.history.clear()
	game.run.gain_levels(1, null)
	eq(Array(board.history).count("LevelUp"), 1, "two members levelling at once play one LevelUp (one message per action)")
	eq(heard.size(), 1, "one Message.Run.LevelsGained")
	if not heard.is_empty():
		eq(int(heard[0]), 2, "carrying the levels gained in all")
	game.free()


## Spec audio-pass 3.4 / second-pack 2.6: every ultimate (pressed, or cast by itself from its ult bar) plays its own signature sound
## (a `ult.*` bank entry no other ultimate uses); a rank (`_2`, `_3`) shares its first rank's.
func test_every_ultimate_has_its_own_sound() -> void:
	if skip_in_export():
		return
	var owner_of := {}
	for file in DirAccess.get_files_at("res://content/demo/abilities/"):
		if not file.ends_with(".tscn"):
			continue
		var base := file.get_basename().trim_suffix("_2").trim_suffix("_3")
		if base != file.get_basename() and ResourceLoader.exists("res://content/demo/abilities/" + base + ".tscn"):
			continue  # a rank: checked through its first rank
		var ability := (load("res://content/demo/abilities/" + file) as PackedScene).instantiate() as BattleAbility
		if ability == null:
			continue
		var ultimate := ability.is_ultimate() or (ability.is_meter() and ability.meter_attribute == BattleUnit.ENERGY)
		if ultimate and ability.animation != null:
			var sounds: Array[String] = []
			for track in ability.animation.get_track_count():
				if ability.animation.track_get_type(track) == Animation.TYPE_AUDIO:
					for key in ability.animation.track_get_key_count(track):
						var stream := ability.animation.audio_track_get_key_stream(track, key)
						if stream != null and stream.resource_path.get_file().begins_with("ult."):
							sounds.append(stream.resource_path.get_file())
			check(not sounds.is_empty(), "%s plays a signature (ult.*) sound" % file)
			for sound in sounds:
				check(not owner_of.has(sound) or owner_of[sound] == file, "%s shares %s with %s" % [file, sound, owner_of.get(sound, "")])
				owner_of[sound] = file
		ability.free()
	check(owner_of.size() >= 29, "every ultimate checked (%d sounds)" % owner_of.size())
