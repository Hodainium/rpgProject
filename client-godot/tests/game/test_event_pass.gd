## Spec event-pass: the SLOT / LOWEST_HP / FLOOR recipients and on_floor armor, ApplyMemberEffect, RemoveItem by query,
## GoToRandomPage and the event's draw counter, the new conditions, WHEN_MET choices and EventText, party_grants at battle
## start, the bots' event choices (EventScorer), the run summary's event tally, RunWire's Other offers, the validator's
## new codes and the `event` console command. Events, effects and encounters are built in memory over the fixtures.
extends TestCase

const PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]

var _runs: Array[RunController] = []
var _battles_made: Array[Battle] = []


func after_each() -> void:
	for battle in _battles_made:
		if is_instance_valid(battle):
			battle.free()
	_battles_made.clear()
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


# --- Builders -------------------------------------------------------------------------------------------------------

func _item(name: String) -> ItemDefinition:
	return fixtures().items[StringName("fixture.item." + name)]


func _gift(item: ItemDefinition, recipient: int, slot: int = 1) -> GiveItem:
	var outcome := GiveItem.new()
	outcome.item = item
	outcome.recipient = recipient
	outcome.slot = slot
	return outcome


func _choice(label: String, outcomes: Array, tags: Array = [], conditions: Array = []) -> EventChoice:
	var choice := EventChoice.new()
	choice.label = label
	choice.outcomes.assign(outcomes)
	choice.tags.assign(tags)
	choice.conditions.assign(conditions)
	return choice


## An event: one page per entry of `pages` (each an Array of EventChoice).
func _event(id: String, pages: Array) -> EventDefinition:
	var event := EventDefinition.new()
	event.id = StringName(id)
	event.display_name = "The " + id.get_slice(".", 2)
	var built: Array[EventPage] = []
	for choices in pages:
		var page := EventPage.new()
		page.text = "a page"
		page.choices.assign(choices)
		built.append(page)
	event.pages = built
	return event


## An event with one choice running `outcomes` (ends the event).
func _simple(id: String, outcomes: Array) -> EventDefinition:
	return _event(id, [[_choice("do it", outcomes), _choice("leave", [], [&"Choice.Leave"])]])


func _run(resources: Array = [], seed_text: String = "7") -> RunController:
	var run := RunController.new()
	host.add_child(run)
	_runs.append(run)
	var error := run.start_run(fixtures().overlay(resources), PARTY, seed_text)
	check(error == "", "the run starts: " + error)
	run.event_results = true  # off headless by default (review fix); these tests check them
	return run


func _open(run: RunController, event: EventDefinition, cell: int = -2) -> void:
	run.state.event = {"cell": run.state.current_cell if cell == -2 else cell, "event": event.id, "page": 0}


## An HP change of `amount` (whole HP; stored x100) as an instant effect.
static func _hp_effect(amount: int) -> GameplayEffect:
	var modifier := CombatModifier.new()
	modifier.attribute_name = "hp"
	modifier.operation = GameplayEffectModifier.Operation.ADD
	modifier.value_x100 = amount * 100
	var effect := GameplayEffect.new()
	effect.modifiers.assign([modifier])
	return effect


static func _member_effect(effect: GameplayEffect, target: int, slot: int = 1,
		character: CharacterDefinition = null) -> ApplyMemberEffect:
	var outcome := ApplyMemberEffect.new()
	outcome.effect = effect
	outcome.target = target
	outcome.slot = slot
	outcome.character = character
	return outcome


static func _query(tag: StringName) -> GameplayTagQuery:
	var query := GameplayTagQuery.new()
	query.require_all_tags.assign([tag])
	return query


func _hp(run: RunController, slot: int) -> int:
	return int(run.state.member(slot)["hp"])


# --- 2.1 recipients ---------------------------------------------------------------------------------------------------

func test_slot_recipient_gives_to_that_place() -> void:
	var whetstone := _item("whetstone")
	var event := _simple("fixture.event.slot", [_gift(whetstone, GiveItem.Recipient.SLOT, 3)])
	var run := _run([event])
	_open(run, event)
	eq(run.choose(0), "", "choose")
	eq(run.state.holder_of(whetstone.id), 3, "the third in line holds it")


func test_slot_recipient_falls_back() -> void:
	var whetstone := _item("whetstone")
	var event := _simple("fixture.event.slot_dead", [_gift(whetstone, GiveItem.Recipient.SLOT, 2)])
	var run := _run([event])
	run.state.member(2)["alive"] = false
	run.state.member(2)["hp"] = 0
	_open(run, event)
	eq(run.choose(0), "", "choose")
	eq(run.state.holder_of(whetstone.id), 1, "a dead place: the first member who can hold it")
	check(Array(run.warnings).any(func(text: String) -> bool: return "party place 2" in text), "and it warns")
	var empty := _simple("fixture.event.slot_empty", [_gift(_item("satchel"), GiveItem.Recipient.SLOT, 4)])
	var other := _run([empty])
	_open(other, empty)
	eq(other.choose(0), "", "choose")
	eq(other.state.holder_of(&"fixture.item.satchel"), 1, "an empty place (a party of 3): the first member")


func test_lowest_hp_recipient() -> void:
	var whetstone := _item("whetstone")
	var event := _simple("fixture.event.lowest", [_gift(whetstone, GiveItem.Recipient.LOWEST_HP)])
	var run := _run([event])
	run.apply_member_effect(_hp_effect(-30), [3], false)
	_open(run, event)
	eq(run.choose(0), "", "choose")
	eq(run.state.holder_of(whetstone.id), 3, "the hurt member gets it")


func test_floor_recipient_lands_in_room() -> void:
	var whetstone := _item("whetstone")
	var event := _simple("fixture.event.found", [_gift(whetstone, GiveItem.Recipient.FLOOR)])
	var run := _run([event])
	var cell := run.state.current_cell
	_open(run, event)
	eq(run.choose(0), "", "choose")
	eq(run.state.holder_of(whetstone.id), 0, "nobody holds it yet")
	var drops := run.drop_pickups(cell)
	eq(drops.size(), 1, "one pickup on the floor")
	eq(String(drops[0]["item"]), String(whetstone.id), "the item")
	eq(str(drops[0]["found"]), "fixture.event.found", "it carries the event")
	eq(run.drop_source_name(cell, drops[0]), "The found", "its source is the event's name")
	check(run.state.seen_items.has(whetstone.id), "it is seen once it lands")
	var entry: Dictionary = run.run_log[-1]
	eq(entry["found"], [int(drops[0]["placement"])], "the choose remembers what it put out")
	var wire := RunWire.action(run, entry, {})
	eq(wire["offers"].size(), 1, "the choose action carries the offer")
	eq(wire["offers"][0]["source"], "Other", "as an Other offer")
	eq(run.take(int(drops[0]["placement"]), 2), "", "taken like any pickup")
	eq(run.state.holder_of(whetstone.id), 2, "by the member picked")


func test_floor_outside_a_room_gives_directly() -> void:
	var whetstone := _item("whetstone")
	var run := _run()
	run.give_item(whetstone, null, null, GiveItem.Recipient.FLOOR)
	eq(run.state.holder_of(whetstone.id), 1, "no event room: the first member")
	check(Array(run.warnings).any(func(text: String) -> bool: return "FLOOR outside a room" in text), "and it warns")


