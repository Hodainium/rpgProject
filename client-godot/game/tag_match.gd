## GodotGAS tag-query rules against a plain tag list (spec game-skeleton 3.1, "Tag pools").
##
## GameplayTagQuery.matches() only accepts an ASC; content (rooms, encounters, items) carries tags as arrays. This
## evaluates the same five fields with the same semantics: a query tag matches itself and its children (`Chapter`
## matches `Chapter.Basement`), the *_exact fields match only the exact tag, and an empty field is ignored.
## tests/game/test_tag_match.gd checks every case against the addon on a real ASC.
class_name TagMatch
extends RefCounted


## True when `tags` contains `tag` or one of its children.
static func has(tags: Array, tag: StringName) -> bool:
	var prefix := String(tag) + "."
	for owned in tags:
		if owned == tag or String(owned).begins_with(prefix):
			return true
	return false


static func has_any(tags: Array, wanted: Array) -> bool:
	for tag in wanted:
		if has(tags, tag):
			return true
	return false


## A null query matches everything, like an empty one.
static func matches(query: GameplayTagQuery, tags: Array) -> bool:
	if query == null:
		return true
	if not query.ignore_tags.is_empty() and has_any(tags, query.ignore_tags):
		return false
	for tag in query.ignore_exact_tags:
		if tags.has(tag):
			return false
	if not query.require_all_tags.is_empty():
		for tag in query.require_all_tags:
			if not has(tags, tag):
				return false
	for tag in query.require_exact_tags:
		if not tags.has(tag):
			return false
	if not query.require_any_tags.is_empty() and not has_any(tags, query.require_any_tags):
		return false
	return true
