## Spec ff7-ui 2.2 / 2.11 (HUD panel, UI.Slot.Hud.Toast while UI.State.Run): the run's toasts (pickups, floors, level
## ups) from run_toasts.tres, replacing the old floor card. The first floor's message is sent before the HUD exists,
## so it is handed over on activation. While Tab holds the floor toast, the toasts centre in the free space left of
## the map panel (UI.Slot.Hud.Right) so the grown map and the banner never overlap.
extends UIToastHost

@export var map_slot: StringName = &"UI.Slot.Hud.Right"
## Spec ui-fixes B4: the toasts stack oldest on top. When one leaves, the ones below glide up into its place (px a
## second) instead of snapping; a new toast starts at its place.
@export var separation: float = 6.0
@export var glide_speed: float = 600.0

## [run, floor index] the floor toast was last shown for.
var _floor_shown: Array = []


func bind(context: UIContext) -> void:
	super(context)
	GameplayMessages.listen(GameplayMessageRouter.RUN_FLOOR_ENTERED, func(_channel, _message): _note_floor(), \
		GameplayMessageRouter.Match.EXACT, null, self)
	hold_changed.connect(_on_hold_changed)


func on_activated() -> void:
	var run := ctx.run
	if run == null or run.state == null or [run, run.state.floor_index] == _floor_shown:
		return
	var chapter := run.chapter()
	receive(GameplayMessageRouter.RUN_FLOOR_ENTERED, VerbMessage.make(&"Verb.Enter", &"", run.state.chapter_id,
		run.state.floor_index + 1, [], {"chapterName": chapter.display_name if chapter != null else ""}))
	_note_floor()


func _process(delta: float) -> void:
	super(delta)
	_lay_out(delta)


## Spec ui-fixes B4: stacks the toasts top-down, centred; each moves toward its place at glide_speed (a new one starts
## at its place), plus its own slide-in offset (B6).
func _lay_out(delta: float) -> void:
	var y := 0.0
	for toast: Control in %Toasts.get_children():
		if toast.is_queued_for_deletion():
			continue
		toast.size = toast.get_combined_minimum_size()
		toast.position.x = (%Toasts.size.x - toast.size.x) / 2.0
		var place: float = toast.get_meta("place", y)
		place = move_toward(place, y, glide_speed * delta)
		toast.set_meta("place", place)
		var drop = toast.get("drop")  # spec ui-fixes B6: the banner's own slide-in
		toast.position.y = place + (float(drop) if drop != null else 0.0)
		y += toast.size.y + separation


func _note_floor() -> void:
	if ctx != null and ctx.run != null and ctx.run.state != null:
		_floor_shown = [ctx.run, ctx.run.state.floor_index]


func _on_hold_changed(held: bool) -> void:
	%Toasts.position.x = 0.0
	if not held or ctx == null or ctx.ui == null:
		return
	var map := ctx.ui.point(map_slot)
	if map == null:
		return
	await get_tree().process_frame  # the map grows on the same press; read its edge once it has
	var left_edge := map.get_global_rect().position.x
	var centre := global_position.x + size.x / 2.0
	%Toasts.position.x = left_edge / 2.0 - centre