func test_on_floor_equipment() -> void:
	var piece: EquipmentDefinition = fixtures().equipment.values()[0]
	var outcome := GiveEquipment.new()
	outcome.equipment = piece
	outcome.on_floor = true
	var event := _simple("fixture.event.armor", [outcome])
	var run := _run([event])
	_open(run, event)
	eq(run.choose(0), "", "choose")
	check(not run.state.armor.has(piece.id), "not in the armor inventory")
	eq(run.drop_pickups(run.state.current_cell).size(), 1, "on the floor instead")


## User, 2026-11-21: GiveEquipment.only_slot keeps a query to one equipment slot (a weapon rack gives a weapon).
func test_only_slot_picks_that_slot() -> void:
	var run := _run()
	var slots := {}
	for piece in fixtures().equipment.values():
		if not piece.tags.is_empty():
			slots[piece.slot] = true
	check(slots.size() >= 2, "the fixtures pool pieces for several slots: %s" % [slots.keys()])
	var wanted: StringName = slots.keys()[0]
	var generator := FloorGenerator.new(run.content, run.structure, run.state.run_seed, 0, run.state.seeds())
	for time in 6:
		var piece := generator.pick_equipment(null, RunSeeds.rng(time, "only_slot"), {}, [], wanted)
		check(piece != null, "a piece for %s" % wanted)
		if piece != null:
			eq(piece.slot, wanted, "only pieces for %s" % wanted)


# --- 2.2 outcomes -----------------------------------------------------------------------------------------------------

func test_member_effect_targets() -> void:
	var hurt := _hp_effect(-10)
	var medic: CharacterDefinition = fixtures().units[&"fixture.character.medic"]
	var cases := [[ApplyMemberEffect.Target.FIRST, 1, [1]], [ApplyMemberEffect.Target.SLOT, 2, [2]],
		[ApplyMemberEffect.Target.CHARACTER, 1, [2]], [ApplyMemberEffect.Target.ALL, 1, [1, 2, 3]]]
	for case in cases:
		var event := _simple("fixture.event.hurt%d" % case[0], [_member_effect(hurt, case[0], case[1], medic)])
		var run := _run([event])
		var before := [_hp(run, 1), _hp(run, 2), _hp(run, 3)]
		_open(run, event)
		eq(run.choose(0), "", "choose")
		var hit: Array = []
		for slot in [1, 2, 3]:
			if _hp(run, slot) < before[slot - 1]:
				hit.append(slot)
		eq(hit, case[2], "target %d hits %s" % [case[0], case[2]])


func test_member_effect_lowest_and_random() -> void:
	var hurt := _hp_effect(-5)
	var lowest := _simple("fixture.event.lowest_hurt", [_member_effect(hurt, ApplyMemberEffect.Target.LOWEST_HP)])
	var run := _run([lowest])
	run.apply_member_effect(_hp_effect(-30), [2], false)
	var before := _hp(run, 2)
	_open(run, lowest)
	eq(run.choose(0), "", "choose")
	eq(_hp(run, 2), before - 500, "the lowest HP share is hit")
	var random := _simple("fixture.event.random_hurt", [_member_effect(hurt, ApplyMemberEffect.Target.RANDOM)])
	var picks: Array = []
	for attempt in 2:
		var again := _run([random])
		var start := [_hp(again, 1), _hp(again, 2), _hp(again, 3)]
		_open(again, random)
		eq(again.choose(0), "", "choose")
		for slot in [1, 2, 3]:
			if _hp(again, slot) < start[slot - 1]:
				picks.append(slot)
	eq(picks.size(), 2, "one member each time")
	eq(picks[0], picks[1], "the same seed picks the same member")


func test_event_slay_marks_dead_and_wipe_loses() -> void:
	var slay := RunController.dev_effect("dev_kill")
	check(slay != null, "the dev kill effect exists")
	var one := _simple("fixture.event.slay", [_member_effect(slay, ApplyMemberEffect.Target.SLOT, 3)])
	var run := _run([one])
	_open(run, one)
	eq(run.choose(0), "", "choose")
	check(not run.state.member(3)["alive"], "the third in line is dead")
	eq(run.state.status, RunState.ACTIVE, "the run goes on")
	eq(int(run.run_summary().get("eventMemberDeaths", 0)), 1, "the summary counts the death")
	var all := _simple("fixture.event.wipe", [_member_effect(slay, ApplyMemberEffect.Target.ALL)])
	var wiped := _run([all])
	_open(wiped, all)
	wiped.choose(0)
	eq(wiped.state.status, RunState.LOST, "a wipe loses the run")


func test_remove_by_query() -> void:
	var whetstone := _item("whetstone")
	var remove := RemoveItem.new()
	remove.item_query = _query(&"Fixture.Pool.Treasure")
	remove.from = RemoveItem.From.SLOT
	remove.slot = 2
	var event := _simple("fixture.event.thief", [remove])
	var run := _run([event])
	run.give_item(whetstone, null, null, GiveItem.Recipient.SLOT, 2)
	eq(run.held_items_matching(remove.item_query).size(), 1, "the member holds one treasure")
	_open(run, event)
	eq(run.choose(0), "", "choose")
	eq(run.state.holder_of(whetstone.id), 0, "it is gone")
	var nothing := _run([event])
	_open(nothing, event)
	var before := nothing.state.run_hash()
	eq(nothing.choose(0), "", "nothing to remove is no error")
	check(nothing.state.event.is_empty(), "the event ended")
	check(before != "", "a hash to compare")


func test_random_page_and_the_draw_counter() -> void:
	var gamble := GoToRandomPage.new()
	gamble.pages.assign([1, 2])
	gamble.weights_x100.assign([5000, 5000])
	var again := GoToRandomPage.new()
	again.pages.assign([1, 2])
	again.weights_x100.assign([5000, 5000])
	var event := _event("fixture.event.gamble", [[_choice("bet", [gamble], [&"Choice.Gamble"])],
		[_choice("again", [again], [&"Choice.Gamble"]), _choice("stop", [], [&"Choice.Leave"])],
		[_choice("again", [again], [&"Choice.Gamble"]), _choice("stop", [], [&"Choice.Leave"])]])
	var seen := {}
	var sequences: Array = []
	for attempt in 2:
		var run := _run([event])
		_open(run, event)
		var pages: Array = []
		eq(run.choose(0), "", "bet")
		pages.append(int(run.state.event["page"]))
		for time in 7:
			eq(run.choose(0), "", "again")
			pages.append(int(run.state.event["page"]))
		eq(int(run.state.event["draws"]), 8, "every draw counted in the event")
		for page in pages:
			seen[page] = true
		sequences.append(pages)
	eq(sequences[0], sequences[1], "the same seed draws the same pages")
	check(seen.has(1) and seen.has(2), "a looping choice draws anew each time: %s" % [sequences[0]])


