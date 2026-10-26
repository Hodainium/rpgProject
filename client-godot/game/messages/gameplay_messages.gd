## Spec gameplay-messages (Lyra's GameplayMessageRouter): the autoload `GameplayMessages`. Senders broadcast a typed
## payload on a channel tag and move on; listeners register for a channel, EXACT or PARTIAL (the channel and its
## children: Message.Battle hears Message.Battle.Broken), and never know who sent it.
##
## Delivery is synchronous and ordered: the channel's EXACT listeners, then PARTIAL listeners of the channel, then of
## each parent up the tree (child first), each level in registration order. A listener added during a broadcast hears
## the next one; one removed during a broadcast stops at once; one whose owner node was freed is dropped silently.
##
## Messages are presentation and tooling only: no rule of the game listens, and a listener never changes run or battle
## state. The battle kernel never broadcasts (combat/ is unchanged; BattleMessages bridges a shown battle's signals).
class_name GameplayMessageRouter
extends Node

enum Match { EXACT, PARTIAL }

const NOTIFICATION: StringName = &"Message.Notification"
const RUN_STARTED: StringName = &"Message.Run.Started"
const RUN_ENDED: StringName = &"Message.Run.Ended"
const RUN_FLOOR_ENTERED: StringName = &"Message.Run.FloorEntered"
const RUN_LEVEL_UP: StringName = &"Message.Run.LevelUp"
const RUN_ITEM_TAKEN: StringName = &"Message.Run.ItemTaken"
const RUN_ITEM_DROPPED: StringName = &"Message.Run.ItemDropped"
const RUN_CHOICE: StringName = &"Message.Run.Choice"
const BATTLE_STARTED: StringName = &"Message.Battle.Started"
const BATTLE_ENDED: StringName = &"Message.Battle.Ended"
const BATTLE_DAMAGE: StringName = &"Message.Battle.Damage"
const BATTLE_BROKEN: StringName = &"Message.Battle.Broken"
const BATTLE_RECOVERED: StringName = &"Message.Battle.Recovered"
const BATTLE_DOWNED: StringName = &"Message.Battle.Downed"
const BATTLE_ONE_MORE: StringName = &"Message.Battle.OneMore"
const BATTLE_INTERRUPT: StringName = &"Message.Battle.Interrupt"
const BATTLE_PHASE: StringName = &"Message.Battle.Phase"
const BATTLE_RESISTED: StringName = &"Message.Battle.Resisted"
const BATTLE_DRAINED: StringName = &"Message.Battle.Drained"
const BATTLE_TURN_SKIPPED: StringName = &"Message.Battle.TurnSkipped"
const BATTLE_UNIT_DIED: StringName = &"Message.Battle.UnitDied"
const UI_REFUSED: StringName = &"Message.Ui.Refused"

## Every channel and verb the code sends (the tag checkpoint, sync_tags.tscn, checks them against the registry).
const CHANNELS: Array[StringName] = [NOTIFICATION, RUN_STARTED, RUN_ENDED, RUN_FLOOR_ENTERED, RUN_LEVEL_UP,
	RUN_ITEM_TAKEN, RUN_ITEM_DROPPED, RUN_CHOICE, BATTLE_STARTED, BATTLE_ENDED, BATTLE_DAMAGE, BATTLE_BROKEN,
	BATTLE_RECOVERED, BATTLE_DOWNED, BATTLE_ONE_MORE, BATTLE_INTERRUPT, BATTLE_PHASE, BATTLE_RESISTED, BATTLE_DRAINED,
	BATTLE_TURN_SKIPPED, BATTLE_UNIT_DIED, UI_REFUSED]
