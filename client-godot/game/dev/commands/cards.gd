## Spec card-collection 3.6: the account's cards (server mode) and the local test collection (local mode).
extends DevCommand


func _init() -> void:
	name = "cards"
	usage = "cards [local [core|all|<id> ...] | catalog | issues]"
	help = "Server mode, no argument: the account's cards, gems, dust and pity counters (everything lives on the server). local: the local test collection, the item pool new LOCAL runs start with; local core = the core set only, local all = everything (today's default), local <id> ... = exactly those items. It is a test pool: no ownership, no currency, never sent to a server. catalog: how many cards the content has and how many are core. issues: the card problems of the content."
	cheat = false


func run(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game == null:
		return ctx.fail("no game")
	if args.size() > 0 and args[0] == "local":
		return _local(ctx, args.slice(1))
	if args.size() > 0 and args[0] == "catalog":
		return _catalog(ctx)
	if args.size() > 0 and args[0] == "issues":
		var problems := CardCatalog.problems(ctx.game.content)
		if problems.is_empty():
			return "no card problems" if not ctx.game.content.card_rules.is_empty() else "no card rules in this content: no card checks"
		return "\n".join(PackedStringArray(problems.map(func(p: Array) -> String: return "%s %s: %s" % [p[0], p[1], p[2]])))
	if ctx.game.server == null:
		return "local mode: the account is on the server. Test pool: " + _pool_text(ctx.game.local_card_pool) \
			+ " (cards local core|all|<id> ... sets it; connect with `server <url>` for the real collection)"
	var answer: Dictionary = await ctx.game.server.get_collection()
	if not answer["ok"]:
		return ctx.fail("GET cards/collection: " + ServerLink.describe(answer["error"]))
	return ServerLink.describe_collection(answer["data"])


func _local(ctx: DevContext, args: PackedStringArray) -> String:
	if ctx.game.server != null:
		return ctx.fail("server mode: a run takes only the server's pool (use `server off` first)")
	if args.is_empty():
		return "local test pool: " + _pool_text(ctx.game.local_card_pool)
	if args[0] == "all":
		ctx.game.local_card_pool = null
		return "local test pool: everything (new local runs)"
	if args[0] == "core":
		ctx.game.local_card_pool = CardCatalog.core_item_ids(ctx.game.content)
		if ctx.game.local_card_pool.is_empty():
			ctx.game.local_card_pool = null
			return ctx.fail("this content has no core cards (no Card.Set.Core tags); the pool stays everything")
		return "local test pool: the core set, %d item(s) (new local runs)" % ctx.game.local_card_pool.size()
	var ids: Array[StringName] = []
	for arg in args:
		var id := StringName(arg)
		if not ctx.game.content.items.has(id) and not ctx.game.content.equipment.has(id):
			return ctx.fail("unknown item or equipment '%s'" % arg)
		ids.append(id)
	ctx.game.local_card_pool = ids
	return "local test pool: %d item(s) (new local runs)" % ids.size()


func _catalog(ctx: DevContext) -> String:
	var cards := CardCatalog.cards(ctx.game.content)
	var kinds := {}
	var core := 0
	for card in cards:
		var key: String = "%s/%s" % [card["kind"], card["rarity"] if card["rarity"] != "" else "?"]
		kinds[key] = int(kinds.get(key, 0)) + 1
		core += 1 if card["core"] else 0
	var parts := PackedStringArray()
	var keys := kinds.keys()
	keys.sort()
	for key in keys:
		parts.append("%s %d" % [key, kinds[key]])
	var lines := PackedStringArray(["%d card(s), %d core: %s" % [cards.size(), core, ", ".join(parts)]])
	var counts := CardCatalog.pool_counts(ctx.game.content)
	for pool in counts:
		lines.append("  %s: %d core / target %d" % [pool, counts[pool][0], counts[pool][1]])
	return "\n".join(lines)


static func _pool_text(pool: Variant) -> String:
	return "everything" if pool == null else "%d item(s)" % pool.size()
