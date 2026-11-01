## The client's link to Rpg.GameServerApi (spec server-authority 3.7): await-able wrappers over the C# ServerBridge
## (the one adapter; whole Rpg.Contracts records as JSON) and everything a linked run needs from the server. Holds no
## game rules: the run plays every floor offline from its issued seed.
## Part A: floor seeds fetched with backoff while offline, server errors that stop a run.
## Part B: a dev token for the player name (sent as the bearer token; fetched again once on a 401); the action queue
## (every logged action, uploaded in order in batches of up to 50, one request at a time, backoff with jitter on no
## answer, 5xx and 429); the local save (user://saves/<player>/run.json, rewritten after every action and ack); the
## stairs gate (the floor's log uploaded first, AfterSeq), a won run's end (the queue drained, then POST /end and a
## poll until Won); resume with or without the save; a 409 1103 discards the save and resumes from the server's log;
## the presence heartbeat.
##
## Server mode is on when the Settings (user://game_main.cfg, section "server") name a url; the console's `server`
## sets it. Tests give it a fake bridge with the same methods and the Completed signal. Every call resolves to
## {"ok": bool, "data": the response record parsed (null for a 204), "error": {"status" (0 = no response),
## "errorCode", "title", "detail", "retryAfterSeconds", "expectedSeq", "lastSeq"}}.
class_name ServerLink
extends Node

signal _completed
signal _signed_in
## The queue or its acknowledgement changed (an upload finished, a batch was acknowledged, the queue was dropped).
signal queue_changed
## Spec 2.4: the linked run was rebuilt (a resume, or a 1103 conflict); `source` is "save" or "server".
signal resumed(source: String)
## Spec playtest-fixes B9: the player now waits on the server (`text` says for what) or no longer does ("").
signal waiting_changed(text: String)
## Spec playtest-fixes B10: the server answered or stopped answering, or the player signed in (connected(), player_id).
signal connection_changed

const SETTINGS_SECTION: String = "server"
const BRIDGE_SCRIPT: String = "res://net/ServerBridge.cs"
const TIMEOUT_SECONDS: float = 10.0
const BATCH_SIZE: int = 50
const SEQUENCE_GAP: int = 1102
const SEQUENCE_CONFLICT: int = 1103
const UPLOAD_INCOMPLETE: int = 1106
const RUN_NOT_ACTIVE: int = 1101
## Shown when the server has already ended the run this client is playing (it died, was won or abandoned elsewhere).
const ENDED_ELSEWHERE: String = "This run has already ended on the server (another game window or device played on)"

## Backoff for a floor seed while offline: doubles from base up to max, ±25% jitter; a Retry-After wins.
var retry_base_seconds: float = 1.0
var retry_max_seconds: float = 30.0

var bridge: Object
## The dev player name the token is asked for (spec 3.2), and where its local save lives.
var player: String = "dev"
## The server url this link was made for (the main menu and Settings show it).
var url: String = ""
var saves_dir: String = "user://saves"
var heartbeat_seconds: float = 30.0
## Spec playtest-fixes B12: the heartbeat's period while the server isn't answering, so its return is seen soon.
var offline_heartbeat_seconds: float = 5.0
## Spec playtest-fixes B9: what the connecting pop-up says while the player waits.
var wait_floor_text: String = "Connecting to the server…"
var wait_end_text: String = "Verifying the run…"
var wait_rebuild_text: String = "Restoring the run from the server…"
var poll_seconds: float = 2.0
## Rebuilds and conflicts so far (the dev report's server block).
var resumes: int = 0
## The player id the server gave the dev token (spec 3.2), "" before signing in.
var player_id: String = ""
var _results: Dictionary = {}
var _token: String = ""
## Spec playtest-fixes B9: what the player waits on, by key, in the order the waits began (the newest one shows).
var _waits: Dictionary = {}
## Whether the last request got an answer (any HTTP status); null before the first one.
var _answered: Variant = null
var _signing_in: bool = false
var _sign_in_error: Dictionary = {}

