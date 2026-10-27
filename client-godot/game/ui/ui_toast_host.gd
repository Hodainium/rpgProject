## Spec ff7-ui 2.2 (F10, Lyra's accolade host widget): a panel that turns gameplay messages into toasts by its
## UIToastSet's rules. Put it in a HUD slot like any panel; its look is the set's entry scene and the theme.
##
## A toast is a Dictionary {kicker, title, subtitle, variation, seconds, priority, sound, pinned}. QUEUE sets show
## them one after another, STACK sets pile them up (the oldest leaves past max_visible). Each lasts its seconds of real
## time. A rule with a hold_action also shows, pinned, while that action is held, from the latest message on its
## channel (Tab keeps the floor toast up); while it is pinned, new QUEUE toasts wait.
##
## Presentation only: it listens, never changes the run or a battle.
class_name UIToastHost
extends UIScreen

## A toast came on screen (for sounds and the dev log).
signal toast_shown(toast: Dictionary)
## A hold action started or stopped showing its toast (the scene moves things out of its way).
signal hold_changed(held: bool)

@export var toast_set: UIToastSet
## Where the toast entries go. Empty: this node.
@export var container: NodePath

## [{toast, node, until}] in show order; until < 0 while pinned.
var _live: Array = []
var _queue: Array = []
## UIToastRule -> the latest message on its channel that it matched (for hold actions).
var _latest: Dictionary = {}
var _pinned_rule: UIToastRule = null
## Tests (and the console) can press a hold action without input: action -> bool.
var _forced_holds: Dictionary = {}
var _clock_offset: float = 0.0
var _listening: bool = false


func bind(_context: UIContext) -> void:
	start()


## Starts listening for the set's rules (bind does this; a host made in code calls it itself).
func start() -> void:
	if _listening or toast_set == null:
		return
	_listening = true
	for rule in toast_set.rules:
		if rule == null or rule.channel == &"":
			continue
		GameplayMessages.listen(rule.channel, _on_message.bind(rule), rule.match_mode, null, self)
	for channel in toast_set.clear_on:
		GameplayMessages.listen(channel, func(_channel, _message): clear(), GameplayMessageRouter.Match.EXACT, null, self)


## Hands the host a message as if it had been broadcast on `channel` (one sent before the host existed, such as the
## first floor of a run). Every rule that listens to that channel sees it.
func receive(channel: StringName, message: GameplayMessage) -> void:
	if toast_set == null:
		return
	for rule in toast_set.rules:
		if rule == null:
			continue
		var partial := rule.match_mode == GameplayMessageRouter.Match.PARTIAL
		if channel == rule.channel or (partial and String(channel).begins_with(String(rule.channel) + ".")):
			_on_message(channel, message, rule)


## Removes every toast and the queue (a battle started or ended).
func clear() -> void:
	for live in _live:
		_drop(live["node"])
	_live.clear()
	_queue.clear()
	_pinned_rule = null


## The toasts on screen, oldest first.
func toasts() -> Array:
	return _live.map(func(live) -> Dictionary: return live["toast"])


## How many toasts wait (QUEUE).
func queued() -> int:
	return _queue.size()


## Presses or releases a hold action without input (tests, the console).
func hold(action: StringName, pressed: bool) -> void:
	_forced_holds[action] = pressed
	update()


## Moves the toast clock forward (tests) and updates.
func advance(seconds: float) -> void:
	_clock_offset += seconds
	update()


func _process(_delta: float) -> void:
	if _listening:
		update()


## Expires old toasts, shows waiting ones and follows the hold actions.
func update() -> void:
	var now := _now()
	for live in _live.duplicate():
		if live["until"] >= 0.0 and live["until"] <= now:
			_remove(live)
	_update_hold()
	_show_waiting()


func _on_message(_channel: StringName, message: GameplayMessage, rule: UIToastRule) -> void:
	if not rule.matches(message):
		return
	_latest[rule] = message
	var toast := _make(rule, message)
	if toast_set.stack == UIToastSet.Stack.STACK:
		_show(toast)
		var unpinned := _live.filter(func(live) -> bool: return live["until"] >= 0.0)
		while unpinned.size() > maxi(toast_set.max_visible, 1):
			_remove(unpinned.pop_front())
		return
	_queue.append(toast)
	while _queue.size() > maxi(toast_set.max_queued, 0):
		var drop := 0
		for index in _queue.size():
			if _queue[index]["priority"] < _queue[drop]["priority"]:
				drop = index
		_queue.remove_at(drop)
	_show_waiting()


func _make(rule: UIToastRule, message: GameplayMessage, pinned: bool = false) -> Dictionary:
	var toast := rule.format(message)
	toast["variation"] = rule.variation
	toast["seconds"] = rule.seconds
	toast["priority"] = rule.priority
	toast["sound"] = rule.sound
	toast["pinned"] = pinned
	return toast


func _show_waiting() -> void:
	if toast_set == null or toast_set.stack != UIToastSet.Stack.QUEUE:
		return
	while not _queue.is_empty() and _live.size() < maxi(toast_set.max_visible, 1):
		_show(_queue.pop_front())


func _show(toast: Dictionary) -> void:
	var node := _entry(toast)
	var until := -1.0 if toast["pinned"] else _now() + float(toast["seconds"])
	_live.append({"toast": toast, "node": node, "until": until})
	if StringName(toast.get("sound", &"")) != &"" and is_inside_tree():
		get_tree().call_group("sound_board", "play", String(toast["sound"]))
	toast_shown.emit(toast)


func _update_hold() -> void:
	if toast_set == null:
		return
	var held: UIToastRule = null
	for rule in toast_set.rules:
		if rule != null and rule.hold_action != &"" and _is_held(rule.hold_action) and _latest.has(rule):
			held = rule
			break
	if held == _pinned_rule:
		return
	for live in _live.duplicate():
		if live["until"] < 0.0:
			_remove(live)
	_pinned_rule = held
	if held != null:
		_show(_make(held, _latest[held], true))
	hold_changed.emit(held != null)


func _is_held(action: StringName) -> bool:
	if _forced_holds.has(action):
		return _forced_holds[action]
	return InputMap.has_action(action) and Input.is_action_pressed(action)


func _remove(live: Dictionary) -> void:
	_live.erase(live)
	_drop(live["node"])


func _drop(node: Node) -> void:
	if not is_instance_valid(node):
		return
	if node.has_method("leave"):
		node.leave()
	else:
		node.queue_free()


func _entry(toast: Dictionary) -> Node:
	var parent: Node = get_node_or_null(container) if not container.is_empty() else self
	if parent == null:
		parent = self
	var node: Node
	if toast_set.entry_scene != null:
		node = toast_set.entry_scene.instantiate()
	else:
		var label := Label.new()
		var parts := [toast["kicker"], toast["title"], toast["subtitle"]].filter(func(part) -> bool: return part != "")
		label.text = " · ".join(PackedStringArray(parts))
		node = label
	parent.add_child(node)
	if node.has_method("set_item"):
		node.set_item(toast, ctx)
	return node


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0 + _clock_offset
