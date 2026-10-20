## The seed runner's model (spec dev-tools 2.5): what a seed generates, floor by floor, without playing it; and
## statistics over many seeds to tune FloorGenRules. Pure: (seed, content) → floors. Integers only, keys sorted.
class_name SeedReport
extends RefCounted


## Floors 0..floor_index of `seed_value`, generated in order with one pools object (so items seen on earlier floors are
## left out later, as in a run; items given by events or bought are not simulated). `rules` (optional) replaces the
## chapter's FloorGenRules, for tuning a copy. {"map": FloorMap or null, "chapter": StringName, "error": String}.
static func floor_of(content: ContentIndex, seed_value: int, floor_index: int, rules: FloorGenRules = null) -> Dictionary:
	if content.runs.size() != 1:
		return {"map": null, "chapter": &"", "error": "the content root needs exactly one RunStructure"}
	var structure: RunStructure = content.runs.values()[0]
	if floor_index < 0 or floor_index >= structure.floors.size():
		return {"map": null, "chapter": &"", "error": "floors are 0 to %d" % (structure.floors.size() - 1)}
	var pools := {"party": [], "held": [], "seen": []}
	var result := {}
	for index in floor_index + 1:
		var slot: FloorSlot = structure.floors[index]
		var chapter_rng := RunSeeds.rng(seed_value, "floor/%d/chapter" % index)
		var chapter: ChapterDefinition = slot.chapters[chapter_rng.randi_range(0, slot.chapters.size() - 1)]
		if rules != null and index == floor_index:
			chapter = chapter.duplicate()
			chapter.floor_gen_rules = rules
		var generator := FloorGenerator.new(content, structure, seed_value, index)
		if slot.layout != null:
			result = generator.from_layout(slot.layout, chapter, pools)
		else:
			result = generator.generate(chapter, slot.rooms_from_any_chapter, pools)
		result["chapter"] = chapter.id
		if result["error"] != "":
			return result
	return result


## Statistics for seeds from..from+count-1 on one floor.
static func many(content: ContentIndex, from: int, count: int, floor_index: int, rules: FloorGenRules = null) -> Dictionary:
	var report := {"floor": floor_index, "from": from, "count": count, "failures": [], "attempts": {}, "rooms": {},
		"dead_ends": {}, "rooms_used": {}, "encounters": {}, "events": {}, "elites": {}, "items": {}}
	var attempts: Array[int] = []
	var rooms: Array[int] = []
	var dead_ends: Array[int] = []
	for seed_value in range(from, from + count):
		var result := floor_of(content, seed_value, floor_index, rules)
		if result["error"] != "":
			report["failures"].append({"seed": seed_value, "error": result["error"]})
			continue
		var map: FloorMap = result["map"]
		attempts.append(map.attempts)
		rooms.append(map.cells.size())
		dead_ends.append(FloorGenerator._dead_ends(map).size())
		for index in map.sorted_indices():
			var data: Dictionary = map.cells[index]
			_count(report["rooms_used"], data["room"])
			var cell_content: Dictionary = data["content"]
			if cell_content["kind"] == "encounter":
				_count(report["encounters"], cell_content["encounter"])
				for enemy in cell_content["enemies"]:
					if enemy["variantId"] != null:
						_count(report["elites"], enemy["variantId"])
			elif cell_content["kind"] == "event":
				_count(report["events"], cell_content["event"])
			for pickup in data["pickups"]:
				_count(report["items"], pickup["item"])
	report["attempts"] = _spread(attempts)
	report["rooms"] = _spread(rooms)
	report["dead_ends"] = _spread(dead_ends)
	for key in ["rooms_used", "encounters", "events", "elites", "items"]:
		report[key] = _sorted(report[key])
	return report


## The report as text, most frequent first.
static func text(report: Dictionary) -> String:
	var lines := PackedStringArray(["floor %d, seeds %d..%d: %d failed" % [report["floor"], report["from"],
		report["from"] + report["count"] - 1, report["failures"].size()]])
	for key in ["attempts", "rooms", "dead_ends"]:
		var spread: Dictionary = report[key]
		if not spread.is_empty():
			lines.append("  %-9s min %d  avg %.2f  max %d" % [key, spread["min"], spread["avg_x100"] / 100.0, spread["max"]])
	for key in ["rooms_used", "encounters", "events", "elites", "items"]:
		var counts: Dictionary = report[key]
		var ids := counts.keys()
		ids.sort_custom(func(a, b) -> bool: return counts[a] > counts[b] or (counts[a] == counts[b] and a < b))
		lines.append("  %s: %s" % [key, ", ".join(ids.map(func(id) -> String: return "%s ×%d" % [id, counts[id]]))])
	for failure in report["failures"].slice(0, 10):
		lines.append("  FAILED seed %d: %s" % [failure["seed"], failure["error"]])
	return "\n".join(lines)


static func _count(counts: Dictionary, id: Variant) -> void:
	counts[String(id)] = counts.get(String(id), 0) + 1


@warning_ignore("integer_division")
static func _spread(values: Array[int]) -> Dictionary:
	if values.is_empty():
		return {}
	var total := 0
	for value in values:
		total += value
	return {"min": values.min(), "avg_x100": total * 100 / values.size(), "max": values.max()}


static func _sorted(counts: Dictionary) -> Dictionary:
	var keys := counts.keys()
	keys.sort()
	var result := {}
	for key in keys:
		result[key] = counts[key]
	return result