# The linked run (Part B).
var _run: RunController
var _run_id: String = ""
## RunActionRequests not acknowledged yet, in seq order; the last acknowledged seq; the last acknowledged request.
var _queue: Array = []
var _last_acked: int = 0
var _last_sent: Dictionary = {}
var _uploading: bool = false
## A won run's RunEndRequest while it waits for the server (2.3).
var _end_request: Dictionary = {}
## The RunSnapshot after the latest action, for the local save.
var _snapshot: Dictionary = {}
var _heartbeat: Timer


func _init(bridge_object: Object) -> void:
	name = "ServerLink"
	bridge = bridge_object
	bridge.Completed.connect(_on_completed)
	if bridge is Node:
		add_child(bridge)


## A link to the server the Settings name, or null (local mode: no url set).
static func from_settings() -> ServerLink:
	var url := str(GameMain.load_setting(SETTINGS_SECTION, "url", ""))
	if url == "":
		return null
	return create(url, str(GameMain.load_setting(SETTINGS_SECTION, "player", "")))


## A link to `url` as the dev player `player` through the C# bridge, or null when the bridge isn't built. Writes no
## Settings (spec dev-tools E3: the e2e harness links this way).
static func create(url: String, player_name: String) -> ServerLink:
	if not bridge_available():
		push_error("ServerLink: this build has no C# assemblies (data_* folder); playing in local mode")
		return null
	var script: Script = load(BRIDGE_SCRIPT)
	if script == null or not script.can_instantiate():
		push_error("ServerLink: %s is not built (dotnet build); playing in local mode" % BRIDGE_SCRIPT)
		return null
	var bridge_node: Object = script.new()
	bridge_node.Configure(url, TIMEOUT_SECONDS)
	var link := ServerLink.new(bridge_node)
	link.player = player_name if player_name != "" else "dev"
	link.url = url
	return link


func _ready() -> void:
	_heartbeat = Timer.new()
	_heartbeat.name = "Heartbeat"
	_heartbeat.wait_time = heartbeat_seconds
	_heartbeat.timeout.connect(heartbeat)
	add_child(_heartbeat)
	_heartbeat.start()


## Whether the C# bridge can be loaded. An exported pack carries its assemblies in a data_* folder next to the
## executable; without it, loading a C# script crashes the engine (signal 11) instead of failing, so check first.
## The editor and headless runs from the project build the assembly themselves.
static func bridge_available() -> bool:
	if not ClassDB.class_exists("CSharpScript"):
		return false
	if not OS.has_feature("template"):
		return true
	var folder := OS.get_executable_path().get_base_dir()
	return Array(DirAccess.get_directories_at(folder)).any(func(name: String) -> bool: return name.begins_with("data_"))


## POST /api/v1/runs: data = RunStartResponse {runId, floor, floorSeed, startedAt}.
func start_run(ruleset_version: String, run_structure_id: String, character_ids: Array) -> Dictionary:
	var request := {"rulesetVersion": ruleset_version, "runStructureId": run_structure_id,
		"characterIds": character_ids.map(func(id) -> String: return str(id))}
	return await _request("StartRun", [WireJson.stringify(request)])


## POST /api/v1/runs/{runId}/floors/{floor}, once: data = FloorSeedResponse {runId, floor, floorSeed}. `after_seq`:
## the last seq of the floor being left (Part B's gate; null asks for the current floor again).
func floor_seed(run_id: String, floor_index: int, after_seq: Variant = null) -> Dictionary:
	return await _request("GetFloorSeed", [run_id, floor_index, WireJson.stringify({"afterSeq": after_seq})])


