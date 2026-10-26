## One floor of a run (spec game-skeleton, section 3.1).
@tool
class_name FloorSlot
extends Resource

## Spec playable-demo 3.8: how the chapter is picked. RANDOM: by the seed (floor/<n>/chapter). CHOICE: the player picks
## at the stairs (RunController.next_floor(chapter id); logged). ROUTE: the chapter whose route_tag matches the previous
## floor's chapter (no draw).
enum Pick { RANDOM, CHOICE, ROUTE }

## One is picked per run (alt paths), as `pick` says.
@export var chapters: Array[ChapterDefinition] = []
@export var pick: Pick = Pick.RANDOM
## Delirium-style: rooms come from every chapter's room pool.
@export var rooms_from_any_chapter: bool = false
## Optional hand-made floor, used instead of generating.
@export var layout: FloorLayout


## The chapter this slot plays (spec playable-demo 3.8): RANDOM draws from floor/<n>/chapter (as before); CHOICE takes
## `choice` (a chapter id; empty is an error when there are several); ROUTE takes the chapter whose route_tag matches
## `previous`'s (or `choice` when none matches: the console's `stage` jumping past the stairs).
## {"chapter": ChapterDefinition or null, "error": String}.
func pick_chapter(run_seed: int, floor_index: int, previous: ChapterDefinition, choice: StringName = &"") -> Dictionary:
	if chapters.is_empty() or chapters.has(null):
		return {"chapter": null, "error": "floor %d has no chapters" % floor_index}
	match pick:
		Pick.CHOICE:
			if choice == &"" and chapters.size() == 1:
				return {"chapter": chapters[0], "error": ""}
			for chapter in chapters:
				if chapter.id == choice:
					return {"chapter": chapter, "error": ""}
			return {"chapter": null, "error": "floor %d is a choice: pick one of %s" % [floor_index + 1,
				", ".join(chapters.map(func(chapter: ChapterDefinition) -> String: return String(chapter.id)))]}
		Pick.ROUTE:
			var route: StringName = previous.route_tag if previous != null else &""
			for chapter in chapters:
				if chapter.route_tag == route:
					return {"chapter": chapter, "error": ""}
			for chapter in chapters:
				if choice != &"" and chapter.id == choice:
					return {"chapter": chapter, "error": ""}
			return {"chapter": null, "error": "floor %d has no chapter on route '%s'" % [floor_index + 1, route]}
	var chapter_rng := RunSeeds.rng(run_seed, "floor/%d/chapter" % floor_index)
	return {"chapter": chapters[chapter_rng.randi_range(0, chapters.size() - 1)], "error": ""}
