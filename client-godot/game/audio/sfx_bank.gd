## Spec audio-pass 2.2 / 3.1: the sound bank's manifest (presentation/audio/sfx/manifest.json), read-only. Each row is one bank entry
## `presentation/audio/sfx/bank/<id>.tres` (an AudioStreamRandomizer over the row's imported takes). Everything that plays a sound
## refers to a bank entry, never to a .wav, so swapping a sound is one file. Used by the bank builder, the audio pass, the validator
## and the console. Presentation only.
class_name SfxBank
extends RefCounted

const MANIFEST := "res://presentation/audio/sfx/manifest.json"
const BANK_DIR := "res://presentation/audio/sfx/bank/"
const SFX_DIR := "res://presentation/audio/sfx/"
const ALLOWED_LICENCES: PackedStringArray = ["CC0-1.0", "CC-BY-3.0", "CC-BY-4.0"]
const FORBIDDEN_DIR := "do_not_include"

var data: Dictionary = {}
var problem: String = ""


static func load_manifest(path: String = MANIFEST) -> SfxBank:
	var bank := SfxBank.new()
	if not FileAccess.file_exists(path):
		bank.problem = "no manifest at %s" % path
		return bank
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		bank.problem = "the manifest %s is not a JSON object" % path
		return bank
	bank.data = parsed
	return bank


func entries() -> Array:
	return data.get("entries", [])


func packs() -> Dictionary:
	return data.get("packs", {})


func entry(id: String) -> Dictionary:
	for row in entries():
		if str(row.get("id", "")) == id:
			return row
	return {}


func has(id: String) -> bool:
	return not entry(id).is_empty()


func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for row in entries():
		out.append(str(row.get("id", "")))
	return out


static func bank_path(id: String) -> String:
	return BANK_DIR + id + ".tres"


## The res:// path of a row's take (the import tool's naming: <pack>/<id>.wav, or <id>_<n>.wav when the row has several takes).
static func take_path(row: Dictionary, index: int) -> String:
	var takes: Array = row.get("takes", [])
	var suffix := "" if takes.size() == 1 else "_%d" % (index + 1)
	return SFX_DIR + "%s/%s%s.wav" % [row.get("pack", ""), row.get("id", ""), suffix]


func target_of(category: String) -> float:
	return float(data.get("targets", {}).get(category, 0.0))


func max_ms_of(category: String) -> int:
	return int(data.get("max_ms", {}).get(category, 0))


func is_reserved(row: Dictionary) -> bool:
	return bool(packs().get(str(row.get("pack", "")), {}).get("reserved", false))


func reserved_allow() -> PackedStringArray:
	return PackedStringArray(data.get("reserved_allow", []))


## Ability ids the manifest lists as silent on purpose (validator `sfx_missing` skips them).
func silent() -> PackedStringArray:
	return PackedStringArray(data.get("silent", []))


## The default random pitch and volume spread of a category (a row's own `pitch_random` / `volume_random_db` win).
static func default_variation(category: String) -> Vector2:
	match category:
		"impact":
			return Vector2(1.06, 1.0)
		"cast", "status":
			return Vector2(1.04, 0.5)
		"run":
			return Vector2(1.02, 0.0)
	return Vector2(1.0, 0.0)  # ui, moment, signature: the same every time
