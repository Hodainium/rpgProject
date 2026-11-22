## HUD panel (UI.Slot.Hud.Center while UI.State.Run.Event): the page text and its choices (action_button entries);
## choices whose conditions fail are disabled. The rest stop between floors gets `rest_title_format`.
## Spec event-pass 2.7, 2.9: {member:n} / {party} tokens are filled in (EventText), a WHEN_MET choice is listed only
## while its conditions hold (RunController.choice_shown; it keeps its index), and a class choice shows its badge
## ("[Cleric] ...") in the `class_variation` look.
extends UIScreen

@export var rest_title_format: String = "%s  ·  before floor %d"
## Theme type variation of a class choice's button (spec event-pass 2.9).
@export var class_variation: StringName = &"EventChoiceClass"


func bind(context: UIContext) -> void:
	for signal_name in [&"event_page_shown", &"party_changed"]:
		context.on_run(self, signal_name, func(_a = null, _b = null): queue_refresh())


func refresh() -> void:
	var run := ctx.run
	var event := run.current_event() if run != null and run.state != null else null
	var page := run.current_page() if event != null else null
	if page == null:
		return
	%Title.text = event.display_name
	if run.state.event.has("rest_to"):
		%Title.text = rest_title_format % [event.display_name, int(run.state.event["rest_to"]) + 1]
	%Text.text = EventText.page_text(page, run)  # its text or one of its variants (user, 2026-11-22)
	# Event results (user, 2026-11-22): what the choice that led here changed ("-5 coins", "Rations → Cleric").
	var result: Dictionary = run.last_event_result
	if not result.is_empty() and str(result.get("event", "")) == String(event.id) and not result["lines"].is_empty():
		%Text.text += "\n\n" + "\n".join(result["lines"])
	var choices: Array = []
	for index in page.choices.size():
		if not run.choice_shown(index):
			continue  # a WHEN_MET choice whose conditions fail; the others keep their own index
		var choice: EventChoice = page.choices[index]
		var item := {"text": EventText.label(choice, run), "disabled": not run.choice_enabled(index),
			"action": func(): run.choose(index)}
		if choice.tags.has(EventScorer.CLASS_TAG):
			item["variation"] = class_variation
		choices.append(item)
	%Choices.set_items(choices)