func test_event_draws_survive_restore() -> void:
	var gamble := GoToRandomPage.new()
	gamble.pages.assign([0, 1])
	gamble.weights_x100.assign([5000, 5000])
	var event := _event("fixture.event.loop", [[_choice("throw", [gamble], [&"Choice.Gamble"])],
		[_choice("throw", [gamble], [&"Choice.Gamble"])]])
	var run := _run([event])
	_open(run, event)
	for time in 3:
		run.choose(0)
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(RunSnapshot.capture(run)))
	var restored := RunController.new()
	host.add_child(restored)
	_runs.append(restored)
	eq(RunSnapshot.restore(restored, run.content, saved), "", "the snapshot restores")
	check(restored.state.event["draws"] is int, "draws is an int again")
	eq(restored.state.run_hash(), run.state.run_hash(), "the same run hash")
	run.choose(0)
	restored.choose(0)
	eq(restored.state.run_hash(), run.state.run_hash(), "the next draw is the same")


func test_random_gifts_draw_anew_on_a_looping_page() -> void:
	var gift := _gift(_item("crumb"), GiveItem.Recipient.RANDOM)
	var stay := GoToPage.new()
	stay.page = 0
	var event := _event("fixture.event.loop_gift", [[_choice("again", [gift, stay], [&"Choice.Gain.Item"])]])
	var run := _run([event])
	_open(run, event)
	eq(run.choose(0), "", "the first pass")
	eq(int(run.state.event["recipient_draws"]), 1, "the event remembers its gift draws")
	var holders := {}
	for time in 10:
		eq(run.choose(0), "", "again")
	for member in run.state.party:
		if member["items"].has(&"fixture.item.crumb"):
			holders[member["slot"]] = true
	check(holders.size() >= 2, "the gifts went to different members: %s" % [holders.keys()])


func test_event_command_only_in_event_or_empty_rooms() -> void:
	var event := _simple("fixture.event.cheat", [GainCoins.new()])
	var run := _run([event])
	for index in run.state.map.sorted_indices():
		if str(run.state.map.cells[index]["content"].get("kind", "")) == "encounter":
			run.state.current_cell = index
			break
	eq(run.dev_open_event(event), "only in an event room or a room with nothing in it (a battle room would roll its loot again)",
		"refused in a battle room")


## Review fix: a RANDOM gift outside an event (an item hook after a take) draws from the floor's saved gift counter, so a
## run resumed between two such gifts picks the same members.
func test_random_gift_outside_an_event_survives_restore() -> void:
	var run := _run()
	run.give_item(_item("crumb"), null, null, GiveItem.Recipient.RANDOM)
	var counter := run.state.gifts_on_floor
	check(counter > 0, "the floor's gift counter moved (hashed and saved)")
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(RunSnapshot.capture(run)))
	var restored := RunController.new()
	host.add_child(restored)
	_runs.append(restored)
	eq(RunSnapshot.restore(restored, run.content, saved), "", "the snapshot restores")
	run.give_item(_item("whetstone"), null, null, GiveItem.Recipient.RANDOM)
	restored.give_item(_item("whetstone"), null, null, GiveItem.Recipient.RANDOM)
	eq(restored.state.holder_of(&"fixture.item.whetstone"), run.state.holder_of(&"fixture.item.whetstone"),
		"the next RANDOM gift goes to the same member")
	eq(restored.state.run_hash(), run.state.run_hash(), "the same run hash")


func test_an_event_without_draws_hashes_as_before() -> void:
	var event := _simple("fixture.event.plain", [GainCoins.new()])
	var run := _run([event])
	_open(run, event)
	check(not run.state.event.has("draws"), "no draw counter until a draw happens")


# --- Event results (user, 2026-11-22) ---------------------------------------------------------------------------------

func test_event_result_says_what_a_choice_changed() -> void:
	var keys := GainKeys.new()
	keys.amount = 2
	var coins := GainCoins.new()
	coins.amount = 7
	var choice := _choice("drink", [keys, coins, _gift(_item("whetstone"), GiveItem.Recipient.SLOT, 2),
		_member_effect(_hp_effect(-20), ApplyMemberEffect.Target.SLOT, 3)], [&"Choice.Gain.Keys"])
	var event := _event("fixture.event.receipt", [[choice, _choice("leave", [], [&"Choice.Leave"])]])
	var run := _run([event])
	var heard: Array = []
	run.event_resolved.connect(func(result: Dictionary): heard.append(result))
	_open(run, event)
	eq(run.choose(0), "", "choose")
	eq(heard.size(), 1, "a choice that ends its event without an ending page falls back to the result dialog")
	var result: Dictionary = heard[0]
	eq(result["title"], event.display_name, "titled by the event")
	var medic: String = fixtures().units[&"fixture.character.medic"].display_name
	var rogue: String = fixtures().units[&"fixture.character.rogue"].display_name
	var lines := Array(result["lines"])
	for line in ["+7 coins", "+2 keys", "%s got %s" % [medic, _item("whetstone").display_name]]:
		check(lines.has(line), "it lists '%s': %s" % [line, lines])
	var hp := lines.find(lines.filter(func(line: String) -> bool: return line.begins_with(rogue + " lost"))[0]) 		if lines.any(func(line: String) -> bool: return line.begins_with(rogue + " lost")) else -1
	check(hp >= 0, "and the HP lost: %s" % [lines])
	check(hp < lines.find("%s got %s" % [medic, _item("whetstone").display_name]), "HP first, then what members got")
	check(lines.find("+7 coins") > lines.find("%s got %s" % [medic, _item("whetstone").display_name]), "coins and keys last")


## User, 2026-11-22: when the whole party is hurt alike the result says so in one line, above what anyone got.
func test_event_result_groups_the_party() -> void:
	var hurt := ApplyPartyEffect.new()
	hurt.effect = _hp_effect(-10)
	var event := _event("fixture.event.receipt_party", [[_choice("offer", [hurt, _gift(_item("whetstone"),
		GiveItem.Recipient.SLOT, 1)], [&"Choice.Cost.Hp"])]])
	var run := _run([event])
	for slot in [1, 2, 3]:  # same max HP share loss for all: give everyone the same max HP
		run.state.member(slot)["hp"] = int(run.state.member(slot)["hp"])
	var heard: Array = []
	run.event_resolved.connect(func(result: Dictionary): heard.append(result))
	_open(run, event)
	eq(run.choose(0), "", "choose")
	var lines := Array(heard[0]["lines"])
	var party_lines := lines.filter(func(line: String) -> bool: return line.contains("HP"))
	check(not party_lines.is_empty(), "HP lines: %s" % [lines])
	var last_hp := lines.find(party_lines[-1])
	var got := lines.find("%s got %s" % [fixtures().units[&"fixture.character.knight"].display_name, _item("whetstone").display_name])
	check(got > last_hp, "every HP line comes before what a member got: %s" % [lines])


