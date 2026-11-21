## Spec ff7-ui 2.3–2.6 (HUD panel, UI.Slot.Hud.Bottom.Right while UI.State.Run.Battle): the FF7 command window.
## COMMANDS is a vertical list: Attack (the unit's Ability.Type.Basic ability; hidden without one), Ability, Block (the
## unit's Ability.Role.Guard ability; hidden without one) and Item. Ability, Item and a two-ult chooser open a LIST in
## the same window; a pick that needs a target opens TARGET. Back (the button or Esc) steps back a page.
## Hovering an entry sends its hint (Message.Ui.Hint) when HINT is on; the target prompt is always sent.
## Footer: HINT, Auto, battle speed and Skip (presentation only; replay never depends on them).
extends UIBattlePanel

enum Page { IDLE, COMMANDS, LIST, TARGET }

const BASIC_TAG: StringName = &"Ability.Type.Basic"
const GUARD_TAG: StringName = &"Ability.Role.Guard"

@export var speeds: Array[float] = [1.0, 2.0, 3.0]
@export var speed_format: String = "SPEED %d×"
@export var hint_format: String = "HINT %s"
@export var attack_text: String = "Attack"
@export var ability_text: String = "Ability"
@export var block_text: String = "Block"
@export var item_text: String = "Item"
@export var ability_title: String = "ABILITY · %s"
@export var item_title: String = "ITEM · %s"
@export var ult_title: String = "ULT · %s"
@export var target_title: String = "TARGET · %s"
@export var prompt_format: String = "%s · choose a target"
@export var item_detail: String = "[item]"
@export var down_suffix: String = " (down)"
@export var queued_format: String = "%s: %s at the next chance"

var _page: Page = Page.IDLE
## The party unit waiting for a decision, or null.
var _unit: BattleUnit
## "ability", "item" or "ult" while the LIST page is open.
var _list_kind: String = ""
## The ability waiting for a target, and who casts it (an ult's caster may not be the waiting unit).
var _pending: BattleAbility
var _caster: BattleUnit
var _ult_flow: bool = false
## The TARGET page was opened from a LIST (Back returns there).
var _target_from_list: bool = false
var _speed_index: int = 0
var _hints: bool = true
## Spec ui-feedback: what each unit last tried ({unit id: {"ability", "target"}}), so a rejection names its row; and
## what each entry of the open page stands for (an ability tag, "ability" / "item" for the two lists, or a target id).
var _tries: Dictionary = {}
var _entry_keys: Array = []
## A turn action's refusal whose rows flash once the battle asks the unit again ({"unit_id", "data", "ability"}).
var _flash_next: Dictionary = {}


func bind(context: UIContext) -> void:
	super(context)
	%Skip.toggled.connect(func(on):
		if gate != null:
			gate.skip_all = on)
	%Auto.toggled.connect(_on_auto_toggled)
	%Auto.set_pressed_no_signal(context.main.auto_battle)
	%Speed.pressed.connect(_on_speed_pressed)
	%Hint.toggled.connect(_on_hint_toggled)
	%Back.pressed.connect(func(): _back())
	%Skip.button_pressed = GameMain.load_setting("settings", "skip_animations", false)
	_hints = GameMain.load_setting("settings", "battle_hints", true)
	%Hint.set_pressed_no_signal(_hints)
	_show_hint_toggle()
	_speed_index = maxi(speeds.find(float(GameMain.load_setting("settings", "battle_speed", speeds[0]))), 0)
	_show_speed()
	GameplayMessages.listen(GameplayMessageRouter.UI_ULT_PRESSED, _on_ult_pressed, GameplayMessageRouter.Match.EXACT,
		VerbMessage, self)
	UIFlash.listen(self, _refused)


