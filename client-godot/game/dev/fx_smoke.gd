## Plays effects headless to see that they hold together (spec vfx-framework 6): each is validated, then played on an
## anchor made for its space (a card-sized Control, a Node3D, a hybrid stage, the screen) on a scripted clock until it
## ends (a looping one is stopped after 2 s) at every quality tier asked for. Nothing is drawn; this checks the data, the
## lifecycle and that no script error fires. The result per effect is {id, problems, tiers: {tier: {played, seconds,
## layers, skipped}}}. Dev tooling (the console's `fx`, game/tools/fx_smoke.tscn and test_fx use it).
class_name FxSmoke
extends RefCounted

const STEP: float = 1.0 / 30.0
const LIMIT: float = 30.0


## Runs `ids` (all of the service's effects when empty). `host` is a node in the tree the anchors hang under.
static func run(host: Node, service: FxService, ids: Array = [], tiers: Array = [FxQuality.HIGH], params: Dictionary = {}) -> Array:
	var results: Array = []
	var was_enabled := service.enabled
	var was_manual := service.manual_clock
	var was_quality := service.quality
	service.enabled = true
	service.manual_clock = true
	for id in (ids if not ids.is_empty() else service.catalog()):
		var definition := service.definition(StringName(id))
		var result := {"id": String(id), "problems": [], "tiers": {}}
		results.append(result)
		if definition == null:
			result["problems"].append("fx_unknown: no effect '%s'" % id)
			continue
		for problem in FxValidator.check(definition):
			result["problems"].append(str(problem))
		for tier in tiers:
			service.quality = tier
			result["tiers"][FxQuality.NAMES[tier]] = _play(host, service, definition, params)
	service.enabled = was_enabled
	service.manual_clock = was_manual
	service.quality = was_quality
	return results


## True when every result has no problems and every tier above `off` played.
static func all_ok(results: Array) -> bool:
	for result in results:
		if not (result["problems"] as Array).is_empty():
			return false
		for tier in result["tiers"]:
			if tier != "off" and not result["tiers"][tier]["played"]:
				return false
	return true


static func _play(host: Node, service: FxService, definition: FxDefinition, params: Dictionary) -> Dictionary:
	var made: Array[Node] = []
	var anchor := _anchor_for(host, definition, made)
	var handle := service.play(definition, anchor, params)
	var report := {"played": handle.is_playing(), "seconds": 0.0, "layers": definition.layers.size(), "skipped": 0}
	for state in handle.states:
		if state == FxHandle.LayerState.SKIPPED:
			report["skipped"] += 1
	var time := 0.0
	var stopped := false
	while handle.is_playing() and time < LIMIT:
		service.advance(STEP)
		time += STEP
		if definition.is_looping() and not stopped and time >= 2.0:
			handle.stop(0.2)
			stopped = true
	if handle.is_playing():
		handle.stop(0.0)
		report["played"] = false
		report["note"] = "still playing after %d s" % int(LIMIT)
	report["seconds"] = snappedf(time, 0.01)
	service.stop_all()
	for node in made:
		if is_instance_valid(node):
			node.free()
	return report


## The anchor an effect of this space belongs on (the nodes made for it go in `made` to be freed after).
static func _anchor_for(host: Node, definition: FxDefinition, made: Array[Node]) -> FxAnchor:
	match definition.space:
		FxDefinition.Space.UI:
			var card := Control.new()
			card.size = Vector2(190, 270)
			card.pivot_offset = card.size * 0.5
			host.add_child(card)
			made.append(card)
			return FxAnchor.control(card)
		FxDefinition.Space.WORLD_3D:
			var unit := MeshInstance3D.new()
			unit.mesh = BoxMesh.new()
			host.add_child(unit)
			made.append(unit)
			return FxAnchor.node3d(unit)
		FxDefinition.Space.HYBRID:
			var stage := FxStage.new()
			stage.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
			stage.size = Vector2(640, 520)
			host.add_child(stage)
			made.append(stage)
			var card := MeshInstance3D.new()
			card.mesh = BoxMesh.new()
			stage.world_root.add_child(card)
			return FxAnchor.on_stage(stage, card)
	return FxAnchor.screen()
