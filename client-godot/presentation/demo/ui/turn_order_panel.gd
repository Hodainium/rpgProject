## Spec ff7-ui 2.6 (HUD panel, UI.Slot.Hud.Right while UI.State.Run.Battle): the Honkai: Star Rail turn order. Queued
## ult presses first (gold), then the next `count` turns from TurnManager.preview (a pure look-ahead: the live order is
## never touched); the first is NOW, the others show their action value from now. Redrawn after every change.
extends UIBattlePanel

@export var count: int = 7
@export var now_text: String = "NOW"
@export var ult_text: String = "ULT"
## Portrait colours: party members by slot (1-4), then enemies.
@export var party_colors: Array[Color] = [Color("4a6fd8"), Color("d8c04a"), Color("8b5cd8"), Color("4ab878")]
@export var enemy_color: Color = Color("9b4b52")


func bind(context: UIContext) -> void:
	super(context)
	GameplayMessages.listen(GameplayMessageRouter.UI_ULT_PRESSED, func(_channel, _message): changed(),
		GameplayMessageRouter.Match.EXACT, null, self)


func on_recorder(new_recorder: ActionRecorder) -> void:
	new_recorder.action_requested.connect(func(_unit, _turn): changed())


func battle_changed() -> void:
	var cards: Array = []
	if recorder != null:
		for press in recorder.pending_ults():
			var caster := battle.unit_by_id(press["unit"])
			cards.append({"name": AbilityName.of_tag(caster, press["ability"]), "initial": _initial(caster),
				"color": _color(caster), "av": ult_text, "kind": "ult"})
	var first := true
	for entry in battle.turn_manager.preview(count):
		var unit: BattleUnit = entry["unit"]
		cards.append({"name": _name(unit), "initial": _initial(unit), "color": _color(unit),
			"av": now_text if first else str(int(entry["av"]) / 100), "kind": "now" if first else "next"})
		first = false
	%Cards.set_items(cards)


func _color(unit: BattleUnit) -> Color:
	if unit == null:
		return enemy_color
	if unit.is_party() and unit.slot >= 1 and unit.slot <= party_colors.size():
		return party_colors[unit.slot - 1]
	return enemy_color


static func _initial(unit: BattleUnit) -> String:
	var shown := _name(unit)
	return shown.substr(0, 1).to_upper() if shown != "" else "?"


static func _name(unit: BattleUnit) -> String:
	if unit == null or unit.definition == null:
		return "?"
	return unit.definition.display_name if unit.definition.display_name != "" else String(unit.definition.id)