func test_event_result_on_the_next_page_and_none_for_leave() -> void:
	var pay := LoseCoins.new()
	pay.amount = 3
	var event := _event("fixture.event.receipt_page", [[_choice("bet", [pay, _go(1)], [&"Choice.Cost.Coins"]),
		_choice("leave", [], [&"Choice.Leave"])], [_choice("walk away", [], [&"Choice.Leave"])]])
	var run := _run([event])
	run.state.coins = 10
	var heard: Array = []
	run.event_resolved.connect(func(result: Dictionary): heard.append(result))
	_open(run, event)
	eq(run.choose(0), "", "bet")
	eq(heard.size(), 0, "no dialog while the event goes on")
	eq(Array(run.last_event_result["lines"]), ["-3 coins"], "the next page shows what the bet changed")
	eq(run.choose(0), "", "walk away")
	eq(heard.size(), 0, "leaving with nothing changed reports nothing")


func test_gain_keys_toasts() -> void:
	var run := _run()
	var heard: Array = []
	var handle := GameplayMessages.listen(GameplayMessageRouter.RUN_KEY_FOUND, func(_channel: StringName, message: VerbMessage):
		heard.append(message.magnitude), GameplayMessageRouter.Match.EXACT, VerbMessage)
	var keys := GainKeys.new()
	keys.amount = 2
	keys.apply(run)
	handle.unregister()
	eq(heard, [2], "an outcome's keys send the key-found toast")


## Event endings (user, 2026-11-22): a page's on_enter outcomes run when a choice leads there, once, and the page
## lists what changed under its story; its Continue then ends the event with no dialog.
func test_ending_page_runs_its_outcomes() -> void:
	var keys := GainKeys.new()
	keys.amount = 2
	var ending := EventPage.new()
	ending.text = "The watchman snores; the party lifts his keys."
	ending.choices.assign([_choice("Continue", [], [&"Choice.Leave"])])
	var on_enter: Array[RunOutcome] = [keys]
	ending.on_enter = on_enter
	var start := EventPage.new()
	start.text = "A watchman sleeps."
	start.choices.assign([_choice("drink with him", [_go(1)], [&"Choice.Gain.Keys"])])
	var event := EventDefinition.new()
	event.id = &"fixture.event.ending"
	event.display_name = "Watchman"
	event.pages.assign([start, ending])
	var run := _run([event])
	var heard: Array = []
	run.event_resolved.connect(func(result: Dictionary): heard.append(result))
	_open(run, event)
	var before := run.state.keys
	eq(run.choose(0), "", "choose")
	eq(int(run.state.event["page"]), 1, "on the ending page")
	eq(run.state.keys, before + 2, "its outcomes ran")
	eq(Array(run.last_event_result["lines"]), ["+2 keys"], "and it lists what changed")
	eq(run.choose(0), "", "Continue")
	eq(run.state.keys, before + 2, "nothing ran twice")
	eq(heard.size(), 0, "an ending page needs no dialog")


func test_ending_page_with_a_chosen_gift_runs_once() -> void:
	var gift := _gift(_item("whetstone"), GiveItem.Recipient.CHOOSE)
	var coins := GainCoins.new()
	coins.amount = 5
	var ending := EventPage.new()
	ending.text = "A gift, and coins."
	ending.choices.assign([_choice("Continue", [], [&"Choice.Leave"])])
	var on_enter: Array[RunOutcome] = [coins, gift]
	ending.on_enter = on_enter
	var start := EventPage.new()
	start.text = "Take it?"
	start.choices.assign([_choice("take", [_go(1)], [&"Choice.Gain.Item"])])
	var event := EventDefinition.new()
	event.id = &"fixture.event.ending_gift"
	event.display_name = "Gift"
	event.pages.assign([start, ending])
	var run := _run([event])
	_open(run, event)
	var coins_before := run.state.coins
	eq(run.choose(0), "", "choose")
	eq(run.state.pending_gifts.size(), 1, "the gift waits for its holder")
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(RunSnapshot.capture(run)))
	var restored := RunController.new()
	host.add_child(restored)
	_runs.append(restored)
	eq(RunSnapshot.restore(restored, run.content, saved), "", "a save made while it waits restores")
	for runner in [run, restored]:
		eq(runner.give_to(2), "", "give it")
		eq(runner.state.coins, coins_before + 5, "the page's coins were given once")
		eq(int(runner.state.event["page"]), 1, "still on the ending page")
	eq(restored.state.run_hash(), run.state.run_hash(), "the restored run matches")


## Review fix: a FLOOR gift an ending page gives travels with the choose as an Other offer.
func test_ending_page_floor_gift_is_uploaded() -> void:
	var ending := EventPage.new()
	ending.text = "Someone left in a hurry."
	ending.choices.assign([_choice("Continue", [], [&"Choice.Leave"])])
	var on_enter: Array[RunOutcome] = [_gift(_item("whetstone"), GiveItem.Recipient.FLOOR)]
	ending.on_enter = on_enter
	var start := EventPage.new()
	start.text = "A pack."
	start.choices.assign([_choice("search", [_go(1)], [&"Choice.Gain.Item"])])
	var event := EventDefinition.new()
	event.id = &"fixture.event.pack"
	event.display_name = "Pack"
	event.pages.assign([start, ending])
	var run := _run([event])
	_open(run, event)
	eq(run.choose(0), "", "search")
	var entry: Dictionary = run.run_log[-1]
	eq(entry["type"], "choose", "the choose is the last log entry")
	eq(entry.get("found", []).size(), 1, "the ending page's floor gift is on the choose")
	var wire := RunWire.action(run, entry, {})
	eq(wire["offers"].size(), 1, "and uploads as an offer")
	eq(wire["offers"][0]["source"], "Other", "an Other offer")


## Review fix: a RANDOM gift an ending page gives, after a chosen gift waited, draws the same member in a run resumed
## from a save made while the gift waited.
func test_ending_page_random_gift_after_a_wait_survives_restore() -> void:
	var ending := EventPage.new()
	ending.text = "And one more, for someone."
	ending.choices.assign([_choice("Continue", [], [&"Choice.Leave"])])
	var on_enter: Array[RunOutcome] = [_gift(_item("crumb"), GiveItem.Recipient.RANDOM)]
	ending.on_enter = on_enter
	var start := EventPage.new()
	start.text = "Gifts."
	start.choices.assign([_choice("take", [_gift(_item("crumb"), GiveItem.Recipient.RANDOM),
		_gift(_item("whetstone"), GiveItem.Recipient.CHOOSE), _go(1)], [&"Choice.Gain.Item"])])
	var event := EventDefinition.new()
	event.id = &"fixture.event.gifts"
	event.display_name = "Gifts"
	event.pages.assign([start, ending])
	var run := _run([event])
	_open(run, event)
	eq(run.choose(0), "", "take")
	eq(run.state.pending_gifts.size(), 1, "the chosen gift waits")
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(RunSnapshot.capture(run)))
	var restored := RunController.new()
	host.add_child(restored)
	_runs.append(restored)
	eq(RunSnapshot.restore(restored, run.content, saved), "", "a save made while it waits restores")
	eq(run.give_to(2), "", "give it (live)")
	eq(restored.give_to(2), "", "give it (resumed)")
	eq(restored.state.run_hash(), run.state.run_hash(), "the ending page's RANDOM gift went to the same member")


