## Spec event-pass 2.7 and 2.9: what an event page shows. Pure and presentation only: never hashed, never logged.
## Tokens in page text and choice labels: {member:<n>} (the character at party position n, or EventResultText.empty_place when there is
## none) and {party} (every member's name, in slot order). Any other {...} is left as typed (the validator warns).
class_name EventText
extends RefCounted

const _MEMBER_PREFIX: String = "{member:"


## `text` with its tokens filled in from `run`'s party.
static func format(text: String, run: RunController) -> String:
	if not "{" in text or run == null or run.state == null:
		return text
	var result := text
	if "{party}" in result:
		var names := PackedStringArray()
		for slot in _slots(run):
			names.append(_name(run, slot))
		result = result.replace("{party}", ", ".join(names))
	var start := result.find(_MEMBER_PREFIX)
	while start >= 0:
		var close := result.find("}", start)
		if close < 0:
			break
		var number := result.substr(start + _MEMBER_PREFIX.length(), close - start - _MEMBER_PREFIX.length())
		if not number.is_valid_int():
			start = result.find(_MEMBER_PREFIX, close + 1)  # malformed: left as typed (the validator warns)
			continue
		var shown := _texts(run).empty_place
		if not run.state.member(number.to_int()).is_empty():
			shown = _name(run, number.to_int())
		result = result.substr(0, start) + shown + result.substr(close + 1)
		start = result.find(_MEMBER_PREFIX, start + shown.length())
	return result


## The text a page shows: `text` or one of its `text_variants`, picked by the run's seed, floor, event and page (stable for
## a run, so a resumed run reads the same; different from floor to floor), with its tokens filled in. Presentation only.
static func page_text(page: EventPage, run: RunController) -> String:
	if page == null:
		return ""
	var pool: Array[String] = [page.text]
	pool.append_array(page.text_variants.filter(func(variant: String) -> bool: return variant != ""))
	var text := page.text
	if pool.size() > 1 and run != null and run.state != null:
		var key := "%d|%d|%s|%d" % [run.state.run_seed, run.state.floor_index, str(run.state.event.get("event", "")),
			int(run.state.event.get("page", 0))]
		text = pool[absi(key.hash()) % pool.size()]
	return format(text, run)


## The tokens in `text` this formatter does not know (for the validator), e.g. ["{hero}"].
static func unknown_tokens(text: String) -> PackedStringArray:
	var unknown := PackedStringArray()
	var start := text.find("{")
	while start >= 0:
		var close := text.find("}", start)
		if close < 0:
			break
		var token := text.substr(start, close - start + 1)
		var known := token == "{party}"
		if token.begins_with(_MEMBER_PREFIX):
			known = token.substr(_MEMBER_PREFIX.length(), token.length() - _MEMBER_PREFIX.length() - 1).is_valid_int()
		if not known:
			unknown.append(token)
		start = text.find("{", close)
	return unknown


## Spec event-pass 2.9: the badge of a class choice: its `badge`, else the display names of the characters its
## HasCharacter conditions name (also inside AnyOf), joined by " / ". "" when it names none.
static func badge(choice: EventChoice) -> String:
	if choice == null:
		return ""
	if choice.badge != "":
		return choice.badge
	var names := PackedStringArray()
	for character in characters_named(choice.conditions):
		if not names.has(character.display_name):
			names.append(character.display_name)
	return " / ".join(names)


## The characters the HasCharacter conditions in `conditions` name, AnyOf included, in order.
static func characters_named(conditions: Array) -> Array[CharacterDefinition]:
	var result: Array[CharacterDefinition] = []
	for condition in conditions:
		if condition is HasCharacter and condition.character != null:
			result.append(condition.character)
		elif condition is AnyOf:
			result.append_array(characters_named(condition.conditions))
	return result


## The label a choice shows: "[badge] label" for a class choice (tag Choice.Class or a WHEN_MET choice with a badge),
## with its tokens filled in.
static func label(choice: EventChoice, run: RunController) -> String:
	var text := format(choice.label, run)
	var shown_badge := badge(choice)
	if shown_badge != "" and (choice.tags.has(EventScorer.CLASS_TAG) or choice.show == EventChoice.Show.WHEN_MET):
		return _texts(run).badge_format % [shown_badge, text]
	return text


## The run's text formats (screen texts are exports: EventResultText), or the defaults without a run.
static func _texts(run: RunController) -> EventResultText:
	return run.result_text if run != null and run.result_text != null else EventResultText.defaults()


static func _slots(run: RunController) -> Array:
	var slots: Array = run.state.party.map(func(member: Dictionary) -> int: return int(member["slot"]))
	slots.sort()  # sort-ok: party slots are ints
	return slots


static func _name(run: RunController, slot: int) -> String:
	var character: UnitDefinition = run.content.units.get(run.state.member(slot)["character"])
	return character.display_name if character != null else String(run.state.member(slot)["character"])
