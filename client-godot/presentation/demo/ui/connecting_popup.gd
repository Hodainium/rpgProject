## Spec playtest-fixes B9: the connecting pop-up (UI.Slot.Overlay, always): a dimmed screen and a window with a spinning
## circle while the player waits on the server (a run starting or resuming, a floor seed at the stairs, a won run's
## verification, a rebuild after a conflict). Shows only after the wait has lasted `show_after_seconds`, so a quick
## answer never flashes it; blocks clicks while shown. Background uploads never show it. Hidden in local mode.
extends UIScreen

## Seconds a wait lasts before the pop-up shows.
@export var show_after_seconds: float = 0.3
## Spec card-ui 2.5: seconds an account action (buy, open, dust, craft) reconnects before the give-up button shows.
@export var give_up_after: float = 60.0
@export var give_up_text: String = "Stop waiting"

var _server: ServerLink
var _waited: float = -1.0  # seconds the current wait has lasted; -1 = no wait


func bind(context: UIContext) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	%Popup.hide()
	%GiveUp.text = give_up_text
	%GiveUp.pressed.connect(_give_up)
	if context.main == null:
		return
	context.main.server_changed.connect(_watch)
	_watch(context.main.server)


func _watch(link: ServerLink) -> void:
	if _server != null and is_instance_valid(_server) and _server.waiting_changed.is_connected(_on_waiting):
		_server.waiting_changed.disconnect(_on_waiting)
	_server = link
	if _server != null:
		_server.waiting_changed.connect(_on_waiting)
	_on_waiting(_server.waiting_text() if _server != null else "")


func _on_waiting(text: String) -> void:
	if text == "":
		_waited = -1.0
		%Popup.hide()
		%GiveUp.hide()
		return
	%Text.text = text
	if _waited < 0.0:
		_waited = 0.0
	if _waited >= show_after_seconds:
		%Popup.show()


func _process(delta: float) -> void:
	if %Popup.visible:
		var offer := _offers_give_up_now()
		if offer and not %GiveUp.visible:
			%GiveUp.show()
			%GiveUp.grab_focus()  # keyboard and gamepad players can leave too
		elif not offer and %GiveUp.visible:
			%GiveUp.hide()
	if _waited < 0.0 or %Popup.visible:
		return
	_waited += delta / maxf(Engine.time_scale, 0.0001)  # real time
	if _waited >= show_after_seconds:
		%Popup.show()


## Whether the pop-up shows now (tests).
func showing() -> bool:
	return %Popup.visible


## Whether the give-up button shows now (tests).
func offers_give_up() -> bool:
	return %Popup.visible and %GiveUp.visible


## Only for the account's own wait, once it has reconnected for `give_up_after` (another wait on top keeps its pop-up as is).
func _offers_give_up_now() -> bool:
	if _server == null or not is_instance_valid(_server):
		return false
	return _server.newest_wait_key() == CardAccount.WAIT_KEY and _server.account_reconnecting_seconds() >= give_up_after


func _give_up() -> void:
	if _server != null and is_instance_valid(_server):
		_server.card_account().give_up()
