## Spec ff7-ui 2.12 (shared component): the description window at the top of every menu screen (and the battle hint's
## look). show_info({"name", "kind" (right of the name: a slot, a rarity, a usage tag), "text", "extra" (gold: "Equipped
## by: Cleric", "Held by: …"), "name_variation"}); missing parts are hidden.
extends PanelContainer


func show_info(info: Dictionary) -> void:
	%Name.text = str(info.get("name", ""))
	%Name.theme_type_variation = StringName(info.get("name_variation", &"Title"))
	%Kind.text = str(info.get("kind", ""))
	%Text.text = str(info.get("text", ""))
	%Text.visible = %Text.text != ""
	%Extra.text = str(info.get("extra", ""))
	%Extra.visible = %Extra.text != ""
