## Spec ff7-ui 2.12 (shared): the member_row items for the run's party outside battle (the party strip, Use Item, Use
## Ability, Status), from RunController.party_stats(). `extra(member) -> Dictionary` adds per-row keys (pickable,
## on_pick, selected, on_hover…).
class_name DemoPartyRows
extends RefCounted

const DEAD_CHIP := "DOWN"


static func items(run: RunController, extra: Callable = Callable()) -> Array:
	var rows: Array = []
	if run == null or run.state == null:
		return rows
	var stats := run.party_stats()
	for member in run.state.party:
		var values: Dictionary = stats.get(member["slot"], {})
		var character: UnitDefinition = run.content.units.get(member["character"])
		var max_energy := int(values.get(BattleUnit.MAX_ENERGY, 0))
		var row := {
			"name": character.display_name if character != null else String(member["character"]),
			"level": int(member["level"]),
			"chips": [] if member["alive"] else [DEAD_CHIP],
			"hp": int(values.get(BattleUnit.HP, 0)) / 100, "hp_max": int(values.get(BattleUnit.MAX_HP, 0)) / 100,
			"mp": int(values.get(BattleUnit.MP, 0)) / 100, "mp_max": int(values.get(BattleUnit.MAX_MP, 0)) / 100,
			"ult": clampi(int(values.get(BattleUnit.ENERGY, 0)) * 100 / max_energy, 0, 100) if max_energy > 0 else 0,
			"show_ult": false,
		}
		if extra.is_valid():
			row.merge(extra.call(member), true)
		rows.append(row)
	return rows


## Spec ui-feedback 2.2: the parts of `rows` (a list of these items) a refusal names by party slot ("slot" or "slots"):
## the member's row for `member` and `member_items`, its SP bar (a pulse) for `sp`.
static func refused_controls(rows: Node, run: RunController, data: Dictionary) -> Array:
	var target := str(data.get(UIRefusal.TARGET, ""))
	if run == null or run.state == null or not target in [UIRefusal.MEMBER, UIRefusal.MEMBER_ITEMS, UIRefusal.SP]:
		return []
	var slots: Array = data.get("slots", [data["slot"]] if data.has("slot") else [])
	var hits: Array = []
	for index in run.state.party.size():
		if not slots.has(run.state.party[index]["slot"]):
			continue
		var row := UIFlash.entry(rows, index)
		if row != null:
			hits.append({"control": row.get_node("%Mp"), "shake": false} if target == UIRefusal.SP else row)
	return hits