## The floor seed, retried with backoff while there is no answer, a 5xx or a 429; any other error returns at once.
## For the linked run, the queue is uploaded first and AfterSeq is its last seq (a 1106 drains it and asks again).
func floor_seed_until_issued(run_id: String, floor_index: int) -> Dictionary:
	var delay := retry_base_seconds
	while true:
		var after_seq: Variant = null
		if _linked() and run_id == _run_id:
			await drained()
			after_seq = _last_acked
		var result := await floor_seed(run_id, floor_index, after_seq)
		if result["ok"]:
			return result
		if after_seq != null and int(_code(result["error"])) == UPLOAD_INCOMPLETE:
			await get_tree().create_timer(retry_base_seconds).timeout
			continue  # the log isn't all in yet: drain and ask again
		if not retryable(result["error"]):
			return result
		await _backoff(result["error"], delay)
		delay = minf(delay * 2.0, retry_max_seconds)
	return {}


## GET /api/v1/runs/{runId}: data = RunSummaryResponse.
func get_run(run_id: String) -> Dictionary:
	return await _request("GetRun", [run_id])


## GET /api/v1/runs/current: data = RunSummaryResponse, or null when the player has no active run.
func get_current_run() -> Dictionary:
	return await _request("GetCurrentRun", [])


## GET /api/v1/runs/{runId}/battles/{seq}: data = BattleSessionResponse.
func get_battle(run_id: String, seq: int) -> Dictionary:
	return await _request("GetBattle", [run_id, seq])


## Links `run` (the server's run `run_id`) to the server: floor seeds at the stairs, every logged action queued and
## uploaded, a won run held until the server says Won, the local save, the heartbeat.
func link(run: RunController, run_id: String) -> void:
	_run = run
	_run_id = run_id
	_queue.clear()
	_last_acked = 0
	_last_sent = {}
	_end_request = {}
	_snapshot = {}
	_end_run_waits()
	run.journal = true
	run.verify_wins = true
	run.floor_seed_needed.connect(func(floor_index: int) -> void: _fetch_floor(run, run_id, floor_index))
	run.actions_committed.connect(func(requests: Array) -> void: _on_committed(run, requests))
	run.run_verifying.connect(func(end_request: Dictionary) -> void: _on_verifying(run, end_request))
	run.battle_started.connect(func(_battle) -> void: heartbeat())
	run.battle_finished.connect(func(_outcome) -> void: heartbeat())
	run.run_ended.connect(func(_status) -> void: heartbeat())
	heartbeat()


## Requests not acknowledged yet (copies), the last acknowledged seq, and whether an upload is in flight.
func queued() -> Array:
	return _queue.duplicate(true)


func last_acked_seq() -> int:
	return _last_acked


func uploading() -> bool:
	return _uploading


## Waits until every queued action is acknowledged (the queue drains while online; offline this waits).
func drained() -> void:
	while _linked() and (not _queue.is_empty() or _uploading):
		await queue_changed


# --- The action queue (spec 2.2) ----------------------------------------------------------------------------------

func _on_committed(run: RunController, requests: Array) -> void:
	if run != _run:
		return
	_queue.append_array(requests)
	_snapshot = run.snapshot()
	save()
	_pump()


## Uploads the queue in order, one request at a time; retried with backoff on no answer, 5xx and 429. A 1103 means the
## server accepted other actions (another device, an old save): the save is discarded and the run rebuilt from the
## server's log. Any other refusal stops the run (not a loss).
func _pump() -> void:
	if _uploading or not _linked():
		return
	_uploading = true
	var run := _run
	var delay := retry_base_seconds
	while not _queue.is_empty() and _linked() and _run == run:
		var batch: Array = _queue.slice(0, BATCH_SIZE)
		var result := await _request("SendActions", [_run_id, WireJson.stringify({"actions": batch})])
		if _run != run or not _linked():
			break
		if result["ok"]:
			_acknowledge(int(result["data"]["lastSeq"]))
			delay = retry_base_seconds
			continue
		var error: Dictionary = result["error"]
		if retryable(error):
			await _backoff(error, delay)
			delay = minf(delay * 2.0, retry_max_seconds)
			continue
		_uploading = false
		if int(_code(error)) == SEQUENCE_CONFLICT:
			await _rebuild_after_conflict(run)
		else:
			_refused(run, error)
		queue_changed.emit()
		return
	_uploading = false
	queue_changed.emit()


