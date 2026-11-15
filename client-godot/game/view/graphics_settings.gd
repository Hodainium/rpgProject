## Playtest-fixes B25: the player's graphics settings that live on the window, not on a run: anti-aliasing and fullscreen.
## Saved in user://game_main.cfg [settings] under `anti_aliasing` and `fullscreen`; GameMain applies them at boot, the Graphics
## screen and the console's `graphics` change them at once. Presentation only: nothing here reaches a run, a battle, a hash or an upload.
class_name GraphicsSettings
extends RefCounted

const SETTINGS_SECTION: String = "settings"
const AA_KEY: String = "anti_aliasing"
## The modes, in the order the Graphics screen lists them. MSAA smooths every 3D edge (the cube outlines, thin trims that
## shimmered as a unit bobs: the Lich's gold edges, 2026-11-15); FXAA is a cheap screen filter that also softens text and
## lines; off is the old look.
const AA_MODES: PackedStringArray = ["off", "fxaa", "msaa_2x", "msaa_4x", "msaa_8x"]
const AA_LABELS: PackedStringArray = ["Off", "FXAA (fast)", "MSAA 2×", "MSAA 4×", "MSAA 8×"]
const AA_DEFAULT: String = "msaa_4x"
const FULLSCREEN_KEY: String = "fullscreen"


## The saved mode (an unknown or missing value is the default).
static func saved_aa() -> String:
	var mode := str(GameMain.load_setting(SETTINGS_SECTION, AA_KEY, AA_DEFAULT))
	return mode if AA_MODES.has(mode) else AA_DEFAULT


## The 3D MSAA sample count of a mode (off for `off`, `fxaa` and an unknown mode).
static func msaa_of(mode: String) -> Viewport.MSAA:
	match mode:
		"msaa_2x":
			return Viewport.MSAA_2X
		"msaa_4x":
			return Viewport.MSAA_4X
		"msaa_8x":
			return Viewport.MSAA_8X
	return Viewport.MSAA_DISABLED


## Applies a mode to a viewport (the window's root at boot). Returns "" or a problem for an unknown mode. A change of the
## sample count makes the stencil prepare draw its shader copies again (spec vfx-stencil 3.4: a pipeline is compiled per sample
## count, so the copies prepared for the old one do not cover the new one; the next prepare, at run or battle start, redraws them).
static func apply_aa(viewport: Viewport, mode: String) -> String:
	if not AA_MODES.has(mode):
		return "unknown anti-aliasing mode '%s' (%s)" % [mode, " | ".join(AA_MODES)]
	if viewport == null:
		return ""
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if mode == "fxaa" else Viewport.SCREEN_SPACE_AA_DISABLED
	var msaa := msaa_of(mode)
	if viewport.msaa_3d != msaa:
		viewport.msaa_3d = msaa
		FxStencilShaders.forget_prepared()
	return ""


## Applies and saves a mode (the Graphics screen and the console). Returns "" or a problem; nothing is saved on a problem.
static func set_aa(viewport: Viewport, mode: String) -> String:
	var problem := apply_aa(viewport, mode)
	if problem == "":
		GameMain.save_setting(SETTINGS_SECTION, AA_KEY, mode)
	return problem


## The mode a viewport is in now (for the console and tests); "custom" when it matches none of the modes.
static func current_aa(viewport: Viewport) -> String:
	var fxaa := viewport.screen_space_aa == Viewport.SCREEN_SPACE_AA_FXAA
	match viewport.msaa_3d:
		Viewport.MSAA_DISABLED:
			return "fxaa" if fxaa else "off"
		Viewport.MSAA_2X:
			return "custom" if fxaa else "msaa_2x"
		Viewport.MSAA_4X:
			return "custom" if fxaa else "msaa_4x"
		Viewport.MSAA_8X:
			return "custom" if fxaa else "msaa_8x"
	return "custom"


## The saved fullscreen choice (off unless the player turned it on).
static func saved_fullscreen() -> bool:
	return bool(GameMain.load_setting(SETTINGS_SECTION, FULLSCREEN_KEY, false))


## Whether the window is fullscreen now (false headless).
static func is_fullscreen() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	var mode := DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


## Puts the window into fullscreen or back into a window; nothing headless.
static func apply_fullscreen(on: bool) -> void:
	if DisplayServer.get_name() == "headless" or on == is_fullscreen():
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)


## Applies and saves the choice (the Graphics screen and the console).
static func set_fullscreen(on: bool) -> void:
	apply_fullscreen(on)
	GameMain.save_setting(SETTINGS_SECTION, FULLSCREEN_KEY, on)


## What boot does: the saved anti-aliasing always; fullscreen only when it was saved on (so a window started fullscreen from the
## command line, `--fullscreen` for the playtest launches, is never turned back into a window) and only for the game itself
## (`game_window`: GameMain is the main scene), so dev windows (`dev_run --window`, previews, release checks) stay windowed.
static func apply_saved(viewport: Viewport, game_window: bool) -> void:
	apply_aa(viewport, saved_aa())
	if game_window and saved_fullscreen():
		apply_fullscreen(true)
