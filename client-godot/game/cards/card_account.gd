## Spec card-ui 2.5 (the client half of acceptance scenarios 1 and 2; Hearthstone's model: reconnect, never resume): the one
## account action of a player in flight (buy, open, dust, craft) over `ServerLink`. Its request key lives in memory until the
## server answers: a call with no answer, a 5xx or a 429 emits `reconnecting` (the connecting pop-up blocks the game) and is
## re-sent with the same key until an answer comes, so a double click or a lost answer charges once (the server answers a
## known key with the response it stored, `replayed`). `give_up()` stops waiting; nothing is stored, so after a crash, a quit
## or giving up the screens show the server's state. One action at a time is also the server's rule (the account lock).
## Presentation and client flow only: never in a run hash, snapshot or upload.
class_name CardAccount
extends RefCounted

## An action started or ended (the screens enable or disable their account buttons).
signal busy_changed
## The action got no answer and is being re-sent until the server answers (or the player gives up).
signal reconnecting
## The server answered after `reconnecting` (or the player gave up).
signal reconnected
signal _settled(answer: Dictionary)

const BUY: String = "buy"
const OPEN: String = "open"
const DUST: String = "dust"
const CRAFT: String = "craft"
const KINDS: Array[String] = [BUY, OPEN, DUST, CRAFT]
## The ServerLink wait a screen holds while its account action is on its way: the connecting pop-up offers its give-up
## button only while this wait is the one it shows.
const WAIT_KEY: StringName = &"cards.account"

const NOT_ENOUGH_CURRENCY: int = 1402
const CARD_LOCKED_BY_RUN: int = 1403
const KEY_REUSED: int = 1407
const RUN_VERIFYING: int = 1410

## The longest wait between two re-sends while reconnecting (ServerLink's backoff, capped here).
var reconnect_max_delay: float = 10.0

## Spec card-ui 5: console `cardui log on`: a line per account action sent and per answer (dev only, never in a hash).
static var log_actions: bool = false

## Spec account-session 2.3: the account version the screens show (from a collection read or the session's snapshot, or a
## decision's answer that is exactly the one sent + 1); -1 = not known, so ServerLink reads the collection before the next decision.
var account_version: int = -1

var link: ServerLink
var _running: bool = false
var _action: Dictionary = {}
var _reconnecting_since: int = -1  # Time.get_ticks_msec() of the first unanswered try; -1 = not reconnecting
var _generation: int = 0  # bumped by give_up(): the old retry loop ends silently
var _gave_up: bool = false  # given up, the last try still out
var _result: Dictionary = {}


func _init(server_link: ServerLink) -> void:
	link = server_link


## True while an action is on its way: the screens disable their account buttons.
func busy() -> bool:
	return _running


## The action on its way {kind, target, count, key, givenUp}, or {} (the console and the tests). `givenUp`: the player
## stopped waiting and the last try is still out.
func in_flight() -> Dictionary:
	if not _running or _action.is_empty():
		return {}
	var action := _action.duplicate()
	action["givenUp"] = _gave_up
	return action


## Seconds since the action first went unanswered, or -1 when it is not reconnecting (the pop-up's give-up button).
func reconnecting_seconds() -> float:
	return -1.0 if _reconnecting_since < 0 else (Time.get_ticks_msec() - _reconnecting_since) / 1000.0


## Runs one account action and returns ServerLink's answer {ok, data, error} plus `kind`, `target`, `count`, `key` and
## `given_up` (true when the player stopped waiting: the server may or may not have done it). It never returns before the
## server answers otherwise. Refused at once, with no call, while another action is busy (`error.busy`). `key` is for the
## 1403 path only (the same key after the cancel).
func run(kind: String, target: String, count: int = 1, key: String = "") -> Dictionary:
	if not KINDS.has(kind):
		push_error("CardAccount: unknown action '%s'" % kind)
		return _answer({"ok": false, "data": null, "error": _local("unknown action")}, kind, target, count, key, false)
	if busy():
		return _answer({"ok": false, "data": null, "error": _local("another account action is on its way", true)},
			kind, target, count, key, false)
	var action := {"kind": kind, "target": target, "count": count if kind == BUY else 1,
		"key": key if key != "" else ServerLink.new_request_key()}
	_running = true
	_action = action
	_result = {}
	busy_changed.emit()
	if log_actions:
		print("cardui: %s %s x%d [key %s]" % [kind, target, int(action["count"]), action["key"]])
	_send(action, _generation)  # in the background: give_up() settles the caller without waiting for it
	if not _result.is_empty():
		return _result
	var answer: Dictionary = await _settled
	return answer