func _acknowledge(last_seq: int) -> void:
	while not _queue.is_empty() and int(_queue[0]["seq"]) <= last_seq:
		_last_sent = _queue.pop_front()
	_last_acked = maxi(_last_acked, last_seq)
	if _run.state.status == RunState.LOST and _queue.is_empty():
		forget_save()  # the death is on the server: nothing left to keep
	else:
		save()
	queue_changed.emit()


# --- A won run (spec 2.3) -----------------------------------------------------------------------------------------

func _on_verifying(run: RunController, end_request: Dictionary) -> void:
	if run != _run:
		return
	_end_request = end_request
	_snapshot = end_request["snapshot"]
	save()
	await _finish_win(run)


## Drains the queue, sends the end, then polls GET /runs/{id} every poll_seconds until Won (Rejected stops the run).
func _finish_win(run: RunController) -> void:
	var wait := StringName("end/" + _run_id)
	begin_wait(wait, wait_end_text)
	await _finish_win_waiting(run)
	end_wait(wait)


func _finish_win_waiting(run: RunController) -> void:
	var delay := retry_base_seconds
	var status := ""
	while _run == run and _linked():
		await drained()
		var result := await _request("EndRun", [_run_id, WireJson.stringify(_end_request)])
		if result["ok"]:
			status = str(result["data"]["status"])
			break
		if int(_code(result["error"])) == UPLOAD_INCOMPLETE:
			await get_tree().create_timer(retry_base_seconds).timeout
			continue
		if not retryable(result["error"]):
			_refused(run, result["error"])
			return
		await _backoff(result["error"], delay)
		delay = minf(delay * 2.0, retry_max_seconds)
	while _run == run and status == "Verifying":
		await get_tree().create_timer(poll_seconds).timeout
		var summary := await get_run(_run_id)
		if summary["ok"]:
			status = str(summary["data"]["status"])
	if _run != run:
		return
	if status == "Won":
		forget_save()
		run.confirm_end(RunState.WON)
	elif status != "":
		run.stop_on_server_error("the server says the run is %s" % status)


# --- The local save and resume (spec 2.4) -------------------------------------------------------------------------

func save_path() -> String:
	return saves_dir.path_join(player).path_join("run.json")


## Rewrites the local save: {schemaVersion, runId, player, floorSeeds (every seed issued so far), snapshot (after the
## latest action), queue, lastAckedSeq, end}. A convenience copy; the server's accepted log always wins.
func save() -> void:
	if not _linked() or _snapshot.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(save_path().get_base_dir())
	var file := FileAccess.open(save_path(), FileAccess.WRITE)
	if file == null:
		push_error("ServerLink: can't write %s" % save_path())
		return
	var floor_seeds := {}
	for floor_index in _run.state.floor_seeds:
		floor_seeds[str(floor_index)] = str(_run.state.floor_seeds[floor_index])
	file.store_string(WireJson.stringify({"schemaVersion": 1, "runId": _run_id, "player": player,
		"floorSeeds": floor_seeds, "snapshot": _snapshot, "queue": _queue, "lastAckedSeq": _last_acked,
		"end": _end_request}))
	file.close()


## The local save, or {} when there is none (or it can't be read).
func load_save() -> Dictionary:
	if not FileAccess.file_exists(save_path()):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(save_path()))
	return parsed if parsed is Dictionary and int(parsed.get("schemaVersion", 0)) == 1 else {}


func forget_save() -> void:
	if FileAccess.file_exists(save_path()):
		DirAccess.remove_absolute(save_path())