## Spec ui-feedback rows 15, 16: the skill's row shakes (SP short or it can't be used now), a target's row on the TARGET
## page shakes.
func _refused(data: Dictionary) -> Array:
	var target := str(data.get(UIRefusal.TARGET, ""))
	var key: Variant = null
	if target in [UIRefusal.SP, UIRefusal.COMMAND] and _unit != null and StringName(str(data.get("unit", ""))) == _unit.unit_id:
		var tag := StringName(str(data.get("ability", "")))
		key = tag
		if not _entry_keys.has(tag) and _page == Page.COMMANDS:
			# A skill or an item sits behind its list's row; an ult has no row here (its ULT button flashes).
			if _items(_unit).any(func(ability) -> bool: return ability.ability_tag == tag):
				key = "item"
			elif _skills(_unit).any(func(ability) -> bool: return ability.ability_tag == tag):
				key = "ability"
	elif target == UIRefusal.UNIT_TARGET and _page == Page.TARGET:
		key = StringName(str(data.get("unit", "")))
		if not _entry_keys.has(key):
			return [%Title]  # that target is gone from the list: the page's title shakes
	var row := UIFlash.entry(%Entries, _entry_keys.find(key)) if key != null else null
	return [row] if row != null else []


func on_deactivated() -> void:
	Engine.time_scale = 1.0
	_clear_hint()


func handles_back() -> bool:
	if _page == Page.LIST or _page == Page.TARGET:
		_back()
		return true
	return false


func on_recorder(new_recorder: ActionRecorder) -> void:
	%Auto.set_pressed_no_signal(ctx.main.auto_battle)
	if %Skip.button_pressed and gate != null:
		gate.skip_all = true  # never turns off a skip GameMain set (the script runner)
	new_recorder.action_requested.connect(_on_action_requested)
	new_recorder.action_rejected.connect(_on_action_rejected)
	if new_recorder.waiting_for != &"" and battle != null:
		_on_action_requested(new_recorder.waiting_for, 0)


func on_battle(_battle: Battle) -> void:
	Engine.time_scale = speeds[_speed_index]
	if recorder != null and recorder.waiting_for != &"" and _unit == null:
		_on_action_requested(recorder.waiting_for, 0)


func on_battle_end() -> void:
	_tries.clear()  # unit ids repeat in the next battle
	_flash_next = {}
	_unit = null
	_pending = null
	_caster = null
	_ult_flow = false
	_set_page(Page.IDLE)
	Engine.time_scale = 1.0


## Redraw the open page (costs and tags may have changed).
func battle_changed() -> void:
	_draw()


func _on_action_requested(unit_id: StringName, _turn: int) -> void:
	if battle == null:
		return
	_forget_turn_try(unit_id)
	_unit = battle.unit_by_id(unit_id)
	_ult_flow = false
	var refused := _flash_next
	_flash_next = {}
	if refused.get("unit_id") == unit_id and refused.get("ability") != null:
		# Row 16: back on the TARGET page of the same skill, so the refused target's row is there to shake.
		_target_from_list = refused.get("from_list", false)  # Back returns where the pick came from
		_list_kind = refused.get("list_kind", _list_kind)
		_pending = refused["ability"]
		_caster = _unit
		_set_page(Page.TARGET)
		_send_prompt(_pending)
	else:
		_set_page(Page.COMMANDS)
	if refused.get("unit_id") == unit_id:
		for hit in _refused(refused["data"]):
			UIFlash.refuse(hit)