## Review fix: an on_floor armor gift whose pool is empty puts the fallback item on the floor too.
func test_on_floor_fallback_lands_on_the_floor() -> void:
	var outcome := GiveEquipment.new()
	outcome.query = _query(&"Fixture.Nothing.Matches")
	outcome.on_floor = true
	var event := _simple("fixture.event.empty_rack", [outcome])
	var run := _run([event])
	if run.structure == null or run.structure.fallback_item == null:
		return
	_open(run, event)
	var held_before := run.state.held_items().size()
	eq(run.choose(0), "", "choose")
	eq(run.state.held_items().size(), held_before, "nobody was handed the fallback item")
	eq(run.drop_pickups(run.state.current_cell).size(), 1, "it lies on the floor")


## Review fix: two copies of one thing make one line with the count, never the same line twice.
func test_event_result_counts_copies_once() -> void:
	var piece: EquipmentDefinition = fixtures().equipment.values()[0]
	var first := GiveEquipment.new()
	first.equipment = piece
	var second := GiveEquipment.new()
	second.equipment = piece
	var event := _simple("fixture.event.two_pieces", [first, second])
	var run := _run([event])
	var heard: Array = []
	run.event_resolved.connect(func(result: Dictionary): heard.append(result))
	_open(run, event)
	eq(run.choose(0), "", "choose")
	var lines := Array(heard[0]["lines"])
	var armor_lines := lines.filter(func(line: String) -> bool: return line.contains(piece.display_name))
	eq(armor_lines, [run.result_text.to_armor % (piece.display_name + " x2")], "one line with the count: %s" % [lines])


func test_ending_validator_codes() -> void:
	var ends := _event("fixture.event.no_ending", [[_choice("take", [GainCoins.new()], [&"Choice.Gain.Coins"])]])
	check(_codes([ends]).has("event_ending_missing"), "event_ending_missing")
	var start := StartEncounter.new()
	start.encounter = fixtures().encounters[&"fixture.encounter.lone"]
	var fights := _event("fixture.event.no_intro", [[_choice("fight", [start], [&"Choice.Fight"])]])
	check(_codes([fights]).has("fight_without_intro"), "fight_without_intro")
	var bad := EventPage.new()
	bad.text = "x"
	bad.choices.assign([_choice("Continue", [], [&"Choice.Leave"])])
	var entered: Array[RunOutcome] = [_go(0)]
	bad.on_enter = entered
	var directive := EventDefinition.new()
	directive.id = &"fixture.event.page_directive"
	directive.pages.assign([_event("fixture.event.tmp", [[_choice("go", [_go(1)], [&"Choice.Leave"])]]).pages[0], bad])
	check(_codes([directive]).has("page_outcome_directive"), "page_outcome_directive")
	var first := EventPage.new()
	first.text = "x"
	first.choices.assign([_choice("go", [_go(1)], [&"Choice.Leave"])])
	var first_entered: Array[RunOutcome] = [GainCoins.new()]
	first.on_enter = first_entered
	var page_one := EventPage.new()
	page_one.text = "y"
	page_one.choices.assign([_choice("Continue", [], [&"Choice.Leave"])])
	var opening := EventDefinition.new()
	opening.id = &"fixture.event.first_on_enter"
	opening.pages.assign([first, page_one])
	check(_codes([opening]).has("on_enter_first_page"), "on_enter_first_page")


static func _go(page: int) -> GoToPage:
	var outcome := GoToPage.new()
	outcome.page = page
	return outcome


# --- 2.3 conditions ---------------------------------------------------------------------------------------------------

func test_conditions() -> void:
	var run := _run()
	var member := MemberAt.new()
	member.slot = 3
	check(member.holds(run), "place 3 holds a living member")
	member.slot = 4
	check(not member.holds(run), "place 4 is empty")
	member.slot = 2
	member.hp_at_least_x100 = 9000
	check(member.holds(run), "full HP is at least 90%")
	run.apply_member_effect(_hp_effect(-1000000), [2], false)
	check(not member.holds(run), "a dead member fails alive_only")
	var deep := FloorAtLeast.new()
	deep.min_floor = 1
	check(deep.holds(run), "floor 1 counts from 1")
	deep.min_floor = 2
	check(not deep.holds(run), "not on floor 2 yet")
	var holds := HoldsItemTag.new()
	holds.query = _query(&"Fixture.Pool.Treasure")
	check(not holds.holds(run), "nobody holds a treasure")
	run.give_item(_item("whetstone"), null, null, GiveItem.Recipient.SLOT, 3)
	check(holds.holds(run), "now someone does")
	holds.slot = 1
	check(not holds.holds(run), "but not the first in line")
	var any := AnyOf.new()
	any.conditions.assign([deep, holds])
	check(not any.holds(run), "AnyOf: neither holds")
	holds.slot = 3
	check(any.holds(run), "AnyOf: one holds")
	var never := NotCondition.new()
	never.condition = holds
	check(not never.holds(run), "NotCondition flips it")
	check(NotCondition.new().holds(run), "an empty NotCondition holds")


# --- 2.9 class choices, EventText -------------------------------------------------------------------------------------

func _class_choice(character: String) -> EventChoice:
	var has := HasCharacter.new()
	has.character = fixtures().units[StringName("fixture.character." + character)]
	var choice := _choice("Bless the dice", [GainCoins.new()], [&"Choice.Class", &"Choice.Gain.Coins"], [has])
	choice.show = EventChoice.Show.WHEN_MET
	return choice


func test_class_choice_hidden_unless_met() -> void:
	var shown := _class_choice("medic")
	var hidden := _class_choice("cantor")
	var event := _event("fixture.event.class", [[_choice("plain", [], [&"Choice.Leave"]), hidden, shown]])
	var run := _run([event])
	_open(run, event)
	check(run.choice_shown(0), "an ALWAYS choice shows")
	check(not run.choice_shown(1), "a class choice for a class not in the party is hidden")
	check(run.choice_shown(2), "one for a class in it shows")
	eq(EventText.label(shown, run), "[%s] Bless the dice" % fixtures().units[&"fixture.character.medic"].display_name,
		"with its badge")
	run.state.member(run.state.member_slot(&"fixture.character.medic"))["alive"] = false
	check(not run.choice_shown(2), "a dead member hides it")
	run.state.member(2)["alive"] = true
	eq(run.choose(2), "", "it keeps its index: choose(2) runs it")
	eq(run.run_log[-1]["choice"], 2, "and the log says 2")


func test_event_text() -> void:
	var run := _run()
	var knight: String = fixtures().units[&"fixture.character.knight"].display_name
	eq(EventText.format("{member:1} drinks", run), knight + " drinks", "a member token")
	eq(EventText.format("{member:4} waits", run), run.result_text.empty_place + " waits", "an empty place")
	check(EventText.format("{party}", run).begins_with(knight + ", "), "the party token")
	eq(EventText.unknown_tokens("{member:2} and {hero} and {member:x}"), PackedStringArray(["{hero}", "{member:x}"]),
		"unknown tokens")
	eq(EventText.format("{member:x} waits", run), "{member:x} waits", "a malformed token is left as typed")
	var choice := _class_choice("medic")
	choice.badge = "Healer"
	eq(EventText.badge(choice), "Healer", "the badge override")
	var any := AnyOf.new()
	var first := HasCharacter.new()
	first.character = fixtures().units[&"fixture.character.knight"]
	var second := HasCharacter.new()
	second.character = fixtures().units[&"fixture.character.rogue"]
	any.conditions.assign([first, second])
	var both := _choice("Burn it", [], [&"Choice.Class"], [any])
	eq(EventText.badge(both), "%s / %s" % [knight, fixtures().units[&"fixture.character.rogue"].display_name],
		"several characters")


