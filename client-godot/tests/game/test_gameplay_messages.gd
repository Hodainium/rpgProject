## Spec gameplay-messages 6: the router's delivery rules (exact and partial, order, payload types, owners,
## unregistering, re-entrant listeners), the run and battle messages of a fixture run, that run hashes never depend on
## listeners, that a replay never broadcasts, and a UI panel that listens. Fixtures and code-built listeners only.
extends TestCase

const UI_TEST := preload("res://tests/game/test_ui.gd")
const PROBE := preload("res://tests/game/ui_probe_message.gd")
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]

var _handles: Array[GameplayMessageHandle] = []
var _nodes: Array[Node] = []
var _bridges: Array[BattleMessages] = []
## [listener name, channel] in delivery order.
var _heard: Array = []


func after_each() -> void:
	for handle in _handles:
		handle.unregister()
	_handles.clear()
	for node in _nodes:
		if is_instance_valid(node):
			node.free()
	_nodes.clear()
	_bridges.clear()
	_heard.clear()
	super()


func _listen(channel: StringName, label: String, mode: int = GameplayMessageRouter.Match.EXACT,
		payload_type: Script = null, owner: Object = null) -> GameplayMessageHandle:
	var handle := GameplayMessages.listen(channel, func(heard_on: StringName, _message): _heard.append([label, heard_on]),
		mode, payload_type, owner)
	_handles.append(handle)
	return handle


static func _note(text: String) -> NotificationMessage:
	return NotificationMessage.make(text)


func _labels() -> Array:
	return _heard.map(func(entry) -> String: return entry[0])


func test_messages_exact_and_partial() -> void:
	_listen(&"Message.Test.A", "exact A")
	_listen(&"Message.Test", "partial Test", GameplayMessageRouter.Match.PARTIAL)
	_listen(&"Message.Test.A", "partial A", GameplayMessageRouter.Match.PARTIAL)
	_listen(&"Message.Test", "exact Test")
	_listen(&"Message.Test.A", "exact A 2")
	_listen(&"Message", "partial Message", GameplayMessageRouter.Match.PARTIAL)
	eq(GameplayMessages.broadcast(&"Message.Test.A", _note("a")), 5, "five listeners hear Message.Test.A")
	eq(_labels(), ["exact A", "exact A 2", "partial A", "partial Test", "partial Message"],
		"exact in registration order, then partial from the channel up the tree")
	_heard.clear()
	GameplayMessages.broadcast(&"Message.Test.A.B", _note("b"))
	eq(_labels(), ["partial A", "partial Test", "partial Message"], "a child channel reaches only partial listeners")
	eq(_heard[0][1], &"Message.Test.A.B", "listeners get the channel it was sent on")
	_heard.clear()
	GameplayMessages.broadcast(&"Message.Test", _note("c"))
	eq(_labels(), ["exact Test", "partial Test", "partial Message"],
		"a parent channel never reaches its children's listeners")
	_heard.clear()
	eq(GameplayMessages.broadcast(&"Message.Other", _note("d")), 1, "an unrelated channel: only the root listener")
	eq(GameplayMessages.listener_count(&"Message.Test.A"), 3, "three listeners on Message.Test.A")


func test_messages_payload_type() -> void:
	_listen(&"Message.Test.Typed", "verb only", GameplayMessageRouter.Match.EXACT, VerbMessage)
	_listen(&"Message.Test.Typed", "any")
	GameplayMessages.broadcast(&"Message.Test.Typed", _note("not a verb"))
	eq(_labels(), ["any"], "a listener for VerbMessage skips a notification")
	_heard.clear()
	GameplayMessages.broadcast(&"Message.Test.Typed", VerbMessage.make(&"Verb.Take", &"slot:1", &"item"))
	eq(_labels(), ["verb only", "any"], "and hears a verb")
	var verb := VerbMessage.make(&"Verb.Break", &"P1", &"E2", 1250, [&"Hit.Weakness"])
	eq(verb.describe(), "Verb.Break P1→E2 1250 [Hit.Weakness]", "the dev log line of a verb")


func test_messages_owner_freed() -> void:
	var owner := Node.new()
	host.add_child(owner)
	_listen(&"Message.Test.Owned", "owned", GameplayMessageRouter.Match.EXACT, null, owner)
	GameplayMessages.broadcast(&"Message.Test.Owned", _note("1"))
	eq(_heard.size(), 1, "heard while the owner lives")
	owner.free()
	eq(GameplayMessages.broadcast(&"Message.Test.Owned", _note("2")), 0, "nobody hears after the owner is freed")
	eq(_heard.size(), 1, "the listener was dropped silently")
	eq(GameplayMessages.listener_count(&"Message.Test.Owned"), 0, "and removed")
	# A node's own method as the callback: the node is the owner without saying so.
	var probe := Node.new()
	host.add_child(probe)
	_handles.append(GameplayMessages.listen(&"Message.Test.Owned", Callable(probe, &"get_index")))
	eq(GameplayMessages.listener_count(&"Message.Test.Owned"), 1, "a node's method listens")
	probe.free()
	eq(GameplayMessages.listener_count(&"Message.Test.Owned"), 0, "and goes away with the node")


