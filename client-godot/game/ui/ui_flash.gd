## Spec ui-feedback 2.3: a refusal's feedback on a Control: a red pulse (and a small shake), then back to exactly how it
## was. Presentation only: nothing in a run, a battle, a hash or a replay reads it. Values from the theme type `UIFlash`
## (constants `flash_ms`, `shake_px`, colour `refuse`), with the defaults below when the control's theme has none.
class_name UIFlash
extends RefCounted

const THEME_TYPE: StringName = &"UIFlash"
const DEFAULT_MS: int = 350
const DEFAULT_SHAKE_PX: int = 6
const DEFAULT_COLOR: Color = Color(1, 0.6039, 0.5412, 1)
## Metadata on a flashing control: its running tween and how it looked before the flash.
const META_TWEEN: StringName = &"ui_flash_tween"
const META_FROM: StringName = &"ui_flash_from"


## The standard refusal: two red pulses and, with `shake`, a few pixels left and right, over `flash_ms`; the control ends
## at its start colour and position. A flash on a control already flashing restarts it from its resting look. Returns
## the tween (tests step it with `custom_step`), or null for a control outside the tree.
static func refuse(control: Control, shake: bool = true) -> Tween:
	if control == null or not is_instance_valid(control) or not control.is_inside_tree():
		return null
	var from := _rest(control)
	var seconds := float(_constant(control, &"flash_ms", DEFAULT_MS)) / 1000.0
	var refused := _color(control)
	var px := float(_constant(control, &"shake_px", DEFAULT_SHAKE_PX)) if shake else 0.0
	var tween := control.create_tween().set_ignore_time_scale(true)
	tween.tween_method(func(t: float): _step(control, from, t, refused, px), 0.0, 1.0, seconds)
	tween.finished.connect(func(): _end(control))
	control.set_meta(META_TWEEN, tween)
	return tween


## One step of the flash at `t` (0..1): two pulses toward `refused` and a shake that dies out. The start position is
## read on the first step, after a container placed the control (a list rebuilt just before the flash).
static func _step(control: Control, from: Dictionary, t: float, refused: Color, px: float) -> void:
	if not is_instance_valid(control):
		return
	var rest_color: Color = from["modulate"]
	var pulse_at := 1.0 - absf(2.0 * fmod(t * 2.0, 1.0) - 1.0)  # 0 → 1 → 0, twice
	control.modulate = rest_color.lerp(Color(refused.r, refused.g, refused.b, rest_color.a), pulse_at)
	if px > 0.0:
		if from["position"] == null:
			from["position"] = control.position
		control.position = from["position"] + Vector2(px * sin(t * TAU * 2.0) * (1.0 - t), 0.0)


## The red pulse only (counters, bars).
static func pulse(control: Control) -> Tween:
	return refuse(control, false)


## Whether `control` is flashing now.
static func flashing(control: Control) -> bool:
	if control == null or not is_instance_valid(control) or not control.has_meta(META_TWEEN):
		return false
	var tween: Tween = control.get_meta(META_TWEEN)
	return tween != null and tween.is_valid() and tween.is_running()


## Spec ui-feedback 2.3: `owner` flashes the targets it owns. For each Message.Ui.Refused while `owner` is visible,
## `resolve(data) -> Array` names the controls: a Control (a pulse and a shake) or {"control", "shake"}. The listener
## leaves with `owner`; an owner the UI hides flashes nothing.
static func listen(owner: Control, resolve: Callable) -> void:
	GameplayMessages.listen(GameplayMessageRouter.UI_REFUSED, func(_channel: StringName, message: VerbMessage) -> void:
		if not is_instance_valid(owner) or not owner.is_visible_in_tree():
			return
		for hit in resolve.call(message.data):
			if hit is Control:
				refuse(hit)
			elif hit is Dictionary and hit.get("control") is Control:
				refuse(hit["control"], hit.get("shake", true)),
		GameplayMessageRouter.Match.EXACT, VerbMessage, owner)


## The live entries of a UIList (or any container), in order.
static func entries(list: Node) -> Array:
	if list == null:
		return []
	return list.get_children().filter(func(child) -> bool: return not child.is_queued_for_deletion())


## The entry at `index` of a list, or null.
static func entry(list: Node, index: int) -> Control:
	var all := entries(list)
	return all[index] as Control if index >= 0 and index < all.size() else null


## The control's resting look: what it looked like before the flash that is running, which ends here at once.
static func _rest(control: Control) -> Dictionary:
	if control.has_meta(META_FROM):
		var from: Dictionary = control.get_meta(META_FROM)
		_kill(control)
		control.modulate = from["modulate"]
		if from["position"] != null:
			control.position = from["position"]
			from["position"] = null  # read again on the next step: a container may have moved it meanwhile
			if control.get_parent() is Container:
				control.get_parent().queue_sort()
		return from
	var rest := {"modulate": control.modulate, "position": null}
	control.set_meta(META_FROM, rest)
	return rest


static func _end(control: Control) -> void:
	if not is_instance_valid(control) or not control.has_meta(META_FROM):
		return
	var from: Dictionary = control.get_meta(META_FROM)
	control.modulate = from["modulate"]
	if from["position"] != null:
		control.position = from["position"]
	control.remove_meta(META_FROM)
	control.remove_meta(META_TWEEN)
	if control.get_parent() is Container:
		control.get_parent().queue_sort()  # a layout that moved meanwhile wins over the start position


static func _kill(control: Control) -> void:
	var tween: Variant = control.get_meta(META_TWEEN, null)
	if tween is Tween and tween.is_valid():
		tween.kill()
	if control.has_meta(META_TWEEN):
		control.remove_meta(META_TWEEN)


static func _constant(control: Control, name: StringName, fallback: int) -> int:
	return control.get_theme_constant(name, THEME_TYPE) if control.has_theme_constant(name, THEME_TYPE) else fallback


static func _color(control: Control) -> Color:
	return control.get_theme_color(&"refuse", THEME_TYPE) if control.has_theme_color(&"refuse", THEME_TYPE) \
		else DEFAULT_COLOR