## User, 2026-11-22: a page with text_variants shows one of them: the same one for the same run, floor and page, and
## across floors more than one (a rest stop reads differently each time). Tokens are filled in.
func test_page_text_variants() -> void:
	var page := EventPage.new()
	page.text = "A"
	var variants: Array[String] = ["B", "C", "D {member:1}"]
	page.text_variants = variants
	var run := _run()
	run.state.event = {"cell": run.state.current_cell, "event": &"fixture.event.rest", "page": 1}
	var first := EventText.page_text(page, run)
	eq(EventText.page_text(page, run), first, "the same run, floor and page show the same text")
	var seen := {}
	for floor in 12:
		run.state.floor_index = floor
		seen[EventText.page_text(page, run)] = true
	check(seen.size() >= 2, "different floors show different texts: %s" % [seen.keys()])
	var knight: String = fixtures().units[&"fixture.character.knight"].display_name
	for text in seen:
		check(text in ["A", "B", "C", "D " + knight], "every pick is one of the page's texts, tokens filled: %s" % text)
	page.text_variants = []
	eq(EventText.page_text(page, run), "A", "no variants: the text")


# --- 2.4 party_grants -------------------------------------------------------------------------------------------------

func test_party_grants_apply_at_battle_start() -> void:
	var base: EncounterDefinition = fixtures().encounters[&"fixture.encounter.lone"]
	var granted := base.duplicate() as EncounterDefinition
	granted.id = &"fixture.encounter.lone_ambush"
	var event_tags: Array[StringName] = [&"Encounter.Event"]
	granted.tags = event_tags  # a new array: the duplicate shares the fixture's
	var grants := AbilitySet.new()
	grants.tags.assign([&"Weakness.Fire"])
	granted.party_grants = grants
	var start := StartEncounter.new()
	start.encounter = granted
	var event := _simple("fixture.event.ambush", [start])
	var run := _run([granted, event])
	_open(run, event)
	eq(run.choose(0), "", "choose")
	check(not run.pending_battle.is_empty(), "the fight is pending")
	var snapshot := run.battle_snapshot()
	var battle := Battle.new()
	host.add_child(battle)
	_battles_made.append(battle)
	eq(battle.setup(snapshot, run.content), "", "the battle builds")
	check(battle.unit_by_id(&"P1").asc.has_tag(&"Weakness.Fire"), "a party member got the grant")
	check(not battle.unit_by_id(&"E1").asc.has_tag(&"Weakness.Fire"), "an enemy did not")


## F5: party_grants are rebuilt from content by the encounter id, so the verifier's replay of such a battle matches the
## client's; replayed where the encounter has no party_grants, the same log does not.
func test_party_grants_replay() -> void:
	var base: EncounterDefinition = fixtures().encounters[&"fixture.encounter.lone"]
	var granted := base.duplicate() as EncounterDefinition
	granted.id = &"fixture.encounter.lone_hasted"
	var event_tags: Array[StringName] = [&"Encounter.Event"]
	granted.tags = event_tags
	var grants := AbilitySet.new()
	grants.effects.assign([load("res://tests/fixtures/effects/haste.tres")])
	granted.party_grants = grants
	var start := StartEncounter.new()
	start.encounter = granted
	var event := _simple("fixture.event.hasted", [start])
	var run := _run([granted, event])
	_open(run, event)
	eq(run.choose(0), "", "choose")
	var snapshot: Dictionary = JSON.parse_string(WireJson.stringify(run.battle_snapshot()))
	var battle := Battle.new()
	host.add_child(battle)
	_battles_made.append(battle)
	eq(battle.setup(snapshot, run.content), "", "the battle builds")
	var controller := ScriptedController.new()
	await battle.run(controller)
	var request := {"snapshot": snapshot, "actionLog": ActionRecorder.build_log(controller.entries, battle.outcome, battle.final_hash)}
	var verified := await ReplayRunner.new().run_on(request.duplicate(true), run.content, host)
	eq(verified.get("verdict"), "Verified", "the verifier's replay matches (%s)" % [verified.get("mismatch")])
	var plain := granted.duplicate() as EncounterDefinition
	plain.party_grants = null
	var without := await ReplayRunner.new().run_on(request.duplicate(true), fixtures().overlay([plain, event]), host)
	eq(without.get("verdict"), "Rejected", "without the grant the same log does not replay")


## F10 (D3): an event encounter holding an Enemy.Boss unit is flagged (a win would pay boss gems); the demo has none.
func test_event_encounter_boss_is_flagged() -> void:
	var boss_unit: UnitDefinition = null
	for unit in fixtures().units.values():
		if unit is EnemyDefinition and unit.tags.has(&"Enemy.Boss"):
			boss_unit = unit
			break
	check(boss_unit != null, "the fixtures have a boss unit")
	if boss_unit == null:
		return
	var encounter := EncounterDefinition.new()
	encounter.id = &"fixture.encounter.event_boss"
	var event_tags: Array[StringName] = [&"Encounter.Event"]
	encounter.tags = event_tags
	var slot := EncounterSlot.new()
	slot.enemy = boss_unit
	encounter.slots.assign([slot])
	check(_codes([encounter]).has("event_encounter_boss"), "event_encounter_boss")


# --- 2.8 bots -----------------------------------------------------------------------------------------------------------

func test_bot_event_choice_random() -> void:
	var locked := CoinsAtLeast.new()
	locked.amount = 99999
	var event := _event("fixture.event.bots", [[_choice("a", [], [&"Choice.Leave"]),
		_choice("b", [GainCoins.new()], [&"Choice.Gain.Coins"], [locked]), _choice("c", [GainCoins.new()],
		[&"Choice.Gain.Coins"])]])
	var picks := {}
	var first: Array = []
	for attempt in 2:
		var run := _run([event])
		var run_picks: Array = []
		for time in 12:
			_open(run, event)
			run.run_log.append({"type": "dev", "command": "pad", "args": []})  # a new log size: a new draw
			var picked := EventScorer.pick(run, [0, 2], EventScorer.POLICY_RANDOM)
			run_picks.append(picked)
			picks[picked] = true
			run.state.event = {}
		if attempt == 0:
			first = run_picks
		else:
			eq(run_picks, first, "the same run picks the same choices")
	check(not picks.has(1), "never a disabled choice")
	check(picks.has(0) and picks.has(2), "both enabled choices come up: %s" % [picks.keys()])


func test_bots_take_class_choices() -> void:
	var event := _event("fixture.event.bot_class", [[_choice("leave", [], [&"Choice.Leave"]),
		_choice("gold", [GainCoins.new()], [&"Choice.Gain.Coins"]), _class_choice("medic")]])
	var run := _run([event])
	_open(run, event)
	for policy in [EventScorer.POLICY_RANDOM, EventScorer.POLICY_SMART]:
		for time in 5:
			run.run_log.append({"type": "dev", "command": "pad", "args": []})
			eq(EventScorer.pick(run, [0, 1, 2], policy), 2, "%s takes the class choice" % policy)


