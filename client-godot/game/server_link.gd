## The client's link to Rpg.GameServerApi (spec server-authority 3.7, Part A): await-able wrappers over the C#
## ServerBridge (the one adapter; whole Rpg.Contracts records as JSON), floor seeds fetched for a linked run with
## backoff while offline, and server errors that stop a run. Holds no game rules: the run plays every floor offline
## from its issued seed.
##
## Server mode is on when the Settings (user://game_main.cfg, section "server") name a url; the console's `server`
## sets it. Tests give it a fake bridge with the same methods and the Completed signal. Every call resolves to
## {"ok": bool, "data": the response record parsed (null for a 204), "error": {"status" (0 = no response),
## "errorCode", "title", "detail", "retryAfterSeconds"}}.
class_name ServerLink
extends Node

signal _completed

const SETTINGS_SECTION: String = "server"
const BRIDGE_SCRIPT: String = "res://net/ServerBridge.cs"
const TIMEOUT_SECONDS: float = 10.0

## Backoff for a floor seed while offline: doubles from base up to max, ±25% jitter; a Retry-After wins.
var retry_base_seconds: float = 1.0
var retry_max_seconds: float = 30.0

var bridge: Object
var _results: Dictionary = {}


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
	var script: Script = load(BRIDGE_SCRIPT)
	if script == null or not script.can_instantiate():
		push_error("ServerLink: %s is not built (dotnet build); playing in local mode" % BRIDGE_SCRIPT)
		return null
	var bridge_node: Object = script.new()
	bridge_node.Configure(url, str(GameMain.load_setting(SETTINGS_SECTION, "player", "")), TIMEOUT_SECONDS)
	return ServerLink.new(bridge_node)


## POST /api/v1/runs: data = RunStartResponse {runId, floor, floorSeed, startedAt}.
func start_run(ruleset_version: String, run_structure_id: String, character_ids: Array) -> Dictionary:
	var request := {"rulesetVersion": ruleset_version, "runStructureId": run_structure_id,
		"characterIds": character_ids.map(func(id) -> String: return str(id))}
	return await _await(bridge.StartRun(WireJson.stringify(request)))


## POST /api/v1/runs/{runId}/floors/{floor}, once: data = FloorSeedResponse {runId, floor, floorSeed}.
func floor_seed(run_id: String, floor_index: int) -> Dictionary:
	return await _await(bridge.GetFloorSeed(run_id, floor_index, WireJson.stringify({"afterSeq": null})))


## The floor seed, retried with backoff while there is no answer, a 5xx or a 429; any other error returns at once.
func floor_seed_until_issued(run_id: String, floor_index: int) -> Dictionary:
	var delay := retry_base_seconds
	while true:
		var result := await floor_seed(run_id, floor_index)
		if result["ok"] or not retryable(result["error"]):
			return result
		var after: Variant = result["error"].get("retryAfterSeconds")
		var wait: float = float(after) if after != null else delay * randf_range(0.75, 1.25)
		await get_tree().create_timer(wait).timeout
		delay = minf(delay * 2.0, retry_max_seconds)
	return {}


## GET /api/v1/runs/{runId}: data = RunSummaryResponse.
func get_run(run_id: String) -> Dictionary:
	return await _await(bridge.GetRun(run_id))


## GET /api/v1/runs/current: data = RunSummaryResponse, or null when the player has no active run.
func get_current_run() -> Dictionary:
	return await _await(bridge.GetCurrentRun())


## Answers the run's floor_seed_needed with the issued seeds; a refusal stops the run (not a loss).
func link(run: RunController, run_id: String) -> void:
	run.floor_seed_needed.connect(func(floor_index: int) -> void: _fetch_floor(run, run_id, floor_index))


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


func _fetch_floor(run: RunController, run_id: String, floor_index: int) -> void:
	var result := await floor_seed_until_issued(run_id, floor_index)
	if not is_instance_valid(run) or run.state == null or run.state.run_id != run_id:
		return  # the run was left meanwhile
	if result["ok"]:
		run.provide_floor_seed(floor_index, str(result["data"]["floorSeed"]).to_int())
	else:
		run.stop_on_server_error(describe(result["error"]))


func _await(request_id: int) -> Dictionary:
	while not _results.has(request_id):
		await _completed
	var result: Dictionary = _results[request_id]
	_results.erase(request_id)
	return result


func _on_completed(request_id: int, ok: bool, json: String) -> void:
	var parsed: Variant = JSON.parse_string(json)
	if ok:
		_results[request_id] = {"ok": true, "data": parsed, "error": {}}
	else:
		_results[request_id] = {"ok": false, "data": null,
			"error": parsed if parsed is Dictionary else {"status": 0, "title": "unreadable error", "detail": json}}
	_completed.emit()