## The last seq a save holds (its snapshot is after it).
static func save_seq(saved: Dictionary) -> int:
	var seq := int(saved.get("lastAckedSeq", 0))
	for request in saved.get("queue", []):
		seq = maxi(seq, int(request["seq"]))
	if not saved.get("end", {}).is_empty():
		seq = maxi(seq, int(saved["end"]["seq"]))
	return seq


## Continues the player's current run `summary` (a RunSummaryResponse) in `run`, a fresh RunController: from the local
## save when it is this run's and at least as far as the server, else rebuilt from the server's log (resume without
## a save). "" or the error. Links the run.
func resume_into(run: RunController, content_index: ContentIndex, summary: Dictionary) -> String:
	var run_id := str(summary["runId"])
	var saved := load_save()
	link(run, run_id)
	if not saved.is_empty() and str(saved["runId"]) == run_id and save_seq(saved) >= int(summary["lastSeq"]):
		return _load_save_into(run, content_index, saved)
	if str(summary["status"]) != "Active":
		return "run %s is %s on the server" % [run_id, summary["status"]]
	return await _resume_from_server(run, content_index)


func _load_save_into(run: RunController, content_index: ContentIndex, saved: Dictionary) -> String:
	var error := run.load_snapshot(content_index, saved["snapshot"])
	if error != "":
		return error
	var floor_seeds: Dictionary = saved.get("floorSeeds", {})
	for floor_index in floor_seeds:  # seeds issued after the snapshot (at the stairs)
		run.state.floor_seeds[str(floor_index).to_int()] = str(floor_seeds[floor_index]).to_int()
	_queue.assign(saved.get("queue", []))
	_last_acked = int(saved.get("lastAckedSeq", 0))
	_end_request = saved.get("end", {})
	_snapshot = saved["snapshot"]
	_resumed(run, "save")
	return ""


## Spec main-menu (offline Continue): continues the local save without asking the server first, like Steam Cloud
## playing offline. Its queued actions upload when the server answers; if the server's log has moved on (another
## window played on, the save is out of date) the upload is refused and the run is rebuilt from the server (a 1103)
## or stopped. "" or the error.
func resume_offline(run: RunController, content_index: ContentIndex) -> String:
	var saved := load_save()
	if saved.is_empty():
		return "no saved run"
	link(run, str(saved["runId"]))
	return _load_save_into(run, content_index, saved)


## Rebuilds the run from GET /resume: the latest checkpoint snapshot, then the accepted actions after it replayed on a
## run of its own (no screens, no queue), checked against each action's state hash, then loaded into `run`.
func _resume_from_server(run: RunController, content_index: ContentIndex) -> String:
	var result := await _request("Resume", [_run_id])
	if not result["ok"]:
		return "resume: " + describe(result["error"])
	var data: Dictionary = result["data"]
	if data["snapshot"] == null:
		return "resume: the server has no checkpoint for run %s yet" % _run_id
	var replay := RunController.new()
	replay.name = "ResumeReplay"
	add_child(replay)
	var error := replay.load_snapshot(content_index, data["snapshot"])
	for floor_seed in data["floorSeeds"]:
		replay.state.floor_seeds[int(floor_seed["floor"])] = str(floor_seed["floorSeed"]).to_int()
	var last_seq := int(data["checkpointSeq"])
	for request in data["tail"] if error == "" else []:
		error = await RunWire.apply(replay, request["action"])
		if error == "" and replay.runner_error != "":
			error = replay.runner_error
		if error == "" and replay.state.run_hash() != str(request["stateHash"]):
			error = "the replay differs from the server's log at seq %d" % int(request["seq"])
		if error != "":
			error = "resume: seq %d: %s" % [int(request["seq"]), error]
			break
		last_seq = int(request["seq"])
	var snapshot := replay.snapshot() if error == "" else {}
	replay.free()
	if error != "":
		return error
	error = run.load_snapshot(content_index, snapshot)
	if error != "":
		return error
	_queue.clear()
	_last_acked = last_seq
	_end_request = {}
	_snapshot = snapshot
	_resumed(run, "server")
	return ""


