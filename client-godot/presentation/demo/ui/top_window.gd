## Spec ff7-ui 2.3 / 2.6 (HUD panel, UI.Slot.Hud.Top while UI.State.Run.Battle): the battle's hint window at the top.
## It shows what Message.Ui.Hint carries: an ability's name, cost, description, target and where it can be used (the
## command window sends it on hover when HINT is on), or a prompt ("Ice Blast · choose a target"). Empty: hidden.
extends UIScreen

@export var target_format: String = "TARGET: %s"


func bind(_context: UIContext) -> void:
	GameplayMessages.listen(GameplayMessageRouter.UI_HINT, _on_hint, GameplayMessageRouter.Match.EXACT, VerbMessage, self)
	%Window.visible = false


func on_deactivated() -> void:
	%Window.visible = false


func _on_hint(_channel: StringName, message: VerbMessage) -> void:
	var data := message.data
	if data.has("prompt"):
		%Name.text = str(data["prompt"])
		%Cost.text = ""
		%Description.visible = false
		%Target.visible = false
		%Window.visible = true
		return
	if not data.has("name"):
		%Window.visible = false
		return
	%Name.text = str(data["name"])
	%Cost.text = str(data.get("cost", ""))
	%Description.text = str(data.get("description", ""))
	%Description.visible = %Description.text != ""
	var target := str(data.get("target", ""))
	var usage := str(data.get("usage", ""))
	%Target.text = _join(target, usage)
	%Target.visible = %Target.text != ""
	%Window.visible = true


func _join(target: String, usage: String) -> String:
	var parts := PackedStringArray()
	if target != "":
		parts.append(target_format % target)
	if usage != "":
		parts.append(usage)
	return "  ·  ".join(parts)
