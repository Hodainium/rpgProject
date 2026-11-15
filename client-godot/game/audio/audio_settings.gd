## Spec audio-pass 3.3: the player's volume per audio bus (Master, Effects, Interface), 0–100, saved in user://game_main.cfg
## [settings] (`volume_master`, `volume_sfx`, `volume_ui`); GameMain applies them at boot, the Audio screen and the console's
## `audio volume` change them at once. 0 silences a bus by volume (−80 dB), never by mute, so the headless `RPG_MUTE` mute of Master
## (Watchdog) is never undone. Presentation only: nothing here reaches a run, a battle, a hash or an upload.
class_name AudioSettings
extends RefCounted

const SETTINGS_SECTION: String = "settings"
## The settings by short name, in the order the Audio screen and the console list them: [bus, settings key, label].
const VOLUMES: Dictionary = {
	"master": [&"Master", "volume_master", "Master"],
	"sfx": [&"Sfx", "volume_sfx", "Effects"],
	"ui": [&"Ui", "volume_ui", "Interface"],
}
const DEFAULT: int = 100
const SILENT_DB: float = -80.0


static func names() -> PackedStringArray:
	return PackedStringArray(VOLUMES.keys())


static func bus_of(volume_name: String) -> StringName:
	return VOLUMES[volume_name][0] if VOLUMES.has(volume_name) else &""


static func label_of(volume_name: String) -> String:
	return VOLUMES[volume_name][2] if VOLUMES.has(volume_name) else volume_name


## The saved volume (missing or out of range reads as the default, clamped).
static func saved(volume_name: String) -> int:
	if not VOLUMES.has(volume_name):
		return DEFAULT
	return clampi(int(GameMain.load_setting(SETTINGS_SECTION, VOLUMES[volume_name][1], DEFAULT)), 0, 100)


## The bus gain for a volume of 0–100: linear, so 50 is half the amplitude; 0 is silent.
static func db_of(value: int) -> float:
	return SILENT_DB if value <= 0 else maxf(SILENT_DB, linear_to_db(clampi(value, 0, 100) / 100.0))


## Applies a volume to its bus now. Returns "" or a problem (an unknown name, a bus missing from the layout).
static func apply(volume_name: String, value: int) -> String:
	if not VOLUMES.has(volume_name):
		return "unknown volume '%s' (%s)" % [volume_name, " | ".join(names())]
	var index := AudioServer.get_bus_index(VOLUMES[volume_name][0])
	if index < 0:
		return "the bus %s is not in the bus layout (default_bus_layout.tres)" % VOLUMES[volume_name][0]
	AudioServer.set_bus_volume_db(index, db_of(value))
	return ""


## Applies and saves (the Audio screen and the console). Nothing is saved on a problem.
static func set_volume(volume_name: String, value: int) -> String:
	var problem := apply(volume_name, clampi(value, 0, 100))
	if problem == "":
		GameMain.save_setting(SETTINGS_SECTION, VOLUMES[volume_name][1], clampi(value, 0, 100))
	return problem


## Applies every saved volume (GameMain at boot). Problems are pushed, never fatal: a missing bus plays on Master.
static func apply_saved() -> void:
	for volume_name in VOLUMES:
		var problem := apply(volume_name, saved(volume_name))
		if problem != "":
			push_warning("AudioSettings: " + problem)


## The volume a bus is at now, 0–100 (for the console and tests); -1 when the bus is missing.
static func current(volume_name: String) -> int:
	var index := AudioServer.get_bus_index(bus_of(volume_name))
	if index < 0:
		return -1
	var db := AudioServer.get_bus_volume_db(index)
	return 0 if db <= SILENT_DB + 0.01 else int(round(db_to_linear(db) * 100.0))
