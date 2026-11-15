"""Card data for the collection prototype: the real demo catalog joined with the content's names and texts, plus a
proposed game-icons glyph per item (keyword match, the same idea as the spec's icon pass). Writes cards.json."""
import json, re, sys
from pathlib import Path

repo = Path(sys.argv[1])
icons_root = Path(sys.argv[2])
out = Path(sys.argv[3])

catalog = json.loads((repo / "infra/economy/card_catalog.json").read_text(encoding="utf-8"))["cards"]
content = repo / "client-godot/content/demo"

defs = {}
for folder in ("items", "equipment", "characters"):
    for f in (content / folder).glob("*.tres"):
        text = f.read_text(encoding="utf-8")
        m = re.search(r'^id = &"([^"]+)"', text, re.M)
        if not m:
            continue
        def field(name):
            mm = re.search(rf'^{name} = "((?:[^"\\]|\\.)*)"', text, re.M)
            return mm.group(1).replace('\\"', '"') if mm else ""
        kind = re.search(r"^kind = (\d)", text, re.M)
        slot = re.search(r'^slot = &"Equipment\.Slot\.(\w+)"', text, re.M)
        cooldown = re.search(r"^cooldown_battles = (\d+)", text, re.M)
        use_mode = re.search(r"^use_mode = (\d)", text, re.M)
        defs[m.group(1)] = {
            "folder": folder, "name": field("display_name"), "text": field("description"), "role": field("role"),
            "usable": bool(kind and kind.group(1) == "1"), "slot": slot.group(1) if slot else "",
            "cooldown": int(cooldown.group(1)) if cooldown else 1, "consumable": not (use_mode and use_mode.group(1) == "1"),
            "food": "Item.Food" in text or '"Pool.Food"' in text, "corrupted": "Item.Corrupted" in text,
        }

# every icon by its file stem (first author wins, lorc and delapouite first)
stems = {}
for author in ["lorc", "delapouite", "skoll", "carl-olsen"] + sorted(p.name for p in icons_root.iterdir()):
    d = icons_root / author
    if d.is_dir():
        for svg in d.glob("*.svg"):
            stems.setdefault(svg.stem, svg)

KEYWORDS = {
    "lantern": "lantern-flame", "seal": "wax-seal", "fang": "fangs", "fangs": "fangs", "sigil": "pentacle", "rations": "meat",
    "haunch": "meat", "cake": "cake-slice", "feast": "hot-meal", "lens": "magnifying-glass", "loupe": "magnifying-glass",
    "bell": "ringing-bell", "horn": "hunting-horn", "drum": "drum", "coil": "electrical-resistance", "heart": "heart-organ",
    "totem": "totem-head", "thorns": "thorny-vine", "thorn": "thorny-vine", "mail": "chain-mail", "vest": "leather-vest",
    "charm": "gem-pendant", "pendant": "gem-pendant", "band": "ring", "ring": "ring", "halo": "halo", "brand": "branding-iron",
    "mark": "target-arrows", "bounty": "wanted-reward", "oath": "scroll-unfurled", "fleece": "sheep", "pact": "blood",
    "breaker": "hammer-break", "maul": "warhammer", "blade": "broadsword", "dagger": "plain-dagger", "crown": "crown",
    "greaves": "leg-armor", "bracers": "bracer", "hide": "animal-hide", "potion": "potion-ball", "tonic": "potion-ball",
    "bomb": "unlit-bomb", "salve": "medicines", "ether": "magic-potion", "salts": "powder", "water": "holy-water",
    "metronome": "metronome", "fork": "tuning-fork", "loop": "ouroboros", "tome": "book-cover", "hourglass": "hourglass",
    "edge": "sword-wound", "gloves": "gloves", "mirror": "mirror-mirror", "censer": "smoking-orb", "key": "key",
    "lockpick": "lockpick", "rod": "dowsing-rod", "fob": "pocket-watch", "skeleton": "skeleton-key", "ember": "flame",
    "frost": "snowflake-1", "bellows": "bellows", "dynamo": "electric", "eye": "eyeball", "quiver": "quiver",
    "bow": "pocket-bow", "staff": "wizard-staff", "shield": "checked-shield", "helm": "visored-helm", "cap": "pointy-hat",
    "brand": "flaming-claw", "amulet": "gem-pendant", "glove": "gloves", "coin": "two-coins", "purse": "coins",
    "idol": "medal", "flask": "round-bottom-flask", "crystal": "crystal-growth", "core": "fire-ring", "shard": "crystal-shine",
    "skin": "stone-block", "banner": "flag-objective", "whetstone": "stone-sphere", "ledger": "book-cover", "satchel": "knapsack",
    "wing": "angel-wings", "badge": "rank-3", "stew": "hot-meal", "heartstring": "harp", "rites": "tombstone",
    "shatterpoint": "shatter", "toxic": "poison-bottle", "box": "present", "halo": "crowned-heart", "lockpick": "padlock",
    "rod": "lightning-helix",
}
SLOT_ICON = {"Weapon": "broadsword", "Body": "chest-armor", "Head": "visored-helm", "Arms": "gauntlet",
             "Legs": "leg-armor", "Accessory": "ring"}

