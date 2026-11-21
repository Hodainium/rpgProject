## Spec ff7-ui 2.9 (F14): Use Item and Use Ability, one menu screen with two modes (payload {"mode": "item" or
## "ability"}). Use Item: pick an item from the list, then a party member at the bottom. Use Ability: pick a party member
## first, then one of their abilities, then a target if it needs one. Battle-only entries are greyed; the usage label
## comes from the Ability.Usage.* tags (AbilityHint). Uses go through RunController.use_field (logged). Chests are
## opened in their room, from the pickup panel (spec floor-chests; keys-and-gear D9 superseded). Back steps back one stage.
extends DemoMenuFrame

enum Stage { MEMBER, LIST, TARGET }

@export var mode: String = "item"
@export var item_title: String = "USE ITEM"
@export var ability_title: String = "USE ABILITY · %s"
@export var choose_member_name: String = "Use Ability"
@export var choose_member_text: String = "Choose a party member below, then one of their abilities."
@export var choose_target_text: String = "Choose a party member below."
@export var held_format: String = "Held by: %s"
@export var used_format: String = "%s · used on %s"
@export var used_all_format: String = "%s · used on the party"
@export var empty_text: String = "Nothing to use."

var _stage: Stage = Stage.LIST
var _member: int = 0
var _picked: Dictionary = {}
var _busy: bool = false
## "<slot>/<ability>" of each entry in the list, in order (spec ui-feedback: the row a refusal shakes).
var _pool_keys: Array[String] = []


func on_pushed(payload: Dictionary) -> void:
	mode = str(payload.get("mode", mode))
	_stage = Stage.MEMBER if mode == "ability" else Stage.LIST


func bind(context: UIContext) -> void:
	context.on_run(self, &"party_changed", func(): queue_refresh())
	UIFlash.listen(self, _refused)


## Spec ui-feedback row 13: the member's SP bar (SP short) or row (a bad target), or the ability's row.
func _refused(data: Dictionary) -> Array:
	if data.get(UIRefusal.TARGET) == UIRefusal.COMMAND:
		var row := UIFlash.entry(%Pool, _pool_keys.find("%d/%s" % [int(data.get("slot", 0)), data.get("ability", "")]))
		return [row] if row != null else []
	return DemoPartyRows.refused_controls(%Rows, ctx.run if ctx != null else null, data)


func handles_back() -> bool:
	match _stage:
		Stage.TARGET:
			_stage = Stage.LIST
			_picked = {}
		Stage.LIST:
			if mode != "ability":
				return false
			_stage = Stage.MEMBER
		Stage.MEMBER:
			return false
	refresh()
	return true


func refresh() -> void:
	if ctx == null or ctx.run == null or ctx.run.state == null or _busy:
		return
	var catalog := ctx.run.field_catalog()
	var entries: Array = []
	_pool_keys.clear()
	if _stage != Stage.MEMBER:
		for entry in catalog:
			if (mode == "item") != (entry["item"] != &""):
				continue
			if mode == "ability" and entry["slot"] != _member:
				continue
			_pool_keys.append("%d/%s" % [entry["slot"], entry["ability"]])
			entries.append({"text": entry["name"], "detail": entry["hint"]["usage"],
				"disabled": not entry["usable"] or _stage == Stage.TARGET,
				"hover": _describe_entry.bind(entry), "action": _pick.bind(entry)})
	%ListTitle.text = item_title if mode == "item" else ability_title % _member_name(_member).to_upper()
	%Pool.set_items(entries)
	%Empty.text = choose_target_text if _stage == Stage.MEMBER else empty_text
	%Empty.visible = entries.is_empty()
	%Rows.set_items(DemoPartyRows.items(ctx.run, _row_extra))
	match _stage:
		Stage.MEMBER:
			describe({"name": choose_member_name, "text": choose_member_text})
		Stage.TARGET:
			_describe_entry(_picked, choose_target_text)
		Stage.LIST:
			if not entries.is_empty():
				entries[0]["hover"].call()


func _row_extra(member: Dictionary) -> Dictionary:
	var slot: int = member["slot"]
	var pickable := false
	if _stage == Stage.MEMBER:
		pickable = member["alive"]
	elif _stage == Stage.TARGET:
		pickable = _picked.get("targets", []).has(slot)
	return {"pickable": pickable, "on_pick": _on_member.bind(slot)}


func _describe_entry(entry: Dictionary, extra: String = "") -> void:
	var hint: Dictionary = entry.get("hint", {})
	var cost := str(hint.get("cost", ""))
	describe({"name": entry.get("name", ""), "kind": str(hint.get("usage", "")),
		"text": str(hint.get("description", "")),
		"extra": extra if extra != "" else (held_format % _member_name(entry["slot"]) if mode == "item" else cost)})


func _pick(entry: Dictionary) -> void:
	if entry["targets"].is_empty():
		_use(entry, 0)
		return
	_picked = entry
	_stage = Stage.TARGET
	refresh()


func _on_member(slot: int) -> void:
	if _stage == Stage.MEMBER:
		_member = slot
		_stage = Stage.LIST
		refresh()
	elif _stage == Stage.TARGET:
		_use(_picked, slot)


func _use(entry: Dictionary, target: int) -> void:
	_busy = true
	var problem: Array = await ctx.run.use_field(entry["slot"], entry["ability"], target)
	_busy = false
	_picked = {}
	_stage = Stage.LIST
	refresh()
	if not problem.is_empty():
		# After the redraw, so the flash lands on the rows that stay (the state is the same: a refusal changes nothing).
		ctx.main.refuse("%s: %s" % problem, &"", UIRefusal.for_field_use(ctx.run, str(problem[0]), entry["slot"],
			entry["ability"], int(entry.get("hint", {}).get("spCostX100", 0)), target))
	else:
		ctx.main.show_message(used_format % [entry["name"], _member_name(target)] if target > 0
			else used_all_format % entry["name"])


func _member_name(slot: int) -> String:
	var member := ctx.run.state.member(slot) if ctx.run != null else {}
	if member.is_empty():
		return ""
	var character: UnitDefinition = ctx.run.content.units.get(member["character"])
	return character.display_name if character != null else String(member["character"])
