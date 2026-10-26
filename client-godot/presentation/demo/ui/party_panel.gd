## HUD panel (UI.Slot.Hud.Left while UI.State.Run): one member_card per party member: level and XP, LEVEL UP! after
## a rise (until the next room), HP/MP/ult charge (live during a battle), items, use slots, equipment.
extends UIScreen

var _battle: Battle
## slot -> level when the party last entered a room.
var _seen_levels: Dictionary = {}


func bind(context: UIContext) -> void:
	for signal_name in [&"party_changed", &"floor_entered", &"room_entered", &"room_cleared", &"battle_requested",
			&"battle_finished", &"event_page_shown"]:
		context.on_run(self, signal_name, func(_a = null, _b = null): refresh.call_deferred())
	context.on_run(self, &"battle_started", _on_battle_started)
	context.on_run(self, &"battle_finished", func(_outcome): _battle = null)
	for signal_name in [&"room_entered", &"floor_entered"]:
		context.on_run(self, signal_name, func(_a = null): _see_levels())
	context.run_changed.connect(func(_run): _seen_levels.clear())


func _on_battle_started(battle: Battle) -> void:
	_battle = battle
	battle.turn_started.connect(func(_unit, _turn): refresh.call_deferred())
	battle.execution_resolved.connect(func(_unit, _row, _targets): refresh.call_deferred())
	refresh.call_deferred()


func _see_levels() -> void:
	if ctx.run != null and ctx.run.state != null:
		for member in ctx.run.state.party:
			_seen_levels[member["slot"]] = int(member["level"])


func refresh() -> void:
	var run := ctx.run
	if run == null or run.state == null:
		return
	var battle := _battle if is_instance_valid(_battle) else null
	var stats := run.party_stats() if battle == null else {}
	var items: Array = []
	for member in run.state.party:
		var unit := battle.unit_by_id(StringName("P%d" % member["slot"])) if battle != null else null
		if not _seen_levels.has(member["slot"]):
			_seen_levels[member["slot"]] = int(member["level"])
		items.append({
			"run": run, "member": member,
			"values": RunController.unit_stats(unit) if unit != null else stats.get(member["slot"], {}),
			"alive": unit.alive if unit != null else member["alive"],
			"leveled": int(member["level"]) > _seen_levels[member["slot"]],
		})
	%Members.set_items(items)
