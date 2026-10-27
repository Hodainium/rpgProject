## Spec keys-and-gear D7: every living member has at least this share of their max HP (typed %, e.g. 30). Pair it with
## an ApplyPartyEffect that deals the damage, so a choice that costs HP can't be picked by a party too hurt to pay.
@tool
class_name PartyHpAtLeast
extends RunCondition

@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var percent: float:
	get:
		return Fixed.to_display(percent_x100)
	set(typed):
		percent_x100 = Fixed.from_typed(typed)

@export_storage var percent_x100: int = 0


func holds(run: Object) -> bool:
	return run.party_hp_at_least(percent_x100)
