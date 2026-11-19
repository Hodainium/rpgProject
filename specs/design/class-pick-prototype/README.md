# Class pick prototype (slice 5b4 `class-pick`, 2026-11-18)

The browser prototype made while discussing `specs/class-pick.md`: the **approved layout and flow reference** for the Godot
screen (user, 2026-11-18). Nothing here ships. Published: https://claude.ai/artifact/SVtwmh3LZWw89eSRQ95EFk

| File | What it is |
|---|---|
| `class-pick.html` | The clickable page: the carousel (A Turntable, picked; B Frame and neighbours, not picked), the class card under it, the party as portrait slots (picked) or rows, recommended parties, Lock in, an ownership switch. Open it in a browser. |
| `class_pick.template.html` | Its source; `/*DATA*/` is filled with the class data. |
| `extract_classes.py` | Reads `client-godot/content/demo/characters/*.tres` (name, role, description, display colour, core set, abilities with their `Ability.Type.*`, level skills, starting stats). Run from `client-godot/`. |
| `embed_portraits.py` | Adds the card portraits (resized JPEGs as data URIs) and drops the shared abilities (Ult Charge, Break, Block, SP Gain). |

The browser can only slide flat portraits; the game shows the live cubes (spec 2.2). The win-rate and play-rate tabs on the page
show sample numbers only.