func test_event_scorer() -> void:
	var run := _run()
	var free := _choice("take", [], [&"Choice.Gain.Item"])
	var leave := _choice("leave", [], [&"Choice.Leave"])
	check(EventScorer.score(run, free) > EventScorer.score(run, leave), "a free item beats leaving")
	var sacrifice := _choice("offer", [], [&"Choice.Cost.Life", &"Choice.Gain.Level"])
	eq(EventScorer.score(run, sacrifice), EventScorer.REFUSED, "a life for a level is refused")
	var boss_deal := _choice("offer", [], [&"Choice.Cost.Life", &"Choice.Gain.BossItem"])
	check(EventScorer.score(run, boss_deal) > EventScorer.REFUSED, "a life for a boss item with 3 alive is not")
	run.state.member(3)["alive"] = false
	eq(EventScorer.score(run, boss_deal), EventScorer.REFUSED, "but is with only 2 alive")
	run.state.member(3)["alive"] = true
	var bleed := _choice("drink", [], [&"Choice.Cost.Hp", &"Choice.Gain.Item"])
	var fight := _choice("fight", [], [&"Choice.Fight", &"Choice.Gain.Item"])
	var heal := _choice("rest", [], [&"Choice.Gain.Heal"])
	check(EventScorer.score(run, bleed) > 0 and EventScorer.score(run, fight) > 0, "at full HP: pay HP or fight")
	var heal_full := EventScorer.score(run, heal)
	for slot in [1, 2, 3]:
		run.apply_member_effect(_hp_effect(-1), [slot], false)
	var share := EventScorer.party_hp_share(run)
	check(share < 10000, "the party is hurt a little")
	run.state.member(1)["hp"] = 1
	run.state.member(2)["hp"] = 1
	run.state.member(3)["hp"] = 1
	check(EventScorer.score(run, bleed) < 0, "at low HP: not the HP cost")
	check(EventScorer.score(run, fight) < 0, "nor the fight")
	check(EventScorer.score(run, heal) > heal_full, "a heal is worth more when hurt")
	var event := _event("fixture.event.tie", [[_choice("x", [], [&"Choice.Gain.Item"]),
		_choice("y", [], [&"Choice.Gain.Item"])]])
	var tied := _run([event])
	_open(tied, event)
	var seen := {}
	for time in 16:
		tied.run_log.append({"type": "dev", "command": "pad", "args": []})
		seen[EventScorer.pick(tied, [0, 1], EventScorer.POLICY_SMART)] = true
	eq(seen.size(), 2, "ties are broken on the bots' stream")


## User, 2026-11-22: the smart bot reads who pays an HP cost and how much: it refuses a choice a member would not survive
## (a slot, a random target at its worst, the whole party, one outcome of a gamble), and otherwise prices the cost by the
## hardest-hit member, not the party's average.
func test_scorer_refuses_a_choice_that_would_kill() -> void:
	var drink := _choice("drink", [_member_effect(_hp_effect(-500), ApplyMemberEffect.Target.SLOT, 1)],
		[&"Choice.Cost.Hp", &"Choice.Gain.Item"])
	var event := _event("fixture.event.risky", [[drink, _choice("leave", [], [&"Choice.Leave"])]])
	var run := _run([event])
	_open(run, event)
	check(EventScorer.score(run, drink) > EventScorer.REFUSED, "a healthy first member can afford it")
	run.state.member(1)["hp"] = 30000  # 300 HP left; the effect takes 500
	eq(EventScorer.score(run, drink), EventScorer.REFUSED, "the first member would die: refused")
	check(EventScorer.hp_risk(run, drink)["kills"], "hp_risk says so")
	var random := _choice("snake", [_member_effect(_hp_effect(-500), ApplyMemberEffect.Target.RANDOM)], [&"Choice.Cost.Hp"])
	eq(EventScorer.score(run, random), EventScorer.REFUSED, "a random bite counts at its worst")
	var party := ApplyPartyEffect.new()
	party.effect = _hp_effect(-500)
	var everyone := _choice("darts", [party], [&"Choice.Cost.Hp"])
	eq(EventScorer.score(run, everyone), EventScorer.REFUSED, "a party-wide loss one member cannot take")
	run.state.member(1)["hp"] = int(run.state.member(2)["hp"])
	check(EventScorer.score(run, everyone) > EventScorer.REFUSED, "all healthy: fine")


func test_scorer_checks_each_outcome_of_a_gamble() -> void:
	var lose := EventPage.new()
	lose.text = "ouch"
	var on_enter: Array[RunOutcome] = [_member_effect(_hp_effect(-500), ApplyMemberEffect.Target.SLOT, 2)]
	lose.on_enter = on_enter
	lose.choices.assign([_choice("Continue", [], [&"Choice.Leave"])])
	var win := EventPage.new()
	win.text = "yay"
	win.choices.assign([_choice("Continue", [], [&"Choice.Leave"])])
	var gamble := GoToRandomPage.new()
	gamble.pages.assign([1, 2])
	gamble.weights_x100.assign([5000, 5000])
	var bet := _choice("roll", [gamble], [&"Choice.Gamble", &"Choice.Cost.Hp"])
	var start := EventPage.new()
	start.text = "roll?"
	start.choices.assign([bet])
	var event := EventDefinition.new()
	event.id = &"fixture.event.risky_gamble"
	event.pages.assign([start, win, lose])
	var run := _run([event])
	_open(run, event)
	check(EventScorer.score(run, bet) > EventScorer.REFUSED, "a healthy second member can risk it")
	run.state.member(2)["hp"] = 20000
	eq(EventScorer.score(run, bet), EventScorer.REFUSED, "one outcome would kill the second member: refused")


func test_bots_play_a_looping_event_to_its_end() -> void:
	var gamble := GoToRandomPage.new()
	gamble.pages.assign([0])
	gamble.weights_x100.assign([10000])
	var event := _event("fixture.event.well", [[_choice("throw", [gamble], [&"Choice.Gamble"]),
		_choice("leave", [], [&"Choice.Leave"])]])
	var run := _run([event])
	_open(run, event)
	await RunPlayer.play(run, 60)
	check(str(run.state.event.get("event", "")) != "fixture.event.well", "the bot left the well")


# --- 5 summary and console ------------------------------------------------------------------------------------------

func test_summary_counts_events() -> void:
	var event := _simple("fixture.event.count", [GainCoins.new()])
	var run := _run([event])
	eq(run.dev_open_event(event), "", "the dev command's method opens it")
	eq(run.choose(0), "", "choose")
	var summary := run.run_summary()
	eq(int(summary["eventsEntered"]), 1, "one event entered")
	eq(summary["events"]["fixture.event.count"], {"entered": 1, "choices": {"0:0": 1}}, "and its choice")
	check(run.state.dev, "the dev command marks the run dev")
	var outside := _event("fixture.event.unlisted", [[_choice("x", [], [&"Choice.Leave"])]])
	eq(run.dev_open_event(outside), "no such event in the run's content", "an event the content lacks is refused")