## A 1103: the server accepted actions this client doesn't have. The save is discarded and the run rebuilt from the
## server's log (after the battle in progress, if any); whatever was never accepted is gone.
func _rebuild_after_conflict(run: RunController) -> void:
	forget_save()
	_queue.clear()
	if run.current_battle != null:
		await run.battle_finished
	var content_index := run.content
	var wait := StringName("rebuild/" + _run_id)
	begin_wait(wait, wait_rebuild_text)
	var error := await _resume_from_server(run, content_index)
	end_wait(wait)
	if error != "":
		run.stop_on_server_error(error)
	else:
		GameplayMessages.broadcast(GameplayMessageRouter.NOTIFICATION,
			NotificationMessage.make("The run continues from the server's log"))


func _resumed(run: RunController, source: String) -> void:
	resumes += 1
	save()
	run.announce_resumed()
	if run.waiting_for_floor() >= 0:
		_fetch_floor(run, _run_id, run.waiting_for_floor())
	resumed.emit(source)
	if not _end_request.is_empty():
		_finish_win(run)
	else:
		_pump()


## Dev only (the console's `server conflict`, spec dev-tools E9): sends the last acknowledged action again with another
## state hash, so the server answers 1103 and the conflict path runs end to end. "" or why not.
func dev_conflict() -> String:
	if not _linked() or _last_sent.is_empty():
		return "no acknowledged action to conflict with"
	var changed: Dictionary = _last_sent.duplicate(true)
	changed["stateHash"] = "conflict-" + str(changed["stateHash"])
	_queue.push_front(changed)
	_pump()
	return ""


# --- Waiting (spec playtest-fixes B9) ----------------------------------------------------------------------------

## The player can't go on until the server answers: `text` shows in the connecting pop-up until end_wait(key). A key
## already waiting gets the new text. Keys with a "/" belong to the linked run (they end when another run is
## linked). Background work (uploads, the heartbeat) never waits this way.
func begin_wait(key: StringName, text: String) -> void:
	_waits.erase(key)
	_waits[key] = text
	waiting_changed.emit(waiting_text())


func end_wait(key: StringName) -> void:
	if _waits.erase(key):
		waiting_changed.emit(waiting_text())


## A newly linked run: the waits of the run before it end (its retries may go on, but nobody waits on them).
func _end_run_waits() -> void:
	var before := _waits.size()
	for key in _waits.keys():
		if String(key).contains("/"):
			_waits.erase(key)
	if _waits.size() != before:
		waiting_changed.emit(waiting_text())


## The newest wait's text, or "" when the player waits on nothing.
func waiting_text() -> String:
	return "" if _waits.is_empty() else str(_waits.values()[-1])


## Spec playtest-fixes B10: signed in and the last request got an answer.
func connected() -> bool:
	return _token != "" and _answered == true


# --- Presence (spec 3.6) ------------------------------------------------------------------------------------------

## POST /presence with what the player is doing (Menu, Map, Battle). A hint; errors are ignored.
func heartbeat() -> void:
	var activity := "Menu"
	if _linked() and _run.state.status == RunState.ACTIVE:
		activity = "Battle" if not _run.pending_battle.is_empty() else "Map"
	await _request("Heartbeat", [WireJson.stringify({"activity": activity})])


func _linked() -> bool:
	return _run != null and is_instance_valid(_run) and _run.state != null and _run.state.run_id == _run_id


## No answer, a server error or rate limiting: worth retrying. A 4xx refusal is not.
static func retryable(error: Dictionary) -> bool:
	var status := int(error.get("status", 0))
	return status == 0 or status == 429 or status >= 500


## One line for the player: "409 Floor not reachable (1105)".
static func describe(error: Dictionary) -> String:
	var code: Variant = error.get("errorCode")
	var status := int(error.get("status", 0))
	return "%s%s%s" % ["%d " % status if status > 0 else "no connection: ", str(error.get("title", "")),
		" (%d)" % int(code) if code != null else ""]


