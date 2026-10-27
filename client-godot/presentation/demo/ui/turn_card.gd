## Spec ff7-ui 2.6: one card of the turn order. Item keys: "name", "initial", "color" (the portrait), "av" (text:
## NOW, an action value, ULT), "kind" ("now", "next", "ult"): the card's look (TurnCardNow, TurnCard, TurnCardUlt).
extends PanelContainer

@export var now_portrait: float = 34.0
@export var portrait: float = 24.0


func set_item(item: Dictionary, _ctx: UIContext) -> void:
	var kind: String = item.get("kind", "next")
	theme_type_variation = {"now": &"TurnCardNow", "ult": &"TurnCardUlt"}.get(kind, &"TurnCard")
	var side := now_portrait if kind == "now" else portrait
	%Portrait.custom_minimum_size = Vector2(side, side)
	%Portrait.color = item.get("color", Color.GRAY)
	%Initial.text = str(item.get("initial", ""))
	%Name.text = str(item.get("name", ""))
	%Name.theme_type_variation = &"RowName" if kind == "now" else &""
	%Av.text = str(item.get("av", ""))
	%Av.theme_type_variation = &"Gold" if kind != "next" else &"Caption"
