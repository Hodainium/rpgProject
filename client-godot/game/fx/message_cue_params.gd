## A battle message as GameplayCue parameters (Lyra's ULyraVerbMessageHelpers::VerbMessageToCueParameters): the verb, who did it to whom, the
## magnitude and the tags travel in the cue's payload, so a cue notify can read what happened (an effect chosen by a tag, a brightness from
## the magnitude) with an `FxCueBinding`. Lyra's health set broadcasts a damage message after the effect has run, with the real magnitude and
## the captured source and target tags; a message that reaches a cue through this helper is the same data in the cue's own form.
## Presentation only.
class_name MessageCueParams
extends RefCounted


## {verb, instigator, target, magnitude (x100 for a number of the game), tags}.
static func from_message(message: GameplayMessage) -> Dictionary:
	if not message is VerbMessage:
		return {}
	return {"verb": message.verb, "instigator": message.instigator, "target": message.target, "magnitude": message.magnitude,
		"tags": message.tags.duplicate(), "data": message.data}