func _on_action_rejected(unit_id: StringName, reason: String, detail: String) -> void:
	var tried: Dictionary = _tries.get(unit_id, {})
	var caster := battle.unit_by_id(unit_id) if battle != null else null
	var ability: BattleAbility = caster.ability_by_tag(tried["ability"]) if caster != null and tried.has("ability") else null
	var data := UIRefusal.for_battle(reason, caster, ability, tried.get("target", &""))
	if data.is_empty() and caster != null and tried.has("ability"):
		data = UIRefusal.make(UIRefusal.COMMAND, {"unit": unit_id, "ability": tried["ability"]})
	data.merge({"reason": reason, "detail": detail})
	var retarget: bool = data.get(UIRefusal.TARGET) == UIRefusal.UNIT_TARGET and ability != null and ability.needs_target() \
		and not caster.ultimate_abilities().has(ability)
	if battle != null and recorder != null and recorder.waiting_for == unit_id:
		_unit = caster
		_set_page(Page.COMMANDS)  # a press refused while the unit waits (a queued ult): its rows are shown now
	elif caster != null and caster.is_party() and not caster.ultimate_abilities().has(ability):
		# A turn action refused: the battle asks this unit again at once; its rows flash on that redraw.
		_flash_next = {"unit_id": unit_id, "data": data, "ability": ability if retarget else null,
			"from_list": _target_from_list, "list_kind": _list_kind}
	ctx.main.refuse("%s: %s" % [reason, detail], unit_id, data)  # the sound, the party window; the rows shown now


## Auto takes a waiting decision at once: clear the choices first, since the battle may run on inside the hand-over.
func _on_auto_toggled(on: bool) -> void:
	if on and _unit != null:
		_unit = null
		_set_page(Page.IDLE)
	ctx.main.auto_battle = on


func _on_speed_pressed() -> void:
	_speed_index = (_speed_index + 1) % speeds.size()
	_show_speed()


func _show_speed() -> void:
	%Speed.text = speed_format % int(speeds[_speed_index])
	if battle != null:
		Engine.time_scale = speeds[_speed_index]


func _on_hint_toggled(on: bool) -> void:
	_hints = on
	GameMain.save_setting("settings", "battle_hints", on)
	_show_hint_toggle()
	if not on and _page != Page.TARGET:
		_clear_hint()


func _show_hint_toggle() -> void:
	%Hint.text = hint_format % ("ON" if _hints else "OFF")


# --- Pages ----------------------------------------------------------------------------------------------------------

func _set_page(page: Page) -> void:
	_page = page
	if page != Page.TARGET:
		_clear_hint()
	_draw()


func _draw() -> void:
	%Back.visible = _page == Page.LIST or _page == Page.TARGET
	match _page:
		Page.IDLE:
			%Title.text = ""
			_entry_keys = []
			%Entries.set_items([])
		Page.COMMANDS:
			_draw_commands()
		Page.LIST:
			_draw_list()
		Page.TARGET:
			_draw_targets()


func _draw_commands() -> void:
	if _unit == null:
		_set_page(Page.IDLE)
		return
	%Title.text = _name(_unit).to_upper()
	var basic := _first_with(_unit, BASIC_TAG)
	var guard := _first_with(_unit, GUARD_TAG)
	var items: Array = [
		{"text": attack_text, "variation": &"CommandButton", "hidden": basic == null,
			"disabled": basic != null and not _unit.asc.can_activate_ability(basic), "action": func(): _pick(_unit, basic)},
		{"text": ability_text, "variation": &"CommandButton", "disabled": _skills(_unit).is_empty(),
			"action": func(): _open_list("ability")},
		{"text": block_text, "variation": &"CommandButton", "hidden": guard == null,
			"disabled": guard != null and not _unit.asc.can_activate_ability(guard), "action": func(): _pick(_unit, guard)},
		{"text": item_text, "variation": &"CommandButton", "disabled": _items(_unit).is_empty(),
			"action": func(): _open_list("item")},
	]
	_entry_keys = [basic.ability_tag if basic != null else &"", "ability", guard.ability_tag if guard != null else &"",
		"item"]
	%Entries.set_items(items)


func _open_list(kind: String) -> void:
	_list_kind = kind
	_set_page(Page.LIST)
	var entries := _list_abilities()
	if not entries.is_empty() and _hints:
		_send_hint(_caster_for_list(), entries[0])


func _caster_for_list() -> BattleUnit:
	return _caster if _list_kind == "ult" else _unit


