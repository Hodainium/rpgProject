## One page of an event.
@tool
class_name EventPage
extends Resource

@export_multiline var text: String = ""
## User, 2026-11-22: other ways to tell this page; each time it shows, one of `text` and these is picked (by the run's
## seed, floor and page, never a run stream), so a page seen every floor (the rest stop) reads differently. Presentation only.
@export_multiline var text_variants: Array[String] = []
@export var choices: Array[EventChoice] = []
## Event endings (user, 2026-11-22): run in order when a choice leads to this page (GoToPage or GoToRandomPage), inside
## the same logged choose, so a page can tell what happened and make it happen ("You win! He shoves 35 coins across").
## Not run for page 0 when the event opens. No page, random-page or fight directives here (the validator says so).
@export var on_enter: Array[RunOutcome] = []
