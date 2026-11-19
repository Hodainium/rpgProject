## Spec card-ui 3.3: the five cards of one opened pack, as plain data (no Node, testable headless): built from the server's
## PackOpenResponse (or a made-up one for `cardui pack demo`), each slot with its rarity, tier, duplicate dust, pity and NEW;
## which are still face down, `reveal(i)`, `reveal_all()`, `done()`, and the texts under a flipped card. The pack screen plays
## the choreography over it; the cards are the account's whatever the screen does (spec 2.4: leaving never loses them).
## Presentation and client flow only: never in a run hash, snapshot or upload.
class_name PackReveal
extends RefCounted

## The texts under a flipped card (spec 2.4 beat 6); the pack screen sets them from its exports.
var rarity_text: String = "%s"
## Tier 3 and up (Legendary, Mythic): "Legendary!".
var big_rarity_text: String = "%s!"
var new_text: String = "NEW"
var duplicate_text: String = "+%d dust"
var pity_text: String = "Guaranteed"

var opening_id: String = ""
var pack_id: String = ""
## Packs of this type left after the open (PackOpenResponse.PacksLeft), -1 unknown.
var packs_left: int = -1
## The account's totals after the open, -1 unknown.
var gems: int = -1
var dust: int = -1
## {index, id, rarity, tier, duplicate, dust, pity, new, revealed}, in the server's order (the fan's positions).
var slots: Array[Dictionary] = []


## The reveal of `response` (a PackOpenResponse as a Dictionary). Tiers come from CardStyle.RARITY_ORDER (common 0 .. mythic 4).
static func from_response(response: Dictionary) -> PackReveal:
	var reveal := PackReveal.new()
	reveal.opening_id = str(response.get("openingId", ""))
	reveal.pack_id = str(response.get("packId", ""))
	reveal.packs_left = int(response.get("packsLeft", -1))
	reveal.gems = int(response.get("gems", -1))
	reveal.dust = int(response.get("dust", -1))
	for card in response.get("cards", []):
		var rarity := str(card.get("rarity", "common"))
		var duplicate := bool(card.get("duplicate", false))
		reveal.slots.append({"index": reveal.slots.size(), "id": str(card.get("cardId", "")), "rarity": rarity,
			"tier": tier_of(rarity), "duplicate": duplicate, "dust": int(card.get("dustGained", 0)) if duplicate else 0,
			"pity": bool(card.get("pity", false)), "new": not duplicate, "revealed": false})
	return reveal


## A made-up response for `cardui pack demo [rarity ...]` (presentation only: no account is touched). `cards` are catalog rows
## ({id, rarity}) to draw from; `rarities` the slots' rarities (padded with common to five, cut at five); the last card of a
## rarity seen twice is a duplicate (so the dust label shows), and a Legendary or Mythic slot is a pity card.
static func demo(cards: Array, rarities: Array) -> Dictionary:
	var wanted: Array[String] = []
	for rarity in rarities:
		wanted.append(str(rarity))
	while wanted.size() < 5:
		wanted.push_front("common")
	wanted = wanted.slice(0, 5)
	var by_rarity := {}
	for row in cards:
		var key := str(row.get("rarity", "common"))
		if not by_rarity.has(key):
			by_rarity[key] = []
		by_rarity[key].append(str(row["id"]))
	var picks: Array = []
	var used := {}
	for index in wanted.size():
		var rarity := wanted[index]
		var pool: Array = by_rarity.get(rarity, [])
		var card_id := "demo.%s" % rarity
		if not pool.is_empty():
			card_id = pool[int(used.get(rarity, 0)) % pool.size()]
		var duplicate := used.has(rarity)
		used[rarity] = int(used.get(rarity, 0)) + 1
		picks.append({"cardId": card_id, "rarity": rarity, "duplicate": duplicate, "dustGained": 5 * (tier_of(rarity) + 1) if duplicate else 0,
			"pity": tier_of(rarity) >= 3})
	return {"openingId": "demo", "packId": "demo", "packVersion": 0, "gemsSpent": 0, "cards": picks, "gems": -1, "dust": -1,
		"drawSeed": "0", "packsLeft": -1, "accountVersion": 0}


static func tier_of(rarity: String) -> int:
	return maxi(CardStyle.RARITY_ORDER.find(rarity), 0)


func size() -> int:
	return slots.size()


## Flips slot `index`; false when there is no such slot or it is already face up.
func reveal(index: int) -> bool:
	if index < 0 or index >= slots.size() or slots[index]["revealed"]:
		return false
	slots[index]["revealed"] = true
	return true


## Flips every card still face down; returns their indexes in flip order (left to right, top row first: the server's order).
func reveal_all() -> Array[int]:
	var flipped: Array[int] = []
	for index in hidden():
		reveal(index)
		flipped.append(index)
	return flipped


## The indexes still face down, in order.
func hidden() -> Array[int]:
	var result: Array[int] = []
	for slot in slots:
		if not slot["revealed"]:
			result.append(int(slot["index"]))
	return result


## The next card Space flips, or -1.
func next_hidden() -> int:
	var left := hidden()
	return left[0] if not left.is_empty() else -1


func done() -> bool:
	return not slots.is_empty() and hidden().is_empty()


## The rarity word under a flipped card ("Rare", "Legendary!").
func rarity_line(index: int) -> String:
	var slot: Dictionary = slots[index]
	var word := str(slot["rarity"]).capitalize()
	return (big_rarity_text if int(slot["tier"]) >= 3 else rarity_text) % word


## The second line under a flipped card: NEW, or the duplicate's dust, plus Guaranteed on a pity card.
func detail_line(index: int) -> String:
	var slot: Dictionary = slots[index]
	var parts := PackedStringArray([new_text if slot["new"] else duplicate_text % int(slot["dust"])])
	if slot["pity"]:
		parts.append(pity_text)
	return " · ".join(parts)


## The dust the duplicates gave.
func dust_gained() -> int:
	var total := 0
	for slot in slots:
		total += int(slot["dust"])
	return total


## The plain data, for the console and the tests.
func to_dict() -> Dictionary:
	return {"openingId": opening_id, "packId": pack_id, "packsLeft": packs_left, "gems": gems, "dust": dust,
		"cards": slots.map(func(slot: Dictionary) -> Dictionary: return slot.duplicate()), "done": done()}