func test_messages_unregister() -> void:
	var handle := _listen(&"Message.Test.Gone", "gone")
	check(handle.is_valid(), "a new handle is valid")
	handle.unregister()
	check(not handle.is_valid(), "an unregistered handle is not")
	handle.unregister()  # twice is harmless
	eq(GameplayMessages.broadcast(&"Message.Test.Gone", _note("x")), 0, "nobody hears")
	eq(GameplayMessages.listener_count(&"Message.Test.Gone"), 0, "no listener left")


## A listener that registers one and unregisters another while a message is delivered.
func test_messages_reentrant() -> void:
	var added: Array = []
	var victim: Array = [null]
	_handles.append(GameplayMessages.listen(&"Message.Test.Loop", func(_channel, _message):
		_heard.append(["first", &""])
		if added.is_empty():
			added.append(_listen(&"Message.Test.Loop", "added"))
		if victim[0] != null:
			victim[0].unregister()))
	victim[0] = _listen(&"Message.Test.Loop", "removed")
	GameplayMessages.broadcast(&"Message.Test.Loop", _note("1"))
	eq(_labels(), ["first"], "a listener added during a broadcast waits; one removed during it stops at once")
	_heard.clear()
	GameplayMessages.broadcast(&"Message.Test.Loop", _note("2"))
	eq(_labels(), ["first", "added"], "the added one hears the next broadcast")


# --- Run and battle messages ----------------------------------------------------------------------------------------

func _bridge(battle: Battle, run: RunController) -> void:
	var bridge := BattleMessages.new()
	bridge.attach(battle, StringName(str(run.pending_battle.get("encounter", ""))), GameplayMessages)
	_bridges.append(bridge)


## The fixture scripted run (seed 7), with the client's battle bridge when `with_bridge` (as GameMain plays it).
func _scripted_run(with_bridge: bool) -> RunController:
	var run := RunController.new()
	host.add_child(run)
	_nodes.append(run)
	if with_bridge:
		run.battle_started.connect(_bridge.bind(run))
	eq(run.start_run(fixtures(), PARTY, "7"), "", "the fixture run starts")
	await RunPlayer.play(run)
	return run


func test_messages_run_flow() -> void:
	var heard: Array = []
	_handles.append(GameplayMessages.listen(&"Message", func(channel: StringName, message: GameplayMessage):
		heard.append([channel, message]), GameplayMessageRouter.Match.PARTIAL))
	var run: RunController = await _scripted_run(true)
	var channels: Array = heard.map(func(entry) -> String: return String(entry[0]))
	eq(channels.slice(0, 2), ["Message.Run.Started", "Message.Run.FloorEntered"], "a run starts on its first floor")
	eq(channels.back(), "Message.Run.Ended", "and its end is the last message")
	eq(heard.back()[1].verb, &"Verb.Win" if run.state.status == RunState.WON else &"Verb.Lose", "the outcome is the verb")
	var started := channels.find("Message.Battle.Started")
	var damage := channels.find("Message.Battle.Damage")
	var ended := channels.find("Message.Battle.Ended")
	check(started > 1 and damage > started and ended > damage,
		"a battle: started, damage, ended (%d %d %d)" % [started, damage, ended])
	if damage >= 0:
		var hit: VerbMessage = heard[damage][1]
		check(hit.instigator != &"" and hit.magnitude > 0 and hit.data.has("targetName"),
			"a damage verb names who hit whom and how much: " + hit.describe())
	var counts := {}
	for entry in run.run_log:
		counts[entry["type"]] = counts.get(entry["type"], 0) + 1
	eq(channels.count("Message.Battle.Started"), counts.get("battle", 0), "one Battle.Started per logged battle")
	eq(channels.count("Message.Battle.Ended"), counts.get("battle", 0), "one Battle.Ended per logged battle")
	eq(channels.count("Message.Run.ItemTaken"), counts.get("take", 0) + counts.get("buy", 0),
		"one ItemTaken per take or buy")
	eq(channels.count("Message.Run.Choice"), counts.get("choose", 0), "one Choice per event choice")
	eq(channels.count("Message.Run.FloorEntered"), run.state.floor_index + 1, "one FloorEntered per floor")
	if not run.structure.xp_to_level.is_empty():
		check(channels.has("Message.Run.LevelUp"), "levels are gained in a run with an XP curve")


