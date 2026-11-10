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


## Review fix: the effect listeners' tag fields are gas::tag fields, so the cues and channels a rule set names count as used
## (a cue only a listener executes was "unused" before, and --remove-unused would have taken it out of the registry).
func test_an_effect_listeners_tags_count_as_used() -> void:
	var checker: Node = SyncTags.new()
	var listener := FxListener.new()
	listener.channel = &"Message.Battle.Damage"
	listener.cue = &"Cue.Fx.Proc.Crit"
	listener.require_tags = [&"Hit.Critical"]
	listener.require_verb = &"Verb.Damage"
	checker._walk(listener, "res://x/rules.tres")
	for tag in [&"Message.Battle.Damage", &"Cue.Fx.Proc.Crit", &"Hit.Critical", &"Verb.Damage"]:
		check(checker._used.has(tag), "%s counts as used" % tag)
	checker.free()


## Review fix: a tag only the test fixtures use is protected: never reported unused, never removed.
func test_a_fixture_only_tag_is_protected_from_removal() -> void:
	var checker: Node = SyncTags.new()
	checker._into_protected = true
	checker._note(&"Fixture.Only", "res://tests/fixtures/x.tres: tag")
	checker._into_protected = false
	check(not checker._used.has(&"Fixture.Only") and checker._protected.has(&"Fixture.Only"), "noted as protected, not as used")
	var in_use: Dictionary = checker._used.duplicate()
	in_use.merge(checker._protected)
	var plan: Dictionary = SyncTags.removal_plan([&"Fixture.Only"], in_use, [&"Fixture.Only"])
	eq(plan["remove"], [], "a fixture-only tag is never removed")
	checker.free()
