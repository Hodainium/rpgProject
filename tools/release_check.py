"""Release check (spec playable-demo 3.12 D35): what can be checked from outside an exported build.

The release template takes no --script and no scene, so nothing runs inside a player build; this drives it from the
OS. Started by tools/release_check.sh (watched). Steps: start the .exe in a window with its own log file, wait for
the window and the title screen, shot 1, a backtick keypress by scan code (the console listens on the physical key),
shot 2, close the game, then check:
  - the log has no SCRIPT ERROR / ERROR lines;
  - the console opened or not, as expected (the area it covers changed between the shots). The dev build is the
    control: its console must open, which proves the keypress reached the game.
Writes <shots>/<name>-title.png and <name>-backtick.png and prints a JSON summary. Exit 0 ok, 1 a check failed,
2 bad arguments or no window.
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import json
import os
import subprocess
import sys
import tempfile
import time

from PIL import ImageChops, ImageGrab

user32 = ctypes.windll.user32
ctypes.windll.shcore.SetProcessDpiAwareness(2)  # window rects in real pixels, like ImageGrab

VK_MENU, VK_OEM_3, SCAN_BACKTICK = 0x12, 0xC0, 0x29
KEYEVENTF_KEYUP, WM_CLOSE = 0x0002, 0x0010
# The console is a top-wide panel 360 px high in the 1080 px viewport: the top third of the client area.
CONSOLE_SHARE = 360 / 1080
# A pixel changed when any channel moved by more than this; the console opened when this share of its area changed.
PIXEL_DELTA, OPENED_SHARE = 24, 0.25
# The error lines Godot prints that are not ours to fix: none yet. Add a pattern only with a reason.
IGNORED_ERRORS: list[str] = []


def find_window(pid: int, timeout: float) -> int:
    found: list[int] = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def visit(hwnd, _):
        owner = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd):
            found.append(hwnd)
        return True

    end = time.time() + timeout
    while time.time() < end:
        found.clear()
        user32.EnumWindows(visit, 0)
        if found:
            return found[0]
        time.sleep(0.25)
    return 0


def focus(hwnd: int) -> None:
    # Windows only lets the foreground process hand focus away; a synthetic Alt press lifts that lock.
    user32.keybd_event(VK_MENU, 0, 0, 0)
    user32.SetForegroundWindow(hwnd)
    user32.keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, 0)
    time.sleep(0.5)


def client_box(hwnd: int) -> tuple[int, int, int, int]:
    rect = wt.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rect))
    origin = wt.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(origin))
    return origin.x, origin.y, origin.x + rect.right, origin.y + rect.bottom


def shot(hwnd: int, path: str):
    focus(hwnd)
    image = ImageGrab.grab(bbox=client_box(hwnd), all_screens=True)
    image.save(path)
    return image


def changed_share(before, after) -> float:
    height = int(before.height * CONSOLE_SHARE)
    region = (0, 0, before.width, height)
    diff = ImageChops.difference(before.crop(region).convert("RGB"), after.crop(region).convert("RGB"))
    moved = sum(1 for pixel in diff.getdata() if max(pixel) > PIXEL_DELTA)
    return moved / max(1, before.width * height)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--shots", required=True)
    parser.add_argument("--expect-console", choices=["yes", "no"], required=True)
    parser.add_argument("--settle", type=float, default=8.0, help="seconds from the window to the title screen")
    args = parser.parse_args()
    if not os.path.isfile(args.exe):
        print(f"release_check: no build at {args.exe} (tools/export.sh first)")
        return 2
    os.makedirs(args.shots, exist_ok=True)
    log = os.path.join(tempfile.mkdtemp(prefix="release_check_"), "godot.log")
    game = subprocess.Popen([args.exe, "--log-file", log, "--resolution", "1600x900", "--position", "80,80"])
    result = {"name": args.name, "exe": args.exe, "log": log, "checks": {}, "shots": []}
    try:
        hwnd = find_window(game.pid, 60)
        if not hwnd:
            print("release_check: the game opened no window within 60 s")
            return 2
        print(f"release_check: window up, waiting {args.settle:.0f} s for the title screen", flush=True)
        time.sleep(args.settle)
        title_path = os.path.join(args.shots, f"{args.name}-title.png")
        title = shot(hwnd, title_path)
        result["shots"].append(title_path)
        focus(hwnd)
        user32.keybd_event(VK_OEM_3, SCAN_BACKTICK, 0, 0)
        time.sleep(0.05)
        user32.keybd_event(VK_OEM_3, SCAN_BACKTICK, KEYEVENTF_KEYUP, 0)
        time.sleep(1.5)
        backtick_path = os.path.join(args.shots, f"{args.name}-backtick.png")
        after = shot(hwnd, backtick_path)
        result["shots"].append(backtick_path)
        share = changed_share(title, after)
        opened = share >= OPENED_SHARE
        result["consoleAreaChanged"] = round(share, 3)
        result["checks"]["console"] = opened == (args.expect_console == "yes")
        user32.PostMessageW(hwnd, WM_CLOSE, 0, 0)
        try:
            game.wait(15)
        except subprocess.TimeoutExpired:
            game.kill()
            result["checks"]["closes"] = False
    finally:
        if game.poll() is None:
            game.kill()
    text = open(log, encoding="utf-8", errors="replace").read() if os.path.isfile(log) else ""
    errors = [line for line in text.splitlines() if ("SCRIPT ERROR" in line or line.startswith("ERROR:"))
              and not any(pattern in line for pattern in IGNORED_ERRORS)]
    result["checks"]["log"] = text != ""
    result["checks"]["noErrors"] = not errors
    result["errors"] = errors[:20]
    print(json.dumps(result, indent=2))
    return 0 if all(result["checks"].values()) else 1


if __name__ == "__main__":
    sys.exit(main())