func test_messages_run_hash_unchanged() -> void:
	var bare: RunController = await _scripted_run(false)
	_handles.append(GameplayMessages.listen(&"Message", func(_channel, message: GameplayMessage):
		_heard.append(message.describe()), GameplayMessageRouter.Match.PARTIAL))
	var heard: RunController = await _scripted_run(true)
	check(_heard.size() > 10, "the second run was heard (%d messages)" % _heard.size())
	eq(heard.run_log, bare.run_log, "same run log with and without listeners")
	eq(heard.state.run_hash(), bare.state.run_hash(), "same run hash with and without listeners")


## The bridge on the item-pass fixture battle (it opens with Fire Slash breaking E2, then Fire Wave breaking E1):
## Started first, every break and One More as a verb with names, Ended last; the final hash is the same without it.
func test_messages_battle_bridge() -> void:
	var snap: Dictionary = preload("res://tests/combat/test_item_pass_combat.gd").break_snapshot()
	var heard: Array = []
	_handles.append(GameplayMessages.listen(&"Message.Battle", func(channel: StringName, message: VerbMessage):
		heard.append([String(channel), message]), GameplayMessageRouter.Match.PARTIAL, VerbMessage))
	var battle := new_battle(snap)
	var signalled := {"broken": 0, "one_more": 0}
	battle.unit_broken.connect(func(_u, _by): signalled["broken"] += 1)
	battle.one_more_started.connect(func(_u): signalled["one_more"] += 1)
	var bridge := BattleMessages.new()
	bridge.attach(battle, &"fixture.encounter.brittle_pair", GameplayMessages)
	await battle.run(ScriptedController.new())
	var channels: Array = heard.map(func(entry) -> String: return entry[0])
	eq(channels.front(), "Message.Battle.Started", "the bridge announces the battle")
	eq(channels.back(), "Message.Battle.Ended", "and its end, last")
	eq(heard.back()[1].verb, &"Verb.Win", "a won battle")
	var breaks: Array = heard.filter(func(entry) -> bool: return entry[0] == "Message.Battle.Broken")
	eq(breaks.slice(0, 2).map(func(entry) -> String: return "%s→%s" % [entry[1].instigator, entry[1].target]),
		["P1→E2", "P1→E1"], "the opening breaks, breaker → broken")
	eq(breaks.size(), signalled["broken"], "one Broken message per unit_broken signal")
	check(not breaks.is_empty() and breaks[0][1].data.get("targetName", "") != "", "with the broken unit's name")
	eq(channels.count("Message.Battle.OneMore"), signalled["one_more"], "one OneMore message per One More")
	var weak := heard.filter(func(entry) -> bool:
		return entry[0] == "Message.Battle.Damage" and entry[1].tags.has(&"Hit.Weakness"))
	check(not weak.is_empty(), "damage verbs carry the hit tags")
	var plain := new_battle(snap)
	await plain.run(ScriptedController.new())
	eq(battle.final_hash, plain.final_hash, "the same final hash without the bridge")


## The battle kernel never broadcasts: recording and replaying a fixture battle sends nothing.
func test_replay_sends_no_messages() -> void:
	_listen(&"Message", "anything", GameplayMessageRouter.Match.PARTIAL)
	var request: Dictionary = await record(squad_snapshot("7"))
	var result: Dictionary = await replay(request)
	eq(result.get("verdict", ""), "Verified", "the replay verifies")
	eq(_heard.size(), 0, "no message during a recorded or replayed battle")


## Spec gameplay-messages 6, UI: a panel listening to Message.Notification shows GameMain.show_message's text, and
## its listener goes away with the game.
func test_messages_ui_panel_listens() -> void:
	var policy: UIPolicy = UI_TEST._plain_policy()
	var probe := Control.new()
	probe.set_script(PROBE)
	probe.name = "MessageProbe"
	policy.extensions.assign([UI_TEST._extension(&"UI.Slot.Footer", UI_TEST._pack(probe), 0, &"")])
	var before := GameplayMessages.listener_count(GameplayMessageRouter.NOTIFICATION)
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.ui_policy = policy
	host.add_child(game)
	_nodes.append(game)
	eq(GameplayMessages.listener_count(GameplayMessageRouter.NOTIFICATION), before + 1, "the panel listens")
	game.show_message("hello")
	var panel := game.ui.layout.find_child("MessageProbe", true, false)
	check(panel != null and panel.text == "hello", "the footer panel shows the line")
	game.free()
	eq(GameplayMessages.listener_count(GameplayMessageRouter.NOTIFICATION), before, "the panel's listener left with it")
