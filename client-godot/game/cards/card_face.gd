## Spec card-ui 3.3: what one card face shows, as plain data (no Node): built by CardFaces.build from the content and the catalog,
## drawn by a CardFaceView scene (Look A or B). Presentation only: never in a hash, snapshot or upload.
class_name CardFace
extends RefCounted

const KIND_CHARACTER: String = "character"
const KIND_ITEM: String = "item"
const KIND_EQUIPMENT: String = "equipment"

var id: String = ""
## character, item or equipment (armor and weapons).
var kind: String = KIND_ITEM
var name: String = ""
var text: String = ""
## Magic's type line: "<Kind> — <subtype>" ("Character — Tank", "Item — Passive · Treasure", "Armor — Weapon").
var type_line: String = ""
## common .. mythic (the catalog's names).
var rarity: String = "common"
var set_id: String = ""
var core: bool = false
## Room pools without the "Pool." prefix (Treasure, Shop, ...).
var pools: Array[String] = []
## The element's key in CardStyle.elements: tints the art window and the glyph; never shown as a badge.
var element: StringName = &"neutral"
## Item.Corrupted (the Void pool): the corrupted frame.
var corrupted: bool = false
## An item's glyph (null: the style's default icon, with a warning).
var icon: Texture2D
## A character's prerendered portrait (null until the portrait tool has run).
var portrait: Texture2D
## Equipment.Slot.<Name> → "Weapon", "Body", ...
var slot: String = ""
## A catalog card the local content does not know (catalog drift, spec 2.1): drawn as "Unknown card".
var unknown: bool = false


## The plain fields, for the golden and the console.
func to_dict() -> Dictionary:
	return {"id": id, "kind": kind, "name": name, "text": text, "type": type_line, "rarity": rarity, "set": set_id, "core": core,
		"pools": pools.duplicate(), "element": String(element), "corrupted": corrupted, "slot": slot, "unknown": unknown,
		"icon": icon.resource_path if icon != null else "", "portrait": portrait.resource_path if portrait != null else ""}