const VERBS: Array[StringName] = [&"Verb.Start", &"Verb.Win", &"Verb.Lose", &"Verb.Stop", &"Verb.Enter",
	&"Verb.LevelUp", &"Verb.Take", &"Verb.Buy", &"Verb.Drop", &"Verb.Choose", &"Verb.Damage", &"Verb.Break",
	&"Verb.Recover", &"Verb.Down", &"Verb.OneMore", &"Verb.Interrupt", &"Verb.Phase", &"Verb.Resist", &"Verb.Drain",
	&"Verb.Skip", &"Verb.Die", &"Verb.Refuse"]
const NOTIFICATION_TAGS: Array[StringName] = [&"Notification.Warning", &"Notification.Error"]

## channel -> Array of entries {callback, mode, payload_type, owner: WeakRef or null, removed}
var _listeners: Dictionary = {}


## Delivers `message` to every listener of `channel` (2.1 order). Returns how many listeners heard it.
func broadcast(channel: StringName, message: GameplayMessage) -> int:
	if _listeners.is_empty() or message == null:
		return 0
	var heard := 0

	# Who hears it is fixed now: listeners added by a callback wait for the next broadcast.
	var order: Array = []
	var own: Array = _listeners.get(channel, [])
	order.append_array(own.filter(func(entry) -> bool: return entry["mode"] == Match.EXACT))
	var level := String(channel)
	while true:
		order.append_array(_listeners.get(StringName(level), []).filter(
			func(entry) -> bool: return entry["mode"] == Match.PARTIAL))
		var dot := level.rfind(".")
		if dot < 0:
			break
		level = level.substr(0, dot)
	for entry in order:
		if _deliver(entry, channel, message):
			heard += 1
	return heard


## Registers `callback(channel: StringName, message: GameplayMessage)` for `channel`. PARTIAL also hears its child
## channels. With `payload_type` (a GameplayMessage script), other payloads are skipped with a warning. The listener
## goes away with `owner` (default: the callback's object when it is a Node).
func listen(channel: StringName, callback: Callable, mode: Match = Match.EXACT, payload_type: Script = null,
		owner: Object = null) -> GameplayMessageHandle:
	if owner == null and callback.get_object() is Node:
		owner = callback.get_object()
	var entry := {"channel": channel, "callback": callback, "mode": mode, "payload_type": payload_type,
		"owner": weakref(owner) if owner != null else null, "removed": false}
	if not _listeners.has(channel):
		_listeners[channel] = []
	_listeners[channel].append(entry)
	return GameplayMessageHandle.new(self, entry)


## Listeners registered on exactly `channel` (any match), after dropping those whose owner is gone.
func listener_count(channel: StringName) -> int:
	for entry in _listeners.get(channel, []).duplicate():
		if not _alive(entry):
			unregister(entry)
	return _listeners.get(channel, []).size()


## Called by GameplayMessageHandle.unregister().
func unregister(entry: Dictionary) -> void:
	if entry.is_empty() or entry["removed"]:
		return
	entry["removed"] = true
	var entries: Array = _listeners.get(entry["channel"], [])
	entries.erase(entry)
	if entries.is_empty():
		_listeners.erase(entry["channel"])


func _deliver(entry: Dictionary, channel: StringName, message: GameplayMessage) -> bool:
	if entry["removed"]:
		return false
	if not _alive(entry):
		unregister(entry)
		return false
	var payload_type: Script = entry["payload_type"]
	if payload_type != null and not is_instance_of(message, payload_type):
		push_warning("GameplayMessages: a listener of %s expects %s but got %s; skipped" % [entry["channel"],
			_type_name(payload_type), _type_name(message.get_script())])
		return false
	entry["callback"].call(channel, message)
	return true


static func _alive(entry: Dictionary) -> bool:
	var owner: WeakRef = entry["owner"]
	if owner != null:
		var node: Object = owner.get_ref()
		if node == null or not is_instance_valid(node) or (node is Node and node.is_queued_for_deletion()):
			return false
	return entry["callback"].is_valid()


static func _type_name(script: Script) -> String:
	if script == null:
		return "?"
	var name := script.get_global_name()
	return String(name) if name != &"" else script.resource_path.get_file()
