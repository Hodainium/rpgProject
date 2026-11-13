## HUD panel (UI.Slot.Hud.Center while UI.State.Run.Event): the page text and its choices (action_button entries);
## choices whose conditions fail are disabled. The rest stop between floors gets `rest_title_format`.
extends UIScreen

@export var rest_title_format: String = "%s  ·  before floor %d"


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
	%Text.text = page.text
	var choices: Array = []
	for index in page.choices.size():
		choices.append({"text": page.choices[index].label, "disabled": not run.choice_enabled(index),
			"action": func(): run.choose(index)})
	%Choices.set_items(choices)
