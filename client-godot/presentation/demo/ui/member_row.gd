## Spec ff7-ui 2.12 (shared component): one party member's row, used by the battle party window and the exploration
## party strip. Item keys: "name", "level" (0 hides it), "chips" (status texts), "hp", "hp_max", "mp", "mp_max"
## (mp_max 0 hides SP), "mp_preview" (SP a hovered ability would spend: the bar shows what's left and highlights the
## spent part; 0 = none), "ult" (0-100), "active" (the pointer; the gold name), "show_ult", "ult_state" ("off",
## "ready", "queued"), "on_ult", "pickable", "on_pick", "on_hover", "on_unhover" (Callables), "selected" (a gold
## frame: the Status screen's chosen member).
extends Button

@export var ult_text: String = "ULT"
@export var queued_text: String = "QUEUED"
@export var level_format: String = "LV %d"
@export var number_format: String = "%d / %d"
## Spec skill-points: the SP numbers while an ability's cost is previewed (current, max, cost).
@export var preview_format: String = "%d / %d  −%d"
## The highlighted part of the SP bar a previewed ability would spend.
@export var preview_color: Color = Color(1.0, 0.85, 0.3, 0.85)

var _on_ult: Callable
var _spend: ColorRect
var _on_pick: Callable
var _on_hover: Callable
var _on_unhover: Callable
var _pulse: Tween


func _ready() -> void:
	%Ult.pressed.connect(func():
		if _on_ult.is_valid():
			_on_ult.call())
	pressed.connect(func():
		if _on_pick.is_valid():
			_on_pick.call())
	mouse_entered.connect(func():
		if _on_hover.is_valid():
			_on_hover.call())
	mouse_exited.connect(func():
		if _on_unhover.is_valid():
			_on_unhover.call())


func set_item(item: Dictionary, _ctx: UIContext) -> void:
	var active: bool = item.get("active", false)
	var pickable: bool = item.get("pickable", false)
	%Pointer.self_modulate.a = 1.0 if active else 0.0
	%Name.text = str(item.get("name", ""))
	%Name.theme_type_variation = &"RowNameActive" if active else &"RowName"
	var level := int(item.get("level", 0))
	%Level.text = level_format % level if level > 0 else ""
	_set_chips(item.get("chips", []))
	%HpText.text = number_format % [int(item.get("hp", 0)), int(item.get("hp_max", 0))]
	%HpBar.max_value = maxi(int(item.get("hp_max", 1)), 1)
	%HpBar.value = int(item.get("hp", 0))
	var mp_max := int(item.get("mp_max", 0))
	var mp := int(item.get("mp", 0))
	var spend := mini(int(item.get("mp_preview", 0)), mp)
	%Mp.self_modulate.a = 1.0 if mp_max > 0 else 0.0
	%MpText.text = preview_format % [mp, mp_max, spend] if spend > 0 else number_format % [mp, mp_max]
	%MpBar.max_value = maxi(mp_max, 1)
	%MpBar.value = mp - spend
	_set_spend(mp - spend, spend, maxi(mp_max, 1))
	var ult := int(item.get("ult", 0))
	%UltBar.value = ult
	%UltText.text = "%d%%" % ult
	_set_pulse(ult >= 100)
	var state: String = item.get("ult_state", "off")
	%Ult.visible = item.get("show_ult", false)
	%Ult.text = queued_text if state == "queued" else ult_text
	%Ult.theme_type_variation = &"UltButtonQueued" if state == "queued" else &"UltButton"
	%Ult.disabled = state != "ready"
	_on_ult = item.get("on_ult", Callable())
	_on_pick = item.get("on_pick", Callable())
	_on_hover = item.get("on_hover", Callable())
	_on_unhover = item.get("on_unhover", Callable())
	disabled = not pickable
	mouse_filter = Control.MOUSE_FILTER_STOP if pickable else Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_ALL if pickable else Control.FOCUS_NONE
	if item.get("selected", false):
		theme_type_variation = &"MemberRowSelected"
	else:
		theme_type_variation = &"MemberRowPick" if pickable else (&"MemberRowActive" if active else &"MemberRow")
	set_meta("ui_text", %Name.text)


func _set_chips(texts: Array) -> void:
	var chips := %Chips.get_children()
	for index in maxi(texts.size(), chips.size()):
		if index >= texts.size():
			chips[index].queue_free()
			continue
		var chip: Label = chips[index] if index < chips.size() else null
		if chip == null:
			chip = Label.new()
			chip.theme_type_variation = &"StatusChip"
			%Chips.add_child(chip)
		chip.text = str(texts[index])


## The highlighted segment over the SP bar from `left` to `left + spend` (of `most`); hidden when nothing is spent.
func _set_spend(left: int, spend: int, most: int) -> void:
	if _spend == null:
		_spend = ColorRect.new()
		_spend.mouse_filter = Control.MOUSE_FILTER_IGNORE
		%MpBar.add_child(_spend)
	_spend.visible = spend > 0
	if spend <= 0:
		return
	_spend.color = preview_color
	_spend.anchor_top = 0.0
	_spend.anchor_bottom = 1.0
	_spend.anchor_left = float(left) / most
	_spend.anchor_right = float(left + spend) / most
	_spend.offset_left = 0
	_spend.offset_right = 0
	_spend.offset_top = 0
	_spend.offset_bottom = 0


func _set_pulse(full: bool) -> void:
	if full and _pulse == null:
		_pulse = create_tween().set_loops().set_ignore_time_scale(true)
		_pulse.tween_property(%UltBar, "modulate", Color(1.5, 1.5, 1.5), 0.6)
		_pulse.tween_property(%UltBar, "modulate", Color.WHITE, 0.6)
	elif not full and _pulse != null:
		_pulse.kill()
		_pulse = null
		%UltBar.modulate = Color.WHITE
