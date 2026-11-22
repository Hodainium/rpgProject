## One choice on an event page. Shown disabled unless every condition holds; outcomes run in order.
## A choice whose outcomes neither go to a page nor start an encounter ends the event.
@tool
class_name EventChoice
extends Resource

@export var label: String = ""
@export var conditions: Array[RunCondition] = []
@export var outcomes: Array[RunOutcome] = []
## Spec event-pass 2.8: what the choice gives and costs (Choice.Gain.*, Choice.Cost.*, Choice.Fight, Choice.Gamble,
## Choice.Leave, Choice.Class). Read by the bots and analytics only; never by the run, never hashed.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var tags: Array[StringName] = []
## Spec event-pass 2.9: ALWAYS (a choice whose conditions fail is shown greyed out) or WHEN_MET (hidden until they hold,
## FTL's blue options). Display only: the choice keeps its index.
enum Show { ALWAYS, WHEN_MET }
@export var show: Show = Show.ALWAYS
## Spec event-pass 2.9: the label's badge, e.g. "Cleric". Empty: the characters its HasCharacter conditions name.
@export var badge: String = ""
