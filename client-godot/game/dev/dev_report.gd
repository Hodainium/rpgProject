## The run as data and text, for the console's `state` and `map` and the script runner's JSON (spec dev-tools 2.6).
## HP/MP/ult charge and their maxima are read through GAS (RunController.party_stats), like the screens.
class_name DevReport
extends RefCounted


static func state_of(run: RunController) -> Dictionary:
	if run == null or run.state == null:
		return {"run": null}
	var state := run.state
	var stats := run.party_stats()
	var party: Array = []
	for member in state.party:
		party.append({"slot": member["slot"], "character": String(member["character"]), "alive": member["alive"],
			"stats": stats.get(member["slot"], {}), "items": _strings(member["items"]),
			"useSlots": member["use_slots"].map(func(slot) -> String: return "%s:%d" % [slot["item"], slot["cooldown"]]),
			"equipment": member["equipment"].values().map(func(id) -> String: return String(id)),
			"gear": _gear(run, member),
			"skills": _strings(member["skills"])})
	var data := {
		"seed": RunSeeds.display(state.run_seed), "seedDecimal": str(state.run_seed), "status": state.status,
		"floor": state.floor_index, "chapter": String(state.chapter_id), "cell": state.current_cell, "coins": state.coins,
		"party": party, "event": state.event.duplicate(), "battle": not run.pending_battle.is_empty(),
		"armor": _strings(state.armor), "lastBattle": run.battle_log.duplicate(true),
		"dev": state.dev, "sandbox": state.sandbox, "runHash": state.run_hash(),
		"warnings": Array(run.warnings), "runnerError": run.runner_error,
	}
	if (run.structure != null and run.structure.uses_keys()) or state.keys > 0 or state.golden_key or state.chest_serial > 0:
		# Spec keys-and-gear 3.5: keys and chests, only on runs that have them (older reports are unchanged).
		data["keys"] = state.keys
		data["goldenKey"] = state.golden_key
		data["chests"] = run.chests().map(func(chest: Dictionary) -> Dictionary: return {"number": chest["index"] + 1,
			"chest": String(chest["chest"]), "needsKey": chest["needs_key"], "canOpen": chest["can_open"]})
	return data


## Spec item-pass 3.5: every equipment slot of the run, filled or not: {slot tag: equipment id or null}.
static func _gear(run: RunController, member: Dictionary) -> Dictionary:
	var gear := {}
	for slot_tag in run.equipment_slots():
		var piece: Variant = member["equipment"].get(slot_tag)
		gear[String(slot_tag)] = String(piece) if piece != null else null
	return gear


static func state_text(run: RunController) -> String:
	var data := state_of(run)
	if data.has("run"):
		return "no run"
	var lines := PackedStringArray([
		"seed %s (%s)  %s  floor %d (%s)  cell %d  coins %d%s%s" % [data["seed"], data["seedDecimal"], data["status"],
			data["floor"], data["chapter"], data["cell"], data["coins"], "  DEV" if data["dev"] else "",
			"  SANDBOX" if data["sandbox"] else ""]])
	for member in data["party"]:
		var stats: Dictionary = member["stats"]
		lines.append("  P%d %s %s  hp %s/%s  mp %s/%s  ult %s/%s  items [%s]  use [%s]  gear [%s]" % [member["slot"],
			member["character"], "" if member["alive"] else "DEAD", _typed(stats, "hp"), _typed(stats, "max_hp"),
			_typed(stats, "mp"), _typed(stats, "max_mp"), _typed(stats, "energy"), _typed(stats, "max_energy"),
			", ".join(member["items"]), ", ".join(member["useSlots"]), ", ".join(member["equipment"])])
	if not data["armor"].is_empty():
		lines.append("  armor inventory [%s]" % ", ".join(data["armor"]))
	if data.has("keys"):
		lines.append("  keys %d%s  chests [%s]" % [data["keys"], " + golden key" if data["goldenKey"] else "",
			", ".join(data["chests"].map(func(chest: Dictionary) -> String: return "%d:%s" % [chest["number"], chest["chest"]]))])
	if data["battle"]:
		lines.append("  in battle")
	if not data["event"].is_empty():
		lines.append("  event %s page %d" % [data["event"]["event"], data["event"]["page"]])
	return "\n".join(lines)


## The floor as text: one line per room (index, cell, role, room, content, pickups, visited/cleared, enterable).
static func map_text(run: RunController) -> String:
	if run == null or run.state == null or run.state.map == null:
		return "no floor"
	var map := run.state.map
	var lines := PackedStringArray(["floor %d, %d rooms, you are in %d" % [run.state.floor_index, map.cells.size(),
		run.state.current_cell]])
	for index in map.sorted_indices():
		var data: Dictionary = map.cells[index]
		var content: Dictionary = data["content"]
		var what := ""
		match content["kind"]:
			"encounter":
				what = "battle %s" % content["encounter"]
			"event":
				what = "event %s" % content["event"]
		var pickups := PackedStringArray()
		for pickup in data["pickups"]:
			if not pickup["taken"]:
				pickups.append("%d:%s%s%s%s" % [pickup["placement"], pickup["item"],
					" [armor]" if pickup.get("kind", "") == FloorGenerator.EQUIPMENT_KIND else "",
					" x%d" % pickup["keys"] if pickup.get("kind", "") == FloorGenerator.KEYS_KIND else "",
					"($%d)" % pickup["price"] if pickup["price"] > 0 else ""])
		lines.append("  %2d %s %-7s %-24s %-28s %s%s%s%s%s" % [index, data["cell"], data["role"], data["room"], what,
			"visited " if data["visited"] else "", "cleared " if data["cleared"] else "", "LOCKED " if run.room_locked(index) else "",
			"ENTER " if run.can_enter(index) else "", "pickups " + ", ".join(pickups) if not pickups.is_empty() else ""])
	return "\n".join(lines)


## A ×100 attribute as typed: 100000 → "1000", 525 → "5.25".
@warning_ignore("integer_division")
static func _typed(stats: Dictionary, name: String) -> String:
	if not stats.has(name) or stats[name] == null:
		return "-"
	var value := int(stats[name])
	return str(value / 100) if value % 100 == 0 else "%.2f" % (value / 100.0)


static func _strings(values: Array) -> Array:
	return values.map(func(value) -> String: return String(value))