## A refusal the run can't go on after: it stops (not a loss). A 1101 means the server already ended this run (two
## windows or devices on one player): nothing here can still be accepted, so the save goes too and the player is told
## plainly instead of seeing the raw error.
func _refused(run: RunController, error: Dictionary) -> void:
	if int(_code(error)) == RUN_NOT_ACTIVE:
		if run == _run:
			_queue.clear()
			forget_save()
		run.stop_on_server_error(ENDED_ELSEWHERE)
	else:
		run.stop_on_server_error(describe(error))


static func _code(error: Dictionary) -> Variant:
	return error.get("errorCode") if error.get("errorCode") != null else 0


## Waits `delay` ±25% jitter, or the Retry-After the server sent.
func _backoff(error: Dictionary, delay: float) -> void:
	var after: Variant = error.get("retryAfterSeconds")
	var wait: float = float(after) if after != null else delay * randf_range(0.75, 1.25)
	await get_tree().create_timer(wait).timeout


func _fetch_floor(run: RunController, run_id: String, floor_index: int) -> void:
	var wait := StringName("floor/%s/%d" % [run_id, floor_index])
	begin_wait(wait, wait_floor_text)
	var result := await floor_seed_until_issued(run_id, floor_index)
	end_wait(wait)
	if not is_instance_valid(run) or run.state == null or run.state.run_id != run_id:
		return  # the run was left meanwhile
	if result["ok"]:
		run.provide_floor_seed(floor_index, str(result["data"]["floorSeed"]).to_int())
		if run == _run:
			save()  # the save knows the seed: resumed there, the floor opens even offline
	else:
		_refused(run, result["error"])


## One call through the bridge with the player's token (fetched first; once more after a 401).
func _request(method: String, args: Array) -> Dictionary:
	var signed := await _sign_in()
	if not signed["ok"]:
		return signed
	var result := await _await(bridge.callv(method, args))
	if not result["ok"] and int(result["error"].get("status", 0)) == 401:
		_token = ""  # expired or from another server: one fresh token, then once more
		signed = await _sign_in()
		if not signed["ok"]:
			return signed
		result = await _await(bridge.callv(method, args))
	return result


## POST /auth/dev-token for `player` once (concurrent callers wait for the same answer).
func _sign_in() -> Dictionary:
	if _token != "":
		return {"ok": true, "data": null, "error": {}}
	if _signing_in:
		await _signed_in
		return {"ok": _token != "", "data": null, "error": _sign_in_error}
	_signing_in = true
	var result := await _await(bridge.GetDevToken(WireJson.stringify({"playerName": player})))
	_signing_in = false
	if result["ok"]:
		_token = str(result["data"]["accessToken"])
		player_id = str(result["data"].get("playerId", ""))
		bridge.SetToken(_token)
		_sign_in_error = {}
		connection_changed.emit()
	else:
		_sign_in_error = result["error"]
	_signed_in.emit()
	return result if not result["ok"] else {"ok": true, "data": null, "error": {}}


func _await(request_id: int) -> Dictionary:
	while not _results.has(request_id):
		await _completed
	var result: Dictionary = _results[request_id]
	_results.erase(request_id)
	return result


func _on_completed(request_id: int, ok: bool, json: String) -> void:
	var parsed: Variant = JSON.parse_string(json)
	var answered := ok or (parsed is Dictionary and int(parsed.get("status", 0)) > 0)
	if answered != _answered:
		_answered = answered
		if _heartbeat != null:
			_heartbeat.wait_time = heartbeat_seconds if answered else offline_heartbeat_seconds
		connection_changed.emit()
	if ok:
		_results[request_id] = {"ok": true, "data": parsed, "error": {}}
	else:
		_results[request_id] = {"ok": false, "data": null,
			"error": parsed if parsed is Dictionary else {"status": 0, "title": "unreadable error", "detail": json}}
	_completed.emit()
