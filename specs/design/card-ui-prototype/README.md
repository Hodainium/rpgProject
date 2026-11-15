# Card UI prototype (slice 5b `card-ui`, 2026-11-15)

Browser prototypes made while speccing `specs/card-ui.md`. They are the **approved layout and flow reference** for the Godot
screens (user, 2026-11-15: "I really like the UI you provided, let's go with it"). The real screens are built in Godot; nothing
here ships.

| File | What it is |
|---|---|
| `card-collection.html` | The clickable prototype: Collection (8 a page, filters, paging), card detail with Dust / Create and the run-lock pop-up, the Shop, Open packs (burst, fan-out, rarity tells, flips, labels). Open it in a browser. Published: https://claude.ai/artifact/8puWhAr32ANzuqYSBgWfDZ |
| `collection.template.html` + `build_data.py` + `cards.json` | Its source: `build_data.py <repo> <game-icons 1x1 folder> cards.json` joins `infra/economy/card_catalog.json` with the content's names and texts and proposes a game-icons glyph per item (the keyword table is the seed of the spec's icon pass); the page is the template with `/*DATA*/`, `/*WARRIOR*/`, `/*BULWARK*/` filled (see the inline build in the session: base64 JPEGs). |
| `card-looks.html` + `card_looks.template.html` + `build_mock.py` | The look comparison: Look A "Tavern" (the favourite) and Look B "Grimoire" (both to be built in the engine), Look C (dropped). Published: https://claude.ai/artifact/2SkXB9fTueuDnjqeHp2jcu |
| `warrior.jpg`, `bulwark.jpg`, `warrior_portrait.jpg` | Portrait crops used by the pages. |
| `portrait/portrait.gd` | The throwaway console command that shot the portraits (pass its folder with `--commands` to `game/tools/dev_run.tscn --window --local --manual --shots <dir>`): the unit alone, facing the camera, a dark backdrop and matte floor at the cube's feet (y = -0.405: units are centred on 0 and the room floor sits at -0.6), the room's meshes and the HUD hidden, a warm key spot, element-coloured rim and glow lights, rising motes, its own Environment. The seed of the spec's `build_card_portraits.tscn` and `portrait_studio.tscn`. `shot.txt` is the script for all 11 classes with their rim colours. |
| `portrait/warrior.png`, `bulwark.png` | The two approved shots (smooth helms, PR #55). |

Lessons from the portrait shots: never turn a cube away from the camera (it breaks the face); hide the room's walls (the front wall
covered the lower half of the cube); a glossy floor throws hot reflections, keep it matte. Card art boxes must be `border-box`
(a 4px border on a percentage width pushed every art window 4px right).

Icons: game-icons.net (Lorc, Delapouite, Skoll, Carl Olsen, Willdabeast and others), CC BY 3.0; the source zip stays at
`H:\assets\game-icons` outside the repo.
