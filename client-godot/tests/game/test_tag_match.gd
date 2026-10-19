## TagMatch evaluates GameplayTagQuery on plain tag lists exactly like the addon does on an ASC (spec 3.1).
extends TestCase


func _query(field: String, tags: Array) -> GameplayTagQuery:
	var query := GameplayTagQuery.new()
	var typed: Array[StringName] = []
	typed.assign(tags)
	query.set(field, typed)
	return query


func test_agrees_with_addon_on_every_field() -> void:
	var tag_sets: Array = [
		[], [&"Chapter.Basement"], [&"Chapter"], [&"Chapter.Basement", &"Room.Type.Normal"], [&"Room.Type.Boss"],
		[&"ChapterX"], [&"Chapter.Caves.Deep"],
	]
	var queries: Array = [
		null,
		GameplayTagQuery.new(),
		_query("require_any_tags", [&"Chapter"]),
		_query("require_any_tags", [&"Room.Type.Boss", &"Chapter.Caves"]),
		_query("require_all_tags", [&"Chapter", &"Room.Type"]),
		_query("require_exact_tags", [&"Chapter"]),
		_query("ignore_tags", [&"Chapter"]),
		_query("ignore_exact_tags", [&"Chapter"]),
	]
	var asc := AbilitySystemComponent.new()
	host.add_child(asc)
	for tags in tag_sets:
		for tag in asc._active_tags.keys():
			asc.clear_tag(tag)
		for tag in tags:
			asc.add_tag(tag)
		for index in queries.size():
			var query: GameplayTagQuery = queries[index]
			var expected := true if query == null else query.matches(asc)
			eq(TagMatch.matches(query, tags), expected, "query %d on %s" % [index, tags])
	asc.free()


func test_parent_matching() -> void:
	check(TagMatch.has([&"Chapter.Basement"], &"Chapter"), "a parent tag matches its child")
	check(not TagMatch.has([&"ChapterX"], &"Chapter"), "a longer name is not a child")
	check(not TagMatch.has([&"Chapter"], &"Chapter.Basement"), "a child tag does not match its parent")