func _list_abilities() -> Array:
	var caster := _caster_for_list()
	if caster == null:
		return []
	match _list_kind:
		"ability":
			return _skills(caster)
		"item":
			return _items(caster)
		"ult":
			return caster.ultimate_abilities()
	return []


func _draw_list() -> void:
	var caster := _caster_for_list()
	if caster == null:
		_set_page(Page.IDLE)
		return
	var title := ability_title if _list_kind == "ability" else (item_title if _list_kind == "item" else ult_title)
	%Title.text = title % _name(caster).to_upper()
	var items: Array = []
	_entry_keys = []
	for ability in _list_abilities():
		_entry_keys.append(ability.ability_tag)
		items.append({"text": AbilityName.of(ability),
			"detail": item_detail if caster.item_abilities.has(ability.ability_tag) else AbilityHint.cost_text(ability),
			"disabled": not caster.alive or not caster.asc.can_activate_ability(ability),
			"hover": _send_hint.bind(caster, ability), "action": _pick.bind(caster, ability)})
	%Entries.set_items(items)


func _draw_targets() -> void:
	if _pending == null or _caster == null:
		_set_page(Page.COMMANDS if _unit != null else Page.IDLE)
		return
	%Title.text = target_title % AbilityName.of(_pending)
	var items: Array = []
	_entry_keys = []
	for target in battle.target_candidates(_caster, _pending):
		_entry_keys.append(target.unit_id)
		items.append({"text": _name(target) + ("" if target.alive else down_suffix), "detail": _target_detail(target),
			"action": _choose_target.bind(target.unit_id)})
	%Entries.set_items(items)


## HP, toughness, weaknesses and statuses: what the target page needs to pick well.
func _target_detail(unit: BattleUnit) -> String:
	var parts := PackedStringArray(["HP %d/%d" % [unit.stat(BattleUnit.HP) / 100, unit.stat(BattleUnit.MAX_HP) / 100]])
	var toughness_max := unit.stat(Battle.MAX_TOUGHNESS)
	if toughness_max > 0:
		parts.append("TGH %d/%d" % [unit.stat(Battle.TOUGHNESS) / 100, toughness_max / 100])
	if unit.asc.has_tag_exact(Battle.BROKEN_TAG):
		parts.append("BROKEN")
	var weak := PackedStringArray()
	for tag in unit.asc._active_tags:
		if String(tag).begins_with("Weakness."):
			weak.append(String(tag).get_slice(".", 1))
	weak.sort()
	if not weak.is_empty():
		parts.append("weak " + ", ".join(weak))
	return " · ".join(parts)


# --- Picks ----------------------------------------------------------------------------------------------------------

func _pick(caster: BattleUnit, ability: BattleAbility) -> void:
	if ability == null:
		return
	if ability.needs_target():
		_target_from_list = _page == Page.LIST
		_pending = ability
		_caster = caster
		_set_page(Page.TARGET)
		_send_prompt(ability)
		return
	_submit(caster, ability, &"")


func _choose_target(target_id: StringName) -> void:
	_submit(_caster, _pending, target_id)


## A new decision: the unit's last turn action is settled (a queued ult press is kept: it can still be refused later).
func _forget_turn_try(unit_id: StringName) -> void:
	var tried: Dictionary = _tries.get(unit_id, {})
	var unit := battle.unit_by_id(unit_id) if battle != null else null
	if tried.has("ability") and (unit == null or not unit.ultimate_abilities().any(
			func(ult) -> bool: return ult.ability_tag == tried["ability"])):
		_tries.erase(unit_id)


