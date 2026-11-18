## Credits (spec audio-pass 3.6, decision D4): opened from the main menu; lists every sound pack the bank uses, with its authors,
## licence and source, read from the bank's manifest (presentation/audio/sfx/manifest.json), the same data CREDITS.md is made from.
## CC BY asks for the credit where the sounds reach people, so the shipped game shows it. Presentation only.
extends UIScreen

@export_multiline var header: String = "Sound effects"
@export_multiline var changes_note: String = "Trimmed, converted to mono 16-bit WAV and loudness-matched for this game."


## Spec card-ui 3.5: the fonts and the game-icons glyphs (CC BY 3.0) the cards and packs use, after the sounds.
@export_multiline var art_credits: String = "[b]Fonts[/b]\nChakra Petch, by The Chakra Petch Project Authors · SIL Open Font License 1.1\nCinzel, by The Cinzel Project Authors · SIL Open Font License 1.1\n\n[b]Icons[/b]\ngame-icons.net · CC BY 3.0 · recoloured\nDelapouite: stairs"


func bind(_context: UIContext) -> void:
	%Text.text = text_of(SfxBank.load_manifest(), header, changes_note) + ("\n" + art_credits if art_credits != "" else "")


## The credits text for a bank (static so the tests read the same text the screen shows).
static func text_of(bank: SfxBank, title: String, note: String) -> String:
	if bank.problem != "":
		return bank.problem
	var used := {}
	for row in bank.entries():
		used[str(row.get("pack", ""))] = true
	var names := used.keys()
	names.sort()  # sort-ok: pack names are Strings
	var lines := PackedStringArray(["[b]%s[/b]" % title, note, ""])
	for name in names:
		var pack: Dictionary = bank.packs().get(name, {})
		lines.append("[b]%s[/b]" % pack.get("title", name))
		var authors := str(pack.get("author", ""))
		var by_file: Dictionary = pack.get("file_authors", {})
		if not by_file.is_empty():
			var people := {}
			for file in by_file:
				people[str(by_file[file].get("author", ""))] = true
			var list := people.keys()
			list.sort()  # sort-ok: author names are Strings
			authors = ", ".join(list)
		lines.append("by %s" % authors)
		lines.append("%s · %s" % [pack.get("licence", ""), pack.get("url", "")])
		lines.append("")
	return "\n".join(lines)
