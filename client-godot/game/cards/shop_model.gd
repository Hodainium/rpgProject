## Spec card-ui 2.3a: what the Shop shows, from the server's PackListResponse and CollectionResponse (pure, testable
## headless): one offer per pack type on sale, with its price, size, odds in rarity order, the Rare-or-better guarantee, the
## pity rules and how many unopened packs of it the account holds. The screen formats the texts.
class_name ShopModel
extends RefCounted

## The Buy buttons of each offer (Buy 1, Buy 5).
const BUY_COUNTS: Array[int] = [1, 5]


## Offers in the server's order. Each: {packId, name, price, cardCount, owned, odds: [{rarity, per10000}], minRarity, pity:
## [{rarity, packs}]}; `owned` is -1 when the collection is unknown.
static func offers(packs: Dictionary, collection: Variant) -> Array[Dictionary]:
	var owned := {}
	if collection is Dictionary:
		for entry in collection.get("ownedPacks", []):
			if not entry.get("refundHeld", false):  # held for a support check: not openable, not counted (as on the main menu)
				owned[str(entry["packId"])] = int(entry["count"])
	var result: Array[Dictionary] = []
	for pack in packs.get("packs", []):
		var odds_in: Dictionary = pack.get("oddsPer10000", {})
		var pity_in: Dictionary = pack.get("pityPacks", {})
		var odds: Array[Dictionary] = []
		var pity: Array[Dictionary] = []
		for rarity in CardStyle.RARITY_ORDER:
			if odds_in.has(rarity) and int(odds_in[rarity]) > 0:
				odds.append({"rarity": rarity, "per10000": int(odds_in[rarity])})
			if pity_in.has(rarity) and int(pity_in[rarity]) > 0:
				pity.append({"rarity": rarity, "packs": int(pity_in[rarity])})
		var id := str(pack["packId"])
		result.append({"packId": id, "name": str(pack.get("name", id)), "price": int(pack.get("priceGems", 0)),
			"cardCount": int(pack.get("cardCount", 0)), "owned": int(owned.get(id, 0)) if collection is Dictionary else -1,
			"odds": odds, "minRarity": str(pack["minRarityPerPack"]) if pack.get("minRarityPerPack") != null else "",
			"pity": pity})
	return result


## The unopened packs the account can open (refund-held ones excluded): the main menu's Open packs count.
static func unopened(collection: Variant) -> int:
	var total := 0
	if collection is Dictionary:
		for entry in collection.get("ownedPacks", []):
			if not entry.get("refundHeld", false):
				total += int(entry["count"])
	return total


## The account's gems, or -1 when the collection is unknown.
static func gems(collection: Variant) -> int:
	return int(collection.get("gems", 0)) if collection is Dictionary else -1


## True when `gems` pays for `count` packs of `offer` (an unknown total never disables: the server decides).
static func affordable(offer: Dictionary, count: int, gems_total: int) -> bool:
	return gems_total < 0 or gems_total >= int(offer["price"]) * count


## "72.10%": odds per 10 000 as a percentage with two decimals.
static func percent(per10000: int) -> String:
	return "%d.%02d%%" % [per10000 / 100, per10000 % 100]
