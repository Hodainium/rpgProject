## The tag checkpoint's removal rules (game/tools/sync_tags.gd): an explicit list or the unused tags may leave the registry; a tag the code
## or content uses, or that has a used tag under it, never does.
extends TestCase

const SyncTags := preload("res://game/tools/sync_tags.gd")


func test_unused_tags_may_be_removed_and_used_ones_may_not() -> void:
	var tags: Array = [&"Cue.Fx", &"Cue.Fx.Hit", &"Cue.Fx.Hit.Fire", &"Message.Battle.UnitRevived", &"Status.Debuff"]
	var used := {&"Cue.Fx.Hit.Fire": ["res://x.tres: cue"], &"Status.Debuff": ["code (system tag)"]}
	var plan: Dictionary = SyncTags.removal_plan(tags, used, [&"Message.Battle.UnitRevived", &"Cue.Fx.Hit.Fire", &"Cue.Fx.Hit", &"Not.There", &"Status.Debuff"])
	eq(plan["remove"], [&"Message.Battle.UnitRevived"], "only the unused tag leaves")
	var reasons := {}
	for entry in plan["refused"]:
		reasons[entry["tag"]] = entry["reason"]
	eq(reasons[&"Cue.Fx.Hit.Fire"], "STILL USED", "a tag in use stays")
	eq(reasons[&"Cue.Fx.Hit"], "STILL USED", "a tag with a used tag under it stays")
	eq(reasons[&"Not.There"], "NOT REGISTERED", "a tag that is not registered is reported")
	eq(reasons[&"Status.Debuff"], "STILL USED", "a tag the code uses stays")


func test_a_tag_is_removed_once_and_children_are_not_taken_with_it() -> void:
	var plan: Dictionary = SyncTags.removal_plan([&"A.B", &"A.B.C"], {}, [&"A.B", &"A.B"])
	eq(plan["remove"], [&"A.B"], "listed twice, removed once")
	check(not (plan["remove"] as Array).has(&"A.B.C"), "its child is a different tag and stays unless named")