## Review fix: the cheat opens a fight event in a cleared room too; the won fight clears it without loot rolls again.
func test_event_cheat_fight_in_a_cleared_room() -> void:
	var start := StartEncounter.new()
	start.encounter = fixtures().encounters[&"fixture.encounter.lone"]
	var event := _event("fixture.event.cheat_fight", [[_choice("Fight!", [start], [&"Choice.Fight"])]])
	var run := _run([event])
	check(run.state.map.cells[run.state.current_cell]["cleared"], "the start room is cleared")
	eq(run.dev_open_event(event), "", "a fight event opens in a cleared room")
	eq(run.choose(0), "", "Fight!")
	check(not run.pending_battle.is_empty(), "the fight is pending")
	var keys_before := run.state.keys
	var chests_before: int = run.state.map.cells[run.state.current_cell].get("chests", []).size()
	await run.fight(ScriptedController.new())
	if run.state.status == RunState.ACTIVE:
		eq(run.state.keys, keys_before, "no key roll for the room a second time")
		eq(run.state.map.cells[run.state.current_cell].get("chests", []).size(), chests_before, "no chest roll either")


func test_dev_open_event_refuses_while_one_is_open() -> void:
	var run := _run()
	var event: EventDefinition = fixtures().events[&"fixture.event.coin"]
	eq(run.dev_open_event(event), "", "opens")
	eq(run.dev_open_event(event), "not while a battle or an event is open", "refused while one is open")


# --- 3 validator --------------------------------------------------------------------------------------------------------

func _codes(resources: Array) -> Array:
	return ContentValidator.validate(fixtures().overlay(resources), {"tags": false}).map(
		func(issue: ValidationIssue) -> String: return issue.code)


func test_validator_codes() -> void:
	var no_tags := _event("fixture.event.untagged", [[_choice("take", [GainCoins.new()])]])
	check(_codes([no_tags]).has("choice_tags_missing"), "choice_tags_missing")
	var wrong := _event("fixture.event.wrong", [[_choice("take", [GainCoins.new(), _member_effect(_hp_effect(-5),
		ApplyMemberEffect.Target.FIRST)], [&"Choice.Gain.Coins"])]])
	check(_codes([wrong]).has("choice_tag_mismatch"), "a hurt without Choice.Cost.Hp")
	var gamble := GoToRandomPage.new()
	gamble.pages.assign([1])
	gamble.weights_x100.assign([10000])
	var behind := _event("fixture.event.behind", [[_choice("bet", [gamble], [&"Choice.Gamble"])],
		[_choice("win", [GainCoins.new()], [&"Choice.Gain.Coins"])]])
	check(_codes([behind]).has("choice_tag_mismatch"), "a gain behind a random page needs its tag on the bet")
	var bad_page := GoToRandomPage.new()
	bad_page.pages.assign([5])
	bad_page.weights_x100.assign([0])
	var broken := _event("fixture.event.bad_page", [[_choice("bet", [bad_page], [&"Choice.Gamble"])]])
	check(_codes([broken]).has("random_page_invalid"), "random_page_invalid")
	var far := _gift(_item("whetstone"), GiveItem.Recipient.SLOT, 7)
	check(_codes([_simple("fixture.event.far", [far])]).has("member_slot_out_of_range"), "member_slot_out_of_range")
	var class_choice := _choice("x", [], [&"Choice.Class", &"Choice.Leave"])
	check(_codes([_event("fixture.event.cls", [[class_choice]])]).has("class_choice_without_character"),
		"class_choice_without_character")
	var met := _choice("y", [], [&"Choice.Leave"])
	met.show = EventChoice.Show.WHEN_MET
	check(_codes([_event("fixture.event.met", [[met]])]).has("when_met_without_conditions"), "when_met_without_conditions")
	var both := _gift(_item("whetstone"), GiveItem.Recipient.FLOOR)
	both.character = fixtures().units[&"fixture.character.medic"]
	check(_codes([_simple("fixture.event.floor_character", [both])]).has("floor_ignores_character"), "floor_ignores_character")
	var token := _choice("{hero} waves", [], [&"Choice.Leave"])
	check(_codes([_event("fixture.event.token", [[token]])]).has("event_text_token_unknown"), "event_text_token_unknown")
	var pooled := _item("whetstone").duplicate() as ItemDefinition
	pooled.id = &"fixture.item.cursed_whetstone"
	var curse_tags: Array[StringName] = [&"Item.Curse", &"Pool.Treasure"]
	pooled.tags = curse_tags
	check(_codes([pooled]).has("event_item_pooled"), "event_item_pooled")
	var leaking := fixtures().encounters[&"fixture.encounter.lone"].duplicate() as EncounterDefinition
	leaking.id = &"fixture.encounter.leaking"
	var leak_tags: Array[StringName] = leaking.tags.duplicate()
	leak_tags.append(&"Encounter.Event")
	leaking.tags = leak_tags
	var picked_by_chapter := false
	for chapter in fixtures().chapters.values():
		if chapter.encounter_query != null and TagMatch.matches(chapter.encounter_query, leaking.tags):
			picked_by_chapter = true
	if picked_by_chapter:
		check(_codes([leaking]).has("event_encounter_in_pool"), "event_encounter_in_pool (a chapter's query)")
	# A room's own query picks it too (review fix): an event-only encounter matched only by a room.
	var hidden := leaking.duplicate() as EncounterDefinition
	hidden.id = &"fixture.encounter.room_only"
	var only_event: Array[StringName] = [&"Encounter.Event", &"Fixture.Event.RoomOnly"]
	hidden.tags = only_event
	var room: RoomDefinition = fixtures().rooms.values().filter(func(entry: RoomDefinition) -> bool:
		return entry.content_mode == RoomDefinition.ContentMode.ENCOUNTER_QUERY)[0].duplicate()
	room.id = &"fixture.room.picks_events"
	room.content_query = _query(&"Fixture.Event.RoomOnly")
	check(not _codes([hidden]).has("event_encounter_in_pool"), "no query picks it alone")
	check(_codes([hidden, room]).has("event_encounter_in_pool"), "event_encounter_in_pool (a room's query)")
	var party := AbilitySet.new()
	party.effects.assign([RunController.dev_effect("dev_heal")])
	var grants_ok := fixtures().encounters[&"fixture.encounter.lone"].duplicate() as EncounterDefinition
	grants_ok.id = &"fixture.encounter.granted"
	grants_ok.party_grants = party
	check(not _codes([grants_ok]).has("party_grants_not_turn_based"), "an instant party grant is fine")


func test_effect_kind() -> void:
	eq(ContentValidator.effect_kind(_hp_effect(-5)), "hurt", "a negative HP change hurts")
	eq(ContentValidator.effect_kind(_hp_effect(5)), "heal", "a positive one heals")
	eq(ContentValidator.effect_kind(RunController.dev_effect("dev_kill")), "slay", "an override to 0 slays")
	eq(ContentValidator.effect_kind(RunController.dev_effect("dev_heal")), "heal", "an override to max HP heals")
