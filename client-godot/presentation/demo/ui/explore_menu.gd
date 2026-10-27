## Spec ff7-ui 2.7 (HUD panel, UI.Slot.Hud.Bottom.Right on the map): the exploration menu. Equipment, Armor, Use Item,
## Use Ability and Status open their menu screens on the GameMenu layer; Gold (and Keys, keys-and-gear) are greyed
## lines under them.
extends UIScreen

@export var gear_screen: PackedScene = preload("res://presentation/demo/ui/gear_screen.tscn")
@export var use_screen: PackedScene = preload("res://presentation/demo/ui/use_screen.tscn")
@export var status_screen: PackedScene = preload("res://presentation/demo/ui/status_screen.tscn")
@export var equipment: GearSet = preload("res://presentation/demo/ui/equipment.tres")
@export var armor: GearSet = preload("res://presentation/demo/ui/armor.tres")
@export var gold_format: String = "Gold: %d"


func bind(context: UIContext) -> void:
	for signal_name in [&"party_changed", &"floor_entered", &"room_entered"]:
		context.on_run(self, signal_name, func(_a = null): refresh.call_deferred())


func refresh() -> void:
	if ctx == null or ctx.run == null or ctx.run.state == null:
		return
	%Entries.set_items([
		_entry("Equipment", gear_screen, {"set": equipment}),
		_entry("Armor", gear_screen, {"set": armor}),
		_entry("Use Item", use_screen, {"mode": "item"}),
		_entry("Use Ability", use_screen, {"mode": "ability"}),
		_entry("Status", status_screen, {}),
	])
	%Gold.text = gold_format % ctx.run.state.coins


func _entry(text: String, scene: PackedScene, payload: Dictionary) -> Dictionary:
	return {"text": text, "variation": &"CommandButton",
		"action": func(): ctx.ui.push(&"UI.Layer.GameMenu", scene, payload)}