def pick_icon(name, slot):
    words = [w.lower() for w in re.findall(r"[A-Za-z]+", name)]
    for w in reversed(words):
        stem = KEYWORDS.get(w)
        if stem and stem in stems:
            return stem
    for w in reversed(words):
        if w in stems:
            return w
    if slot:
        return SLOT_ICON.get(slot, "swap-bag")
    return "swap-bag"

def element(d):
    t = (d["name"] + " " + d["text"]).lower()
    if d["corrupted"]:
        return "void"
    if d["food"]:
        return "food"
    if "fire" in t or "burn" in t or "ember" in t:
        return "fire"
    if "ice" in t or "freeze" in t or "frost" in t:
        return "ice"
    return "physical"

POOL_NAMES = {"Pool.Treasure": "Treasure", "Pool.Shop": "Shop", "Pool.Boss": "Boss", "Pool.Void": "Void",
              "Pool.Food": "Food", "Pool.Chest": "Chest"}
cards, used = [], set()
for c in catalog:
    d = defs.get(c["id"])
    if d is None:
        continue
    kind = "character" if c["kind"] == "character" else ("equipment" if d["folder"] == "equipment" else "item")
    pools = [POOL_NAMES.get(p, p) for p in c["pools"]]
    if kind == "character":
        type_line = "Character — " + (d["role"].split(":")[0].split("/")[0].strip() or "Hero")
    elif kind == "equipment":
        type_line = "Armor — " + d["slot"]
    elif d["food"]:
        type_line = "Item — Food"
    elif d["usable"]:
        type_line = "Item — " + ("Consumable" if d["consumable"] else f"Usable · {d['cooldown']} battle{'s' if d['cooldown'] > 1 else ''}")
    else:
        type_line = "Item — Passive" + (" · " + pools[0] if pools else "")
    icon = "" if kind == "character" else pick_icon(d["name"], d["slot"])
    if icon:
        used.add(icon)
    cards.append({"id": c["id"], "kind": kind, "name": d["name"], "text": d["text"], "type": type_line, "rarity": c["rarity"],
                  "set": c["setId"], "core": c["core"], "pools": pools, "el": "physical" if kind == "character" else element(d),
                  "corrupted": d["corrupted"], "icon": icon})

paths = {}
for stem in sorted(used | {"cube", "stairs", "crown", "padlock", "drop", "swap-bag", "flame", "snowflake-1", "crystal-ball", "cut-diamond", "sparkles"}):
    svg = stems.get(stem)
    if svg is None:
        continue
    text = svg.read_text(encoding="utf-8")
    paths[stem] = [d for d in re.findall(r' d="([^"]+)"', text) if d.strip() != "M0 0h512v512H0z"]
authors = sorted({stems[s].parent.name for s in paths})
out.write_text(json.dumps({"cards": cards, "icons": paths, "authors": authors}, separators=(",", ":")), encoding="utf-8")
missing = [c["name"] for c in cards if c["icon"] == "swap-bag"]
print(len(cards), "cards,", len(paths), "icons; generic icon for:", missing)