## Spec card-ui 2.5: the player stops waiting for the server (the pop-up's button). The caller of run() gets `given_up`
## at once and the key is forgotten, so nothing is re-sent. The account stays busy until the try already out returns
## (it may still land on the server): then `busy_changed` fires and the screens refetch, so no second action overlaps it.
func give_up() -> void:
	if not _running or _action.is_empty() or _gave_up:
		return  # nothing on its way (or the 1403 path's abandon, which is not an account action)
	var action := _action
	_gave_up = true
	_generation += 1
	var answer := _answer({"ok": false, "data": null, "error": _local("stopped waiting for the server")}, str(action["kind"]),
		str(action["target"]), int(action.get("count", 1)), str(action["key"]), true)
	_result = answer
	_reconnecting_since = -1
	_settled.emit(answer)
	reconnected.emit()


## Spec card-ui 2.2: a dust refused with 1403 while the run is Active. Cancels that run on the server, releases it here and
## sends the same dust again with the same key (a refusal stored nothing under it). Returns the dust's answer, or the
## abandon's refusal (1410: the run turned Verifying meanwhile; the dust is not retried).
func cancel_run_and_retry(refused: Dictionary) -> Dictionary:
	var run_id := str(refused.get("error", {}).get("runId", ""))
	if run_id == "" or busy():
		return refused
	_running = true  # no other account action may start between the cancel and the retried dust
	busy_changed.emit()
	var abandoned: Dictionary = await link.abandon_run(run_id)
	_running = false  # no emit here: a listener must not start another action before the retried dust
	if not abandoned["ok"]:
		busy_changed.emit()
		abandoned["kind"] = "abandon"
		abandoned["runId"] = run_id
		return abandoned
	link.release_cancelled(run_id)
	return await run(str(refused["kind"]), str(refused["target"]), int(refused.get("count", 1)), str(refused["key"]))


## A refusal made here, before any call: no HTTP status (so never "no connection" and never retryable), `local` set.
static func _local(title: String, is_busy: bool = false) -> Dictionary:
	return {"status": -1, "local": true, "busy": is_busy, "title": title, "errorCode": null}


static func code_of(answer: Dictionary) -> int:
	var code: Variant = answer.get("error", {}).get("errorCode")
	return int(code) if code != null else 0


## Sends until the server answers (same key every time); ends silently when give_up() moved the generation on.
func _send(action: Dictionary, generation: int) -> void:
	var result: Dictionary = await _call(action)
	var delay := link.retry_base_seconds
	while generation == _generation and not result["ok"] and ServerLink.retryable(result["error"]):
		if _reconnecting_since < 0:
			_reconnecting_since = Time.get_ticks_msec()
			reconnecting.emit()
		await link.retry_wait(result["error"], delay, reconnect_max_delay)
		delay = minf(delay * 2.0, minf(link.retry_max_seconds, reconnect_max_delay))
		if generation != _generation:
			break
		result = await _call(action)
	if generation != _generation:
		# Given up: the last try is back, whatever it says. Spec account-session 2.3: a new session fences anything of the given-up
		# request still on its way (the session call waits for a commit in progress), so the screens' refetch after this is final.
		account_version = -1
		await link.renew_session()
		_free()
		return
	if code_of(result) == KEY_REUSED:
		push_error("CardAccount: the server says key %s was used for another request (%s %s)" % [action["key"], action["kind"], action["target"]])
	var answer := _answer(result, str(action["kind"]), str(action["target"]), int(action.get("count", 1)), str(action["key"]), false)
	if log_actions:
		print("cardui: %s %s answered %s%s" % [action["kind"], action["target"], "ok" if result["ok"] else "refused %d" % code_of(result),
			" (after reconnecting)" if _reconnecting_since >= 0 else ""])
	var was_reconnecting := _reconnecting_since >= 0
	_reconnecting_since = -1
	_result = answer
	_free(false)
	_settled.emit(answer)  # the caller resumes first, then the listeners hear the account is free
	if was_reconnecting:
		reconnected.emit()
	busy_changed.emit()


func _free(emit: bool = true) -> void:
	_running = false
	_gave_up = false
	_action = {}
	if emit:
		busy_changed.emit()


## One try. The first try's session and account version (`fence`) go with every retry (spec account-session 2.3).
func _call(action: Dictionary) -> Dictionary:
	var target := str(action["target"])
	var key := str(action["key"])
	var fence: Dictionary = action.get("fence", {})
	var result: Dictionary
	match str(action["kind"]):
		BUY:
			result = await link.buy_pack(target, int(action.get("count", 1)), key, fence)
		OPEN:
			result = await link.open_pack(target, key, fence)
		DUST:
			result = await link.dust_card(target, key, fence)
		_:
			result = await link.craft_card(target, key, fence)
	if fence.is_empty() and result.get("fence") is Dictionary:
		action["fence"] = result["fence"]
	return result


static func _answer(result: Dictionary, kind: String, target: String, count: int, key: String, given_up: bool) -> Dictionary:
	var answer := result.duplicate()
	answer["kind"] = kind
	answer["target"] = target
	answer["count"] = count
	answer["key"] = key
	answer["given_up"] = given_up
	return answer
