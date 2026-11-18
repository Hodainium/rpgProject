## Spec playtest-fixes B9: the connecting pop-up (UI.Slot.Overlay, always): a dimmed screen and a window with a spinning
## circle while the player waits on the server (a run starting or resuming, a floor seed at the stairs, a won run's
## verification, a rebuild after a conflict). Shows only after the wait has lasted `show_after_seconds`, so a quick
## answer never flashes it; blocks clicks while shown. Background uploads never show it. Hidden in local mode.
## Card-ui playtest (user, 2026-11-18): under the window, "Go offline" while an account action reconnects or Go online signs in
## (GameMain.go_offline: local mode for this session, back to the main menu); and the account-session 1412 as a pop-up of its
## own, "Your account was opened somewhere else." with Use it here, wherever the player is (the message line stays for status).
extends UIScreen

## Seconds a wait lasts before the pop-up shows.
@export var show_after_seconds: float = 0.3
## Seconds an account action (buy, open, dust, craft) reconnects before Go offline shows (0: as soon as it reconnects).
@export var give_up_after: float = 0.0
@export var go_offline_text: String = "Go offline"
## Spec account-session 2.3: another login holds the account (1412).
@export var replaced_text: String = "Your account was opened somewhere else."
@export var use_here_text: String = "Use it here"
## Outside the main menu (a run keeps its link) the dialog's second button only closes it; account calls stay refused until
## Use it here.
@export var close_text: String = "Close"
## Use it here could not reach the server.
@export var take_failed_text: String = "Your account was opened somewhere else.\nCouldn't take it back: %s"

var _main: GameMain
var _server: ServerLink
var _waited: float = -1.0  # seconds the current wait has lasted; -1 = no wait
var _taking: bool = false


func bind(context: UIContext) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	%Popup.hide()
	%Replaced.hide()
	%GoOffline.text = go_offline_text
	%GoOffline.pressed.connect(_go_offline)
	%ReplacedOffline.text = go_offline_text
	%ReplacedOffline.pressed.connect(_replaced_second_button)
	%UseHere.text = use_here_text
	%UseHere.pressed.connect(_use_here)
	_main = context.main
	if context.main == null:
		return
	context.main.server_changed.connect(_watch)
	context.main.mode_changed.connect(func(_mode: String) -> void: _update_replaced_offline())
	_watch(context.main.server)


func _watch(link: ServerLink) -> void:
	if _server != null and is_instance_valid(_server):
		if _server.waiting_changed.is_connected(_on_waiting):
			_server.waiting_changed.disconnect(_on_waiting)
		if _server.session_changed.is_connected(_show_replaced):
			_server.session_changed.disconnect(_show_replaced)
	_server = link
	_taking = false  # review fix: a Use it here on the dropped link never comes back
	%UseHere.disabled = false
	if _server != null:
		_server.waiting_changed.connect(_on_waiting)
		_server.session_changed.connect(_show_replaced)
	_on_waiting(_server.waiting_text() if _server != null else "")
	_show_replaced()


func _on_waiting(text: String) -> void:
	if text == "":
		_waited = -1.0
		%Popup.hide()
		%GoOffline.hide()
		return
	%Text.text = text
	if _waited < 0.0:
		_waited = 0.0
	if _waited >= show_after_seconds:
		%Popup.show()
		get_viewport().gui_release_focus()  # Enter must not press a button under the pop-up (Go offline takes it when it shows)


func _process(delta: float) -> void:
	if %Popup.visible:
		var offer := _offers_go_offline_now()
		if offer and not %GoOffline.visible:
			%GoOffline.show()
			%GoOffline.grab_focus()  # keyboard and gamepad reach it (the theme's focus is a white outline, user 2026-11-18)
		elif not offer and %GoOffline.visible:
			%GoOffline.hide()
	if _waited < 0.0 or %Popup.visible:
		return
	_waited += delta / maxf(Engine.time_scale, 0.0001)  # real time
	if _waited >= show_after_seconds:
		%Popup.show()
		get_viewport().gui_release_focus()  # Enter must not press a button under the pop-up (Go offline takes it when it shows)


## Whether the pop-up shows now (tests).
func showing() -> bool:
	return %Popup.visible


## Whether Go offline shows under the pop-up now (tests).
func offers_go_offline() -> bool:
	return %Popup.visible and %GoOffline.visible


## Whether the "opened somewhere else" pop-up shows now (tests).
func shows_replaced() -> bool:
	return %Replaced.visible


## For the account's own wait once it reconnects (after `give_up_after`), and for Go online's sign-in; another wait on top
## (a run's) keeps its pop-up as is.
func _offers_go_offline_now() -> bool:
	if _server == null or not is_instance_valid(_server):
		return false
	if _main == null or _main.mode != "menu":
		return false  # review fix: Go offline works from the main menu only
	var key := _server.newest_wait_key()
	if key == GameMain.GO_ONLINE_WAIT:
		return true
	return key == CardAccount.WAIT_KEY and _server.account_reconnecting_seconds() >= give_up_after


func _go_offline() -> void:
	if _main != null:
		_main.go_offline()


func _show_replaced() -> void:
	var wanted := _server != null and is_instance_valid(_server) and _server.session_replaced
	if wanted and not %Replaced.visible:
		%ReplacedText.text = replaced_text
		_update_replaced_offline()
		%Replaced.show()
		%UseHere.grab_focus()  # the focus stays inside the dialog (white outline, user 2026-11-18)
	elif not wanted:
		%Replaced.hide()


## Go offline on the main menu; elsewhere (a run keeps its link) Close (review fix, follows the mode).
func _update_replaced_offline() -> void:
	%ReplacedOffline.text = go_offline_text if _main != null and _main.mode == "menu" else close_text


func _replaced_second_button() -> void:
	if _main != null and _main.mode == "menu":
		_go_offline()
	else:
		%Replaced.hide()


## Review fix: while a pop-up is up, Back does not reach the screens under it (the Shop would close behind it).
func _input(event: InputEvent) -> void:
	if (%Popup.visible or %Replaced.visible) and event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()


## Use it here: a new session (spec account-session 2.3); the screens redraw from session_changed.
func _use_here() -> void:
	if _taking or _server == null or not is_instance_valid(_server):
		return
	_taking = true
	%UseHere.disabled = true
	var link := _server
	var taken: Dictionary = await link.take_account()
	if not is_instance_valid(self):
		return
	_taking = false
	%UseHere.disabled = false
	if not taken["ok"] and link == _server:
		%ReplacedText.text = take_failed_text % ServerLink.describe(taken["error"])
