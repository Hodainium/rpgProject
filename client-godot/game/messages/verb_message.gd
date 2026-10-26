## Spec gameplay-messages 3.1: who did what to whom, how much, with which tags (Lyra's FLyraVerbMessage).
## Ids are unit ids in a battle (P1, E2), member slots in a run (slot:2) or content ids (items, events, chapters).
class_name VerbMessage
extends GameplayMessage

## Verb.* (Verb.Break, Verb.Take…).
var verb: StringName
var instigator: StringName
var target: StringName
## ×100 when it is a number of the game (damage, prices are whole coins); a count or index otherwise.
var magnitude: int = 0
## Context tags: hit tags, item tags, an ultimate's ability tag.
var tags: Array[StringName] = []
## Small extras (display names, a reason). Read-only by convention.
var data: Dictionary = {}


static func make(verb_tag: StringName, instigator_id: StringName, target_id: StringName, amount: int = 0,
		context_tags: Array = [], extras: Dictionary = {}) -> VerbMessage:
	var message := VerbMessage.new()
	message.verb = verb_tag
	message.instigator = instigator_id
	message.target = target_id
	message.magnitude = amount
	message.tags.assign(context_tags)
	message.data = extras
	return message


## "Verb.Break P1→E2 0 [Hit.Weakness]"
func describe() -> String:
	var text := "%s %s→%s %d" % [verb, instigator, target, magnitude]
	if not tags.is_empty():
		text += " [%s]" % ", ".join(tags.map(func(tag) -> String: return String(tag)))
	return text
