## Spec audio-pass 5: the sound bank and the volumes from the console (the Audio screen's parity, plus dev checks). Never a cheat.
extends DevCommand


func _init() -> void:
	name = "audio"
	usage = "audio [buses | volume master|sfx|ui <0-100> | list [category] | play <bank id> | cue <Cue.Sfx tag> | check | stats]"
	help = "Sound: the buses and volumes (set and save one), the bank, play an entry or a sound cue, the sfx_* checks, cue counters."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	var verb := args[0] if args.size() > 0 else "buses"
	match verb:
		"buses":
			var lines := PackedStringArray()
			for volume_name in AudioSettings.names():
				var bus := AudioSettings.bus_of(volume_name)
				var index := AudioServer.get_bus_index(bus)
				lines.append("%s (%s): %s, saved %d%s" % [AudioSettings.label_of(volume_name), bus,
					("%d" % AudioSettings.current(volume_name)) if index >= 0 else "missing", AudioSettings.saved(volume_name),
					", muted" if index >= 0 and AudioServer.is_bus_mute(index) else ""])
			return "\n".join(lines)
		"volume":
			if args.size() < 3 or not args[2].is_valid_int():
				return ctx.fail("usage: audio volume master|sfx|ui <0-100>")
			var problem := AudioSettings.set_volume(args[1], int(args[2]))
			return ctx.fail(problem) if problem != "" else "%s: %d" % [AudioSettings.label_of(args[1]), clampi(int(args[2]), 0, 100)]
		"list":
			var bank := SfxBank.load_manifest()
			if bank.problem != "":
				return ctx.fail(bank.problem)
			var lines := PackedStringArray()
			for row in bank.entries():
				if args.size() > 1 and str(row.get("category", "")) != args[1]:
					continue
				var measured: Array = row.get("measured", [])
				lines.append("%s  [%s] %s, %d take%s%s" % [row.get("id", ""), row.get("category", ""), row.get("pack", ""),
					(row.get("takes", []) as Array).size(), "" if (row.get("takes", []) as Array).size() == 1 else "s",
					(", %d ms, %.1f LUFS" % [measured[0].get("ms", 0), measured[0].get("loudness", 0.0)]) if not measured.is_empty() else ""])
			return "\n".join(lines) if not lines.is_empty() else "no entries"
		"play":
			if args.size() < 2:
				return ctx.fail("usage: audio play <bank id>")
			var path := SfxBank.bank_path(args[1])
			if not ResourceLoader.exists(path):
				return ctx.fail("no bank entry %s" % args[1])
			var player := AudioStreamPlayer.new()
			player.stream = load(path)
			# The bus the game plays it on: the sound board's entries (ui., run., battle.) on Ui, cues and moves on Sfx.
			player.bus = &"Ui" if args[1].get_slice(".", 0) in ["ui", "run", "battle"] else &"Sfx"
			ctx.console.tree.root.add_child(player)
			player.finished.connect(player.queue_free)
			player.play()
			return "playing %s on %s" % [args[1], player.bus]
		"cue":
			if args.size() < 2:
				return ctx.fail("usage: audio cue <Cue.Sfx tag>")
			if not GameplayCueManager.has_cue(StringName(args[1])):
				return ctx.fail("no cue %s in the cue registry" % args[1])
			if GameplayCueManager.suppress_cues:
				return ctx.fail("cues are suppressed here (headless): nothing plays")
			GameplayCueManager.execute_cue(StringName(args[1]), ctx.console.tree.root, {})
			return "cue %s" % args[1]
		"check":
			var issues := AudioValidator.validate()
			return ContentValidator.report(issues) if not issues.is_empty() else "sound bank: no problems"
		"stats":
			var lines := PackedStringArray(["sound cues: %d played, %d throttled" % [SfxCue.plays, SfxCue.throttled]])
			for bus_index in AudioServer.bus_count:
				lines.append("bus %s: %.1f dB%s" % [AudioServer.get_bus_name(bus_index), AudioServer.get_bus_volume_db(bus_index),
					", muted" if AudioServer.is_bus_mute(bus_index) else ""])
			return "\n".join(lines)
	return ctx.fail("usage: " + usage)
