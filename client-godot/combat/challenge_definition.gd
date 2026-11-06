## A challenge (spec economy-challenges): a set of stars on one encounter. Winning the encounter earns tiers; the tier the
## replay reports is how many stars are satisfied IN A ROW from the first (stars are ordered, star 2 counts only when
## star 1 does), so a higher tier always includes the lower ones, which is what the server's ladder pays by.
## What each tier is worth is a server rule keyed by this `id` (a reward ladder); this resource carries no amounts.
@tool
class_name ChallengeDefinition
extends Resource

## The challenge id the server's reward ladder is keyed by: 1-200 characters, no ':' and no whitespace. Must not start with
## "boss/" (that namespace is the server's own, derived from a boss).
@export var id: StringName = &""
@export var display_name: String = ""
## The encounter this challenge is played on.
@export var encounter_id: StringName = &""
## Ordered stars: tier 1 is the first, tier 2 needs the first two, and so on.
@export var stars: Array[ChallengeStar] = []


## The tier `battle` reached: the leading run of satisfied stars (0 when the first fails, e.g. a lost battle).
func tier_for(battle: Battle) -> int:
	var tier := 0
	for star in stars:
		if star == null or not star.reached(battle):
			break
		tier += 1
	return tier
