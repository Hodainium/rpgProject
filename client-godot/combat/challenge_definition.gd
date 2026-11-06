## A challenge (spec economy-challenges): independent stars on one encounter. Each star is earned on its own, in any order:
## star 3 can be earned without star 2. A star is rewarded as a challenge of its own on the server, keyed by
## `reward_id(star)` = "<challenge id>.<star id>", with its own amount and cycle; the replay
## reports one completion per earned star. This resource carries no amounts.
@tool
class_name ChallengeDefinition
extends Resource

## The challenge's id: 1-200 characters, no ':' and no whitespace, and not starting with "boss/" (the server's own
## namespace). Star reward ids are this id, a dot and the star's id.
@export var id: StringName = &""
@export var display_name: String = ""
## The encounter this challenge is played on.
@export var encounter_id: StringName = &""
## The stars, each earned independently. Order does not matter (it is only the display order).
@export var stars: Array[ChallengeStar] = []


## The key of `star`'s reward on the server (the challenge id its ladder is set on).
func reward_id(star: ChallengeStar) -> String:
	return "%s.%s" % [id, star.id]


## The stars `battle` earned, in display order. A battle that was not won earns none.
func stars_reached(battle: Battle, tally: ChallengeTally = null) -> Array[ChallengeStar]:
	var earned: Array[ChallengeStar] = []
	for star in stars:
		if star != null and star.reached(battle, tally):
			earned.append(star)
	return earned
