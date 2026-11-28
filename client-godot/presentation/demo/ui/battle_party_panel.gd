## Spec ff7-ui 2.3 / 2.5 (HUD panel, UI.Slot.Hud.Bottom.Left while UI.State.Run.Battle): the FF7 party window. One
## member_row per party unit: the pointer on the unit whose turn it is, statuses, HP, MP, the ult bar and the ULT
## button, which works at any time (spec ult-interrupts: the press fires at the next ult window). The command window
## handles the press (two ults: a chooser; a single-target ult: the target).
extends UIBattlePanel

@export var dead_chip: String = "DOWN"
@export var broken_chip: String = "BROKEN"
@export var downed_chip: String = "KNOCKED DOWN"

## Spec skill-points: the ability hovered in the command window ({"unit": id, "sp": whole SP}), previewed on that
## member's SP bar; {} when nothing costed is hovered.
var _preview: Dictionary = {}


func bind(context: UIContext) -> void:
	super(context)
	GameplayMessages.listen(GameplayMessageRouter.UI_ULT_PRESSED, func(_channel, _message): changed(),
		GameplayMessageRouter.Match.EXACT, null, self)
	GameplayMessages.listen(GameplayMessageRouter.UI_HINT, func(_channel, message): _on_hint(message),
		GameplayMessageRouter.Match.EXACT, null, self)
	UIFlash.listen(self, _refused)


## Spec ui-feedback rows 15, 16: the caster's SP bar pulses (SP short); a refused ult flashes its ULT button; a party unit
## named as a target or a dead caster flashes its row.
func _refused(data: Dictionary) -> Array:
	if battle == null or not data.has("unit"):
		return []
	var unit_id := StringName(str(data["unit"]))
	var party := battle.units().filter(func(unit: BattleUnit) -> bool: return unit.is_party())
	var index := party.find_custom(func(unit: BattleUnit) -> bool: return unit.unit_id == unit_id)
	var row := UIFlash.entry(%Rows, index)
	if row == null:
		return []
	match str(data.get(UIRefusal.TARGET, "")):
		UIRefusal.SP:
			return [{"control": row.get_node("%Mp"), "shake": false}]
		UIRefusal.COMMAND:
			var ult := StringName(str(data.get("ability", "")))
			var unit: BattleUnit = party[index]
			if unit.ultimate_abilities().any(func(ability) -> bool: return ability.ability_tag == ult):
				return [row.get_node("%Ult")]
		UIRefusal.UNIT_TARGET, UIRefusal.MEMBER:
			return [row]
	return []


func _on_hint(message: VerbMessage) -> void:
	var sp := int(message.data.get("spCost", 0))
	var next := {"unit": StringName(str(message.data.get("unit", ""))), "sp": sp} if sp > 0 else {}
	if next != _preview:
		_preview = next
		changed()


func on_recorder(new_recorder: ActionRecorder) -> void:
	new_recorder.action_requested.connect(func(_unit, _turn): changed())


func battle_changed() -> void:
	var queued := {}
	if recorder != null:
		for press in recorder.pending_ults():
			queued[press["unit"]] = true
	var rows: Array = []
	for unit in battle.units():
		if unit.is_party():
			rows.append(_row(unit, queued.has(unit.unit_id)))
	%Rows.set_items(rows)


