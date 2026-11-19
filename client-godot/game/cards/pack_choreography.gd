## Spec card-ui 2.4 / 3.2: every number of the pack choreography (seconds, positions, stagger) and the effects and sounds of its
## beats. Each beat reuses an effect of the shared library with the card's rarity colour and a strength by tier (0 Common ..
## 4 Mythic), never one effect per rarity (memory "reuse VFX, parameterize"). `CardStyle.choreography`; none = these defaults.
## Presentation only.
class_name PackChoreography
extends Resource

@export_group("Beats")
## 1. The pack flies from the column into the socket and settles.
@export var socket_seconds: float = 0.35
## 2. It shakes harder and bursts.
@export var burst_seconds: float = 0.6
## 3. The five cards fly out face down to their places, each `fan_stagger` after the last.
@export var fan_seconds: float = 0.5
@export var fan_stagger: float = 0.06
## 5. One flip; Reveal all flips the rest `reveal_all_gap` apart with their flashes at `reveal_all_flash` of their strength.
@export var flip_seconds: float = 0.45
@export var reveal_all_gap: float = 0.12
@export var reveal_all_flash: float = 0.5
## How far a flipping card lifts toward the camera (world units at a card height of 1).
@export var flip_lift: float = 0.35

## The pack on the stage is the 3D metallic foil pouch (CardPack3D; the user's pick, 2026-11-18); off = the flat pack.
@export var pack_3d: bool = true
## How much the 3D pack sways while it waits in the socket (radians), so its foil catches the light.
@export var pack_sway: float = 0.22

@export_group("Layout")
## Hearthstone's five places (three above, two below), as fractions of the stage (x, y of the card's centre).
## Room is left under each card for its two label lines (the bottom row's labels stay on the stage).
@export var spots: Array[Vector2] = [Vector2(0.24, 0.27), Vector2(0.50, 0.23), Vector2(0.76, 0.27), Vector2(0.37, 0.69),
	Vector2(0.63, 0.69)]
## A card's height as a share of the stage's height.
@export var card_height: float = 0.36
## The pack in the socket, as a share of the stage's height.
@export var pack_height: float = 0.42

@export_group("Effects")
## Beat 2: the burst (its colour is the pack's own, CardPackLook.burst_color).
@export var burst_fx: StringName = &"fx.pack_burst"
## Beat 4: the face-down card's rarity tell (none for Common); `tell_intensity` by tier.
@export var tell_fx: StringName = &"fx.card_glow"
@export var tell_intensity: Array[float] = [0.0, 0.9, 1.2, 1.6, 2.0]
@export var tell_pulse: Array[float] = [0.0, 1.0, 1.2, 1.5, 0.8]
## Beat 5: the flip flash in the rarity colour, `flash_intensity` by tier; from `rays_from_tier` the rays, from `shake_from_tier`
## a shake (`shake_strength` by tier), at `screen_flash_tier` a screen flash.
@export var flash_fx: StringName = &"fx.card_flip_flash"
@export var flash_intensity: Array[float] = [0.5, 0.9, 1.3, 1.8, 2.4]
@export var rays_fx: StringName = &"fx.reveal_halo"   # the user's pick, 2026-11-18
@export var rays_from_tier: int = 3
## The Mythic's own big reveal (empty = `rays_fx`, `none` = no big reveal effect). game/dev/pack_reveal_demo.tscn compares
## the reveal effects.
@export var mythic_fx: StringName = &"fx.reveal_rays"   # the user's pick, 2026-11-18
@export var shake_fx: StringName = &"fx.screen_shake"
@export var shake_from_tier: int = 3
@export var shake_strength: Array[float] = [0.0, 0.0, 0.0, 0.5, 0.8]
@export var screen_flash_fx: StringName = &"fx.screen_flash"
@export var screen_flash_tier: int = 4

@export_group("Sounds")
## Bank entries (presentation/audio/sfx/bank/<id>.tres) on the Ui bus; empty = silent. Spec 7 q3: picked from the existing bank.
@export var socket_sound: String = "ui.confirm"
@export var burst_sound: String = "break"
## The flip's sound by tier (Common .. Mythic). The user's picks (2026-11-18): Simple Whoosh, Simple Heal, Glistening Shimmers,
## Healing Gusts, Holy6, imported whole (category `pack`, up to 3 s) so their tails ring out instead of stopping at the battle cap.
@export var flip_sounds: Array[String] = ["pack.flip.common", "pack.flip.rare", "pack.flip.epic", "pack.flip.legendary",
	"pack.flip.mythic"]
## Seconds a sound still ringing fades over when the stage leaves (the screen closes): never a hard stop.
@export var sound_fade_seconds: float = 0.5


## The big reveal effect of `tier` (none below `rays_from_tier`).
func big_reveal_fx(tier: int) -> StringName:
	if tier < rays_from_tier:
		return &""
	if tier >= 4 and mythic_fx != &"":
		return &"" if mythic_fx == &"none" else mythic_fx
	return rays_fx


func tier_value(values: Array, tier: int) -> Variant:
	if values.is_empty():
		return null
	return values[clampi(tier, 0, values.size() - 1)]


## The flip's sound for `tier`, or "".
func flip_sound(tier: int) -> String:
	var sound: Variant = tier_value(flip_sounds, tier)
	return str(sound) if sound != null else ""