func _submit(caster: BattleUnit, ability: BattleAbility, target_id: StringName) -> void:
	_tries[caster.unit_id] = {"ability": ability.ability_tag, "target": target_id}
	if ability.ability_tag in caster.ultimate_abilities().map(func(ult) -> StringName: return ult.ability_tag):
		recorder.submit_ult(caster.unit_id, ability.ability_tag, target_id)
		if recorder.pending_interrupts() > 0:
			ctx.main.show_message(queued_format % [_name(caster), AbilityName.of(ability)])
		GameplayMessages.broadcast(GameplayMessageRouter.UI_ULT_PRESSED, VerbMessage.make(&"Verb.Choose", caster.unit_id,
			target_id, 0, [ability.ability_tag]))
		_pending = null
		_caster = null
		_ult_flow = false
		_set_page(Page.COMMANDS if _unit != null and recorder.waiting_for == _unit.unit_id else Page.IDLE)
		return
	_pending = null
	_caster = null
	_unit = null
	_set_page(Page.IDLE)
	recorder.submit_action(ability.ability_tag, target_id)


func _on_ult_pressed(_channel: StringName, message: VerbMessage) -> void:
	if message.verb != &"Verb.Press" or battle == null or recorder == null:
		return
	var caster := battle.unit_by_id(message.instigator)
	if caster == null or not caster.alive:
		return
	var ready := caster.ultimate_abilities().filter(
		func(ult: BattleAbility) -> bool: return caster.asc.can_activate_ability(ult))
	if ready.is_empty():
		return
	_ult_flow = true
	_caster = caster
	if caster.ultimate_abilities().size() > 1:
		_list_kind = "ult"
		_set_page(Page.LIST)
		if _hints:
			_send_hint(caster, ready[0])
		return
	_pick(caster, ready[0])


func _back() -> void:
	if _page == Page.TARGET:
		_pending = null
		if _target_from_list:
			_set_page(Page.LIST)
		elif _ult_flow:
			_end_ult_flow()
		else:
			_set_page(Page.COMMANDS)
		return
	if _page == Page.LIST:
		if _list_kind == "ult":
			_end_ult_flow()
		else:
			_set_page(Page.COMMANDS)


func _end_ult_flow() -> void:
	_ult_flow = false
	_caster = null
	_list_kind = ""
	_set_page(Page.COMMANDS if _unit != null else Page.IDLE)


# --- Hints ----------------------------------------------------------------------------------------------------------

func _send_hint(caster: BattleUnit, ability: BattleAbility) -> void:
	if not _hints:
		return
	GameplayMessages.broadcast(GameplayMessageRouter.UI_HINT, VerbMessage.make(&"Verb.Hint", &"", &"", 0, [],
		AbilityHint.of(caster, ability)))


func _send_prompt(ability: BattleAbility) -> void:
	GameplayMessages.broadcast(GameplayMessageRouter.UI_HINT, VerbMessage.make(&"Verb.Hint", &"", &"", 0, [],
		{"prompt": prompt_format % AbilityName.of(ability)}))


func _clear_hint() -> void:
	GameplayMessages.broadcast(GameplayMessageRouter.UI_HINT, VerbMessage.make(&"Verb.Hint", &"", &""))


# --- Helpers --------------------------------------------------------------------------------------------------------

## The unit's action abilities that are neither its Attack, its Block nor an item.
func _skills(unit: BattleUnit) -> Array:
	return unit.action_abilities().filter(func(ability: BattleAbility) -> bool:
		return not ability.asset_tags.has(BASIC_TAG) and not ability.asset_tags.has(GUARD_TAG) \
			and not unit.item_abilities.has(ability.ability_tag))


func _items(unit: BattleUnit) -> Array:
	return unit.action_abilities().filter(func(ability: BattleAbility) -> bool:
		return unit.item_abilities.has(ability.ability_tag))


static func _first_with(unit: BattleUnit, tag: StringName) -> BattleAbility:
	for ability in unit.action_abilities():
		if ability.asset_tags.has(tag) and not unit.item_abilities.has(ability.ability_tag):
			return ability
	return null


static func _name(unit: BattleUnit) -> String:
	if unit == null or unit.definition == null:
		return "?"
	return unit.definition.display_name if unit.definition.display_name != "" else String(unit.definition.id)