func _row(unit: BattleUnit, queued: bool) -> Dictionary:
	var ready := unit.alive and unit.ultimate_abilities().any(
		func(ult: BattleAbility) -> bool: return unit.asc.can_activate_ability(ult))
	var max_energy := unit.stat(BattleUnit.MAX_ENERGY) if unit.asc.has_attribute(BattleUnit.MAX_ENERGY) else 0
	var energy := unit.stat(BattleUnit.ENERGY) if unit.asc.has_attribute(BattleUnit.ENERGY) else 0
	return {
		"name": _name(unit),
		"chips": _chips(unit),
		"hp": unit.stat(BattleUnit.HP) / 100, "hp_max": unit.stat(BattleUnit.MAX_HP) / 100,
		"mp": unit.stat(BattleUnit.MP) / 100 if unit.asc.has_attribute(BattleUnit.MP) else 0,
		"mp_max": unit.stat(BattleUnit.MAX_MP) / 100 if unit.asc.has_attribute(BattleUnit.MAX_MP) else 0,
		"mp_preview": int(_preview.get("sp", 0)) if _preview.get("unit") == unit.unit_id else 0,
		"ult": clampi(energy * 100 / max_energy, 0, 100) if max_energy > 0 else 0,
		"active": recorder != null and recorder.waiting_for == unit.unit_id,
		"show_ult": not unit.ultimate_abilities().is_empty() or _auto_ult(unit),
		"ult_state": "auto" if _auto_ult(unit) and unit.ultimate_abilities().is_empty() else (
			"queued" if queued else ("ready" if ready else "off")),
		"on_ult": func(): GameplayMessages.broadcast(GameplayMessageRouter.UI_ULT_PRESSED,
			VerbMessage.make(&"Verb.Press", unit.unit_id, &"")),
	}


## Spec second-pack D29: the unit's ult casts itself when its ult bar is full (a meter ability on the ult charge).
func _auto_ult(unit: BattleUnit) -> bool:
	return unit.abilities().any(func(ability: BattleAbility) -> bool:
		return ability.is_meter() and ability.meter_attribute == BattleUnit.ENERGY)


func _chips(unit: BattleUnit) -> Array:
	var chips: Array = []
	if not unit.alive:
		chips.append(dead_chip)
	if unit.asc.has_tag_exact(Battle.BROKEN_TAG):
		chips.append(broken_chip)
	if unit.asc.has_tag_exact(Battle.DOWNED_TAG):
		chips.append(downed_chip)
	for status in merged_statuses(unit.statuses()):
		var tag := String(status["tag"])
		var text := tag.get_slice(".", tag.get_slice_count(".") - 1).to_upper()
		if int(status["stacks"]) > 1:
			text += "×%d" % status["stacks"]
		if int(status["turns"]) >= 0:
			text += " %d" % status["turns"]
		chips.append(text)
	return chips


## One entry per status tag (user, 2026-11-27): several effects granting the same status (Blood Rite, Crimson Communion and Night
## Feast all give Status.Buff.Lifesteal; Howl and Moonfall Frenzy both give Wolf Form) show as one chip, with the most turns left
## (-1, no end, wins). Stacks: the same effect from several sources adds up (the Bloodletter's 3 Bleed and Vlad's 2 show ×5, as all
## five tick), and of different effects granting the tag the highest counts (three lifesteal buffs show no ×3). The number after a
## chip's name is the turns left, not a rank. Keeps the input's tag order.
static func merged_statuses(statuses: Array) -> Array[Dictionary]:
	var merged: Array[Dictionary] = []
	var at := {}
	var per_effect := {}  # tag -> {effect path -> stacks summed over its sources}
	for status in statuses:
		var tag := String(status["tag"])
		var effect := String(status.get("effect", ""))
		var turns := int(status["turns"])
		if not at.has(tag):
			at[tag] = merged.size()
			merged.append({"tag": tag, "turns": turns, "stacks": 0})
			per_effect[tag] = {}
		var entry: Dictionary = merged[at[tag]]
		if entry["turns"] >= 0 and (turns < 0 or turns > entry["turns"]):
			entry["turns"] = turns
		var sums: Dictionary = per_effect[tag]
		var key := effect if effect != "" else "#%d" % sums.size()  # an effect with no file counts on its own
		sums[key] = int(sums.get(key, 0)) + int(status["stacks"])
		entry["stacks"] = maxi(entry["stacks"], sums[key])
	return merged


static func _name(unit: BattleUnit) -> String:
	if unit == null or unit.definition == null:
		return "?"
	return unit.definition.display_name if unit.definition.display_name != "" else String(unit.definition.id)
