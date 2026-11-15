"""Inline the game-icons SVG paths into the card mock page."""
import json, re, sys
from pathlib import Path

root = Path(sys.argv[1])
template = Path(sys.argv[2])
out = Path(sys.argv[3])
names = {
    "lantern": "lorc/lantern-flame", "seal": "lorc/wax-seal", "fangs": "skoll/fangs",
    "pentacle": "skoll/pentacle", "meat": "lorc/meat", "chain": "willdabeast/chain-mail",
    "sword": "lorc/broadsword", "flame": "carl-olsen/flame", "snow": "lorc/snowflake-1",
    "crown": "lorc/crown", "lock": "lorc/padlock", "lens": "lorc/magnifying-glass",
    "stairs": "delapouite/stairs", "cube": "delapouite/cube", "drop": "lorc/drop",
    "fist": "lorc/mailed-fist",
}
icons = {}
for key, rel in names.items():
    text = (root / f"{rel}.svg").read_text(encoding="utf-8")
    paths = [d for d in re.findall(r' d="([^"]+)"', text) if d.strip() != "M0 0h512v512H0z"]
    icons[key] = paths
import base64
portrait = base64.b64encode((template.parent / "warrior_portrait.jpg").read_bytes()).decode("ascii")
page = template.read_text(encoding="utf-8").replace("/*ICONS*/{}", json.dumps(icons, separators=(",", ":")))
page = page.replace("/*WARRIOR*/", "data:image/jpeg;base64," + portrait)
out.write_text(page, encoding="utf-8")
print(out, len(page))
