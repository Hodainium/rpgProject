# Spec: card-ui (slice 5b)

Status: **spec written 2026-11-15, awaiting review.** Builds on `specs/card-collection.md` (slice 5: the account, the endpoints,
`ServerLink`'s card calls, `CardCatalog`), `specs/ui-framework.md` (screens, layers, `UIList`, Back), `specs/ff7-ui.md` (the window
theme), `specs/vfx-framework.md` (`FxStage`, `FxDefinition`, the shader library), `specs/cube-style.md` (the unit looks a character
card shows) and the roadmap entry "5b. `card-ui`" (its look-and-feel list is the requirement). References: `H:\assets\references\hearthstone\`
(collection, crafting, pack opening) and `H:\assets\references\mtg\` (frames), for layout and feel only; every asset stays our own.

Card look proposals (HTML mock-up on real demo cards): https://claude.ai/artifact/2SkXB9fTueuDnjqeHp2jcu.
**Approved screen prototype** (user, 2026-11-15: "I really like the UI you provided, let's go with it"): the clickable Collection,
card detail, Shop and Open packs at https://claude.ai/artifact/8puWhAr32ANzuqYSBgWfDZ; the Godot screens follow its layout and
flow. Its files, data builder and the portrait command are kept in `specs/design/card-ui-prototype/` (README there).
The engine built **both Look A, "Tavern"** (Hearthstone-leaning) **and Look B, "Grimoire"** (Magic-leaning) as face scenes, and
the user picked **Look B** in the engine on 2026-11-18 (first gate, section 7 question 1; Look A was then deleted). The approved
face is described in 3.3 "The card face (gate 1)".

## 1. Purpose & enterprise mapping

**Purpose.** Give the card system of slice 5 its screens. Today the account (gems, dust, owned cards, packs, pity) is reachable only
through console commands. This slice makes it a player feature, in Hearthstone's shape:

1. **A card face** built from data: a frame per rarity, an art window, name ribbon, rarity gem, text plaque, a type line in Magic's
   style ("Character — Damage dealer", "Item — Passive · Treasure", "Armor — Weapon"), a core tab. No stat corners and no corner
   badge (user, 2026-11-15). **Art is never drawn or generated (user, 2026-11-15):** an item's art is a game-icons SVG from
   `H:\assets\game-icons` tinted by element; a character's art is a **prerendered portrait**: a still of the character's real
   in-game cube look, shot in a portrait studio scene (3.5). Zero art time per new card: a new item gets a face from its tags and
   one icon pick, a new character one portrait run.
2. **Collection** (Hearthstone's collection viewer): an 8-card page (4 x 2) on a 3D stage, page turning, filters (set, kind, rarity,
   room pool, owned / missing, search), owned / missing / locked / NEW states, the dust and gem totals.
3. **Card detail with craft and dust** (Hearthstone's crafting view): the card large, its facts, Dust (+value) and Create (-cost),
   and the run-lock pop-up that offers to cancel the active run (409 1403) or says to wait for the verdict (Verifying).
4. **Shop** (user, 2026-11-15: "just like in Hearthstone there is a separate buy menu"): packs are **bought** with gems in a Shop
   screen (Buy 1, Buy 5, the odds), and wait **unopened** in the account. The server half (pack inventory, the buy endpoint, open
   spending an owned pack) is its own slice, **5b0 `pack-shop`** (`specs/pack-shop.md`), built and merged before this one.
5. **Pack opening**: the owned packs with their counts and pity counters, the pack bursts, five cards fan out face down with a rarity
   glow, flip one at a time with a rarity flash, extra drama on Epic, Legendary, Mythic and pity cards, a NEW badge or a duplicate's
   dust.
6. **Class pick follows the account** (server mode): characters the account does not own are shown locked and cannot be picked,
   so the run start's 400 1409 is never reached through the UI.
7. **Main menu entry points**: three buttons, **Collection**, **Shop** and **Open packs** (with the unopened count). The menu is
   otherwise unchanged.

Local mode keeps working: the collection is a read-only catalog browser (the core set and the local test pool shown as owned),
packs, dust and craft are disabled with a line saying they need a server.

Everything new is **presentation and client flow**: no rule, hash, snapshot, upload or verifier input changes, no golden moves, and
no server change (the server half of the Shop is 5b0 `pack-shop`).

**Components used** (from `README.md`):

| Component | Role in this slice | Enterprise analogue |
|---|---|---|
| Godot client (UI framework, `FxStage`, FX data) | The screens, the card faces, the pack choreography | Front-end over an entitlements service |
| ASP.NET Core API | Unchanged: the slice 5 endpoints and 5b0's buy, open from owned packs, owned packs in the collection | Account / entitlements service |
| PostgreSQL | Unchanged; `account_requests` makes a retried buy, open, dust or craft safe | Idempotent request log |
| Redis | Unchanged (the catalog caches) | Cache-aside reference data |

**Not used here:** RabbitMQ, Redpanda, the verifier, new endpoints, contracts, tables or metrics (all in 5b0 or slice 5).

**Acceptance scenarios covered (client half):** 1 (the client keeps one key per action until it gets an answer, so a double click
or a retry is one purchase) and 2 (a dropped connection blocks the game behind the "Reconnecting…" pop-up while it re-sends the action with
the same key until the server answers, so it buys once and shows the same five cards once; after a crash nothing is re-sent and the
screens show the server's state, 2.5). The server's half of 1, 2 and 3 is slice 5's and 5b0's.

## 2. Sequence flow

### 2.1 Opening the screens

```
Main menu ── Collection button (UIPushButton, same_layer) ──▶ UIManager.push(Menu, collection.tscn)
  CollectionScreen.on_activated:
    local mode  → CardFaces from local content; owned = core + GameMain.local_card_pool; no wallet; actions disabled
    server mode → ServerLink.get_card_catalog()      (once per session, kept with its catalogHash; refetched when a later
                                                      response names a card the cached catalog lacks)
                  ServerLink.get_collection()        (every activation and after every action; the connecting pop-up shows
                                                      after 0.3 s as for every server wait)
  build the CollectionModel (pure: catalog x content x collection x seen set) → filter, sort, page → 8 CardViews on the stage
```
Catalog drift: a server card id with no local definition shows an "Unknown card" face (name = id) and logs one warning; a local card
the server does not list is not shown in server mode. The NEW set (`cards_seen.json`, 3.4) is client-local and per player.

### 2.2 Card detail, dust and craft

```
click a card → CardDetail (Modal layer): the card large on the stage, facts window, crafting bar
  Dust  (owned, not core):      UIManager.confirm("Dust Frost Lantern for 100 dust?")
                                → CardAccount.run(DUST, card) ─▶ POST /cards/{id}/dust {requestKey}
        200        → dust total animates up, the card ghosts (missing), the bar's +/- swap, collection refetched
        409 1403   → runStatus Active:    confirm("Frost Lantern is in your active run (floor 4). Cancel that run to dust it?",
                                                  "Cancel run", "Keep run")
                                          yes → ServerLink.abandon_run(runId) → release_cancelled(runId) → the same dust
                                                re-sent with the SAME key (a refusal stores nothing under the key, slice 5 2.3)
                     runStatus Verifying: message "Your won run is being verified. You can dust this card after the verdict."
        409 1406 / 400 1404 → the collection was stale: refetch, show the server's line
  Create (missing, collectible): no pop-up below Legendary; Legendary and Mythic confirm with the cost
                                → CardAccount.run(CRAFT, card) ─▶ POST /cards/{id}/craft {requestKey}
        200        → the card un-ghosts with the rarity flash (2.4), NEW badge, dust total animates down
        409 1402   → refused sound + "Not enough dust (need 400, have 120)"; the button was already disabled when the
                     collection said so, so this only happens on a stale total
        409 1405   → stale: refetch
```
Core cards show "Core: every account owns it" in place of the bar. A card locked by the run shows the padlock and its Dust button
still works (the pop-up is the way out, as slice 5 decided).

### 2.3a Buying packs (Shop)

```
Main menu ── Shop ──▶ ShopScreen: ServerLink.get_packs() + get_collection() → one offer per pack type (art, name, card count,
                      the Rare guarantee line, Buy 1 · price, Buy 5 · 5 x price, an Odds window); the owned count beside it
  Buy n:  CardAccount.run(BUY, {pack, count: n}) ─▶ ServerLink.buy_pack(pack, n, key) ─▶ POST /api/v1/packs/{packId}/buy (5b0 2.1)
      200 PackBuyResponse → gems total animates down; "Bought 5 packs. You have 7 waiting in Open packs."; the menu's Open packs
                            button shows the count
      409 1402 → refused sound, "Not enough gems (need 500, have 340)" (the Buy buttons were already disabled when the collection said so)
      404 1408 / 400 1401 → the server's line; packs refetched
      no answer / 5xx / 429 → "Reconnecting…" in the connecting pop-up (2.5); the Shop shows the answer once it lands
```

### 2.3 Pack opening

```
Main menu ── Open packs ──▶ PackScreen
  ServerLink.refund_packs() first (spec pack-shop 2.5: the one place refunds of retired packs are paid): each refunded entry
                                               → a notice "Your 3 Descent Packs were retired: +300 gems" (gems total animates up)
  ServerLink.get_packs() + get_collection()  → left column: each pack type the player owns, with its count badge ("x 7");
                                               pity line per type ("Epic in 3 · Legendary in 12 · Mythic in 18 packs": PityPacks - missed),
                                               an Odds button (OddsPer10000 as percentages; slice 5 3.4b); no packs → "Buy packs in the Shop"
  click a pack / drag it to the socket / press Enter on it:
    CardAccount.run(OPEN, pack) ─▶ POST /packs/{id}/open {requestKey}   (no pop-up: the pack is already paid for)
  (the server spends one owned pack: 5b0 2.2)
      waiting:  the pack sits in the socket and pulses (the connecting pop-up still covers waits over 0.3 s)
      200 PackOpenResponse → PackReveal model (3.3) built from Cards[] → the choreography (2.4); the count badge drops by one
      409 1411  → stale count: "You have no pack of this kind left"; collection refetched
      404 1408  → only when the pack has nothing left to draw (a catalog change retired every card it could give; an owned pack
                  of a retired pack type still opens): "This pack cannot be opened right now"; the pack stays owned
      no answer / 5xx / 429 → "Reconnecting…" in the connecting pop-up (2.5) until the server answers with the same key; the reveal then
                              plays as usual
```

### 2.4 The pack choreography (Hearthstone's beats, our effects)

All timings are `PackChoreography` resource values (3.2), shown here at their defaults; every beat is an `FxDefinition` with a
`color` and a `tier` parameter (tier 0 Common .. 4 Mythic), never one effect per rarity.

| Beat | What the player sees | Effect data |
|---|---|---|
| 1. Socket (0.35 s) | The pack flies from the column into the centre socket and settles with a shake | `card.pack_settle` (`FxTweenLayer` + `FxShakeLayer`) |
| 2. Burst (0.6 s) | The pack shakes harder, splits, a radial burst and particles; the burst's colour is the pack's own (not a rarity tell) | `card.pack_burst` (`radial_burst`, particles, light) |
| 3. Fan (0.5 s) | Five cards fly out face down to Hearthstone's five positions (three above, two below), staggered 0.06 s | tweens on `CardView3D` |
| 4. Tell (idle) | Each face-down card glows its rarity: none for Common, blue Rare, purple Epic, orange Legendary with a low hum, rose Mythic with slow rays; a pity card adds a gold rim | `card.rarity_tell` (`glow_aura`, `rays` from tier 3) |
| 5. Flip (0.45 s each) | Click a card (or Space for the next, or Reveal all): it lifts, flips, and flashes its rarity colour; Epic adds sparks, Legendary rays and a short shake, Mythic a screen flash, rays and a camera push | `card.flip_flash` (`vignette_flash`, `rays`, `FxShakeLayer` by tier) |
| 6. Labels | Under the flipped card: its rarity word in its colour ("Legendary!"), NEW if not owned before, "+100 dust" with the dust vial for a duplicate, "Guaranteed" ribbon on a `Pity` card | 2D overlay on the stage (`FxStage.overlay`) |
| 7. Done | After the fifth flip a Done button appears in the centre; Done (or Back) returns the cards to the stage edge and refreshes the collection and totals | |

Skipping: Reveal all flips the remaining cards 0.12 s apart with their flashes at half length; Back during the reveal also reveals
all first (the cards are already the player's: leaving never loses them). Visual-effects quality `off` (Settings) plays the flips
without effects; the labels always show. Sounds come from the existing bank (section 7 question 3).

### 2.5 Pending account actions (client half of acceptance scenarios 1 and 2)

**Hearthstone's model (user, 2026-11-16): reconnect, never resume.** An unanswered account action blocks the game until the
server answers; nothing is written to disk.

```
CardAccount.run(kind, target):
  1. if an action is in flight → refuse a new one (buttons are disabled while one is in flight)
  2. key = ServerLink.new_request_key(), kept in memory only
  3. send; on a retryable failure (no answer, 5xx, 429): emit reconnecting → the screen's wait text turns "Reconnecting…" in
     the connecting pop-up (it dims and blocks clicks; the screen swallows Back) and the action is re-sent with the SAME key,
     ServerLink's backoff capped at `reconnect_max_delay` (default 10 s), until the server answers; a commit whose answer was lost comes back as the stored response (`replayed`), so a pack shows its five
     cards once, a dust or craft its result once
  4. on any answer (success or a 4xx refusal) emit reconnected, forget the key and return the answer
CardAccount.give_up() (console `cardui giveup`; the pop-up's **Go offline** gives up too, see below):
  stop retrying, forget the key, the caller gets {given_up: true} at once; the screen refetches and says
  "We couldn't confirm your purchase. Your gems and packs show what the server has." The account stays busy (no new action)
  until the try already out comes back, whatever it says; then `busy_changed` fires and the screen refetches again, since
  that try may have landed. The button shows only while the account's own wait is the pop-up's; it takes the focus, as do Use it here and a notice's OK
(the theme's focus is a white outline since 2026-11-18, the user's pick; it was yellow).
  Retry-After waits are capped at `reconnect_max_delay` too.
```
**Go offline (user, 2026-11-18 Shop playtest; replaces "Stop waiting"):** a button **beneath** the pop-up's blue window, shown as
soon as the account reconnects (`give_up_after`, now 0 s), and while the main menu's Go online signs in. It gives the action up
(`CardAccount.give_up()`), plays in local mode for this session (`GameMain.go_offline()`: the Settings keep the url) and returns to
the main menu (`UIManager.close_opened` on the Menu and Modal layers). The main menu then shows **Go online** (only in local mode
with a url in the Settings): `GameMain.go_online()` links the Settings' server and signs in again (a fresh token and session) behind
the same pop-up ("Connecting to the server…" with Go offline under it), retrying with backoff (`go_online_retry_seconds`, 1 s doubling
to 10 s) until it answers; a sign-in the server itself refuses goes back to local mode with its line. Console `server go-offline`,
`server go-online`.

**Online only (user, 2026-11-18):** the main menu's Shop and Open packs need the server. Pressed while not online (local mode, or
linked but never signed in), the theme's dialog says "You must be online to access the Shop." / "You must be online to open packs."
with **Go online** (the same `GameMain.go_online()`; the screen opens once online) and **Back** (`UIPushButton.needs_online` /
`offline_text`). A buy that goes through also says so in a dialog with one OK button, "Purchased 1 pack!" (`UIManager.notify`).

After a crash, a quit or giving up, nothing is re-sent: every card screen fetches the collection on activation, so the player sees
whether the buy, dust or craft happened, and a new press is a new action the player chose with the fresh totals. A pack opened
that way is already in the collection without its reveal (Hearthstone's behaviour; a "last opening" read of `pack_openings` is
out of this slice). The rare case it leaves open: a request the server receives only after the crash and a second buy pressed
after the restart are two purchases, each of them paid and shown.

A 1403 refusal keeps the key for the retry after the cancel, since the server stored nothing under it. One action at a time per
player is the server's rule too (the account advisory lock), so a single slot is enough. The account and its key belong to one
`ServerLink`: connecting to another server or player makes a new one.

**The account session (spec `account-session`, slice 5b1, built 2026-11-18).** Every account action also carries the player's
account session and, for a decision, the account version the screen showed; the server refuses an older session (409 1412) or a moved
version (409 1413) and writes nothing. On the screens: no ownership shows without a session; after a 1412 "Your account was opened
somewhere else." with **Use it here** (a new session) and **Go offline**, a centred pop-up in a blue window over whatever screen is up
(the connecting pop-up's second dialog, user 2026-11-18: the message line bottom left is only for status, never for this); **Go online** when no session could start for lack of an answer; after a 1413
"Your account changed. Here is what you have now." and a refetch; giving up a reconnect starts a new session. The Shop does all of
this today; Collection, card detail, Open packs follow it as they are built (the 1412 pop-up already covers the main menu's New run).

### 2.6 Class pick (server mode)

```
New run → title menu's class pick: ServerLink.get_collection() (cached from the menu if fresh)
  pickable = starter (core) characters + owned character cards
  every other character: its class card greyed, a padlock, hint "Find Pyromancer in a pack or craft it", Pick disabled
local mode: unchanged (every selectable character)
```

## 3. Data contracts

### 3.1 C# records, queues, topics, Redis

**N/A: no new or changed record in this slice.** The screens consume slice 5's `CatalogResponse`, `CollectionResponse`,
`PackListResponse`, `PackOpenResponse`, `DustResponse`, `CraftResponse` and 5b0's `PackBuyRequest` / `PackBuyResponse`,
`OwnedPackDto` (in `CollectionResponse.OwnedPacks`) and `PackOpenResponse.PacksLeft`, with the 14xx problems (1411 from 5b0). No
queue, topic or Redis key.

### 3.2 Godot resources (presentation, outside the ruleset roots)

All card presentation lives under `presentation/demo/cards/` and is loaded through one registry, like `StyleRegistry`: never read by
`combat/`, the run, the verifier or the ruleset version (checked by a test, as `test_fx` does for effects).

```gdscript
## presentation/demo/cards/card_style.tres: how every card looks. One per content set; the demo has one.
class_name CardStyle extends Resource
@export var face_scenes: Dictionary[StringName, PackedScene] = {}  # tavern (Look A), grimoire (Look B): the 2D faces rendered to textures
@export var face: StringName = &"tavern"       # the active look until the user picks one (section 7, question 1)
@export var back_texture: Texture2D            # the card back (navy and gold, the cube emblem)
@export var rarities: Dictionary[StringName, CardRarityLook] = {}   # common, rare, epic, legendary, mythic (catalog names)
@export var corrupted: CardRarityLook          # overrides frame and outline for Item.Corrupted, keeps the rarity gem
@export var elements: Dictionary[StringName, CardElement] = {}     # physical, fire, ice, void, food, neutral
@export var element_rules: Array[CardElementRule] = []             # first match wins, after the per-card override
@export var default_element: StringName = &"neutral"
@export var default_icon: Texture2D            # used, with a warning, when a card has no icon
@export var icons: Dictionary[StringName, Texture2D] = {}          # item card id → game-icons glyph (the icon pass, 3.5)
@export var portraits: Dictionary[StringName, Texture2D] = {}      # character id → prerendered portrait (3.5)
@export var element_overrides: Dictionary[StringName, StringName] = {}   # card id → element
@export var name_font: Font                    # section 7 question 1
@export var pack_looks: Dictionary[StringName, CardPackLook] = {}  # pack id → look (pack art colour, glyph, label)
@export var choreography: PackChoreography

class_name CardRarityLook extends Resource      # one per rarity: frame metal, gem, effects
@export var color: Color                       # the rarity colour (shared with 5b2 item-cards and the pack tells)
@export var frame_light: Color
@export var frame_dark: Color
@export var tier: int                          # 0 Common .. 4 Mythic: the `tier` parameter of every card effect
@export var crest: bool                        # the crown crest above the art (Legendary, Mythic)
@export var face_effect: FxDefinition          # a looping effect on the card in the collection (Epic glow, foil for 3 and 4)
@export var face_effect_params: Dictionary = {}

class_name CardElement extends Resource
@export var color: Color                       # tints the art window, the item glyph and the portrait's rim light

class_name CardElementRule extends Resource    # "a card whose tags (or its abilities' asset tags) match → this element"
@export var query: GameplayTagQuery
@export var look_in_abilities: bool = false    # also match the tags of the abilities it grants or uses (Damage.Type.*)
@export var element: StringName

class_name PackChoreography extends Resource   # every number of 2.4 (seconds, positions, stagger) and the five FxDefinitions
```

The **rarity colours** (mock-up legend): Common `#cfd3dc`, Rare `#3e8cff`, Epic `#b05cff`, Legendary `#ff9d24`, Mythic `#ff4f86`,
corrupted outline `#e040fb` (the magenta of 5b2). Slice 5b2 reads `CardStyle.rarities` and `corrupted` for its floor outlines.

**Element resolution** (deterministic, per card): `element_overrides[id]` → the first `element_rules` match (seed rules: `Item.Corrupted`
→ void; `Item.Food` or `Pool.Food` → food; abilities with `Damage.Type.Fire` → fire, `Damage.Type.Ice` → ice, `Damage.Type.Physical`
→ physical) → `default_element`. A character's element is the damage type most of its abilities carry (ties: physical, fire, ice).

### 3.3 Godot code (`game/cards/`, system code)

| Piece | What it is |
|---|---|
| `CardFace` (RefCounted, pure data) | id, kind (character, item, equipment), name, text, type line (`<Kind> — <subtype>`: a character's `role`; an item's Passive / Usable / Food and its room pools; armor's slot), rarity, set id, core, pools, element (tints the art window and the glyph; never shown as a badge), art (icon or portrait), corrupted, slot. `CardFaces.build(content, catalog_rows)` makes them; no Node, testable headless |
| `CollectionModel` (pure) | catalog x faces x `CollectionResponse` x seen set → entries with state (owned, missing, core, locked by run, new), filters (set, kind, rarity, pool, owned / missing, text), sort (kind, rarity, name; Hearthstone's order: characters first), pages of 8 |
| `PackReveal` (pure) | from a `PackOpenResponse`: five slots with rarity, tier, duplicate, dust, pity, new; flip order, `reveal(i)`, `reveal_all()`, `done`; the labels' text |
| `CardAccount` | the single account action in flight (2.5) over `ServerLink`, its in-memory key, `run(kind, target)`, the retry until answered with `reconnecting` / `reconnected`, `give_up()`, the 1403 cancel path |
| `CardSeen` | the per-player NEW set, `user://saves/<player>/cards_seen.json` (ids seen in the collection); a card is NEW until shown in the detail or hovered for 0.5 s |
| `CardFaceCache` | renders a face scene once per (card, state, style version) into an `ImageTexture` (one shared `SubViewport`, `UPDATE_ONCE`), LRU of 64; a page never keeps 8 live viewports |
| `CardView3D` (Node3D) | a thin rounded card mesh: face texture on the front, back texture on the back, a material that takes the foil / glow shader (`foil_shimmer`, `glow_aura`), hover tilt toward the cursor with a moving glare, lift, flip; built on `FxStage.world_root` |
| `CardIconPass` | the icon proposal (3.5) |

Screens (`presentation/demo/ui/cards/`, each a `UIScreen` on the theme; Back top left; hover previews, click selects):
`collection.tscn` (Menu layer), `card_detail.tscn` (Modal layer), `shop.tscn` (Menu layer), `packs.tscn` (Menu layer),
no Reconnecting screen of its own: the existing connecting pop-up (`connecting_popup.tscn`, `UI.Slot.Overlay`, which dims and
blocks clicks) shows the screen's "Reconnecting…" wait text with the **Go offline** button beneath its window (2.5) and the 1412
"opened somewhere else" dialog; an
account screen swallows Back (`handles_back`) while its action is on its way,
`card_face_grimoire.tscn` (the 2D face, below), and the main menu's three `UIPushButton`s (Collection, Shop, Open packs; user 2026-11-15). The 2D slot grid owns input and focus (keyboard and
gamepad work); each `CardView3D` follows its slot through the stage camera (`Camera3D.project_position`).

### 3.3b The card face (gate 1, approved by the user 2026-11-18)

`presentation/demo/ui/cards/card_face_grimoire.tscn` (root `CardFaceView`, `game/cards/card_face_view.gd`; design size 300 × 420):
- **Layout (Magic):** a black border; a frame; the **name bar** on top (Cinzel) with the **set symbol** in the rarity's colour; the
  full-width **art**; the **type bar**; the **rules box** (parchment). Bars are **rectangular** parchment.
- **Colours by rarity**, not element: the frame and the art backdrop take the rarity's two metals (`CardRarityLook.frame_light` /
  `frame_dark`; a corrupted card the `CardStyle.corrupted` look). **Mythic**'s frame is **opal** (`game/cards/shaders/card_frame.gdshader`:
  a milky pastel iridescence drifting slowly).
- **Art:** a character's prerendered portrait fills the window; an item's game-icons glyph is **ivory** (`glyph_color`), at 60% of the
  window (`glyph_size`), with a dark halo (`game/cards/shaders/card_art.gdshader`).
- **Effects:** Common, Rare and Epic none; **Legendary** a warm gold sheen (`foil_shimmer`) sweeping top left to bottom right, starting
  and ending fully off the card, 0.35 card lengths a second, 1.5 s apart (`sweep_from` / `sweep_to` / `rest`, new and defaulted on the
  shared shader); **Mythic** twinkling rainbow glitter (`game/cards/shaders/card_mythic.gdshader`) over the opal frame; a **corrupted**
  card a steady magenta glow and a magenta frame outline. Each card starts its loops at its own point (`CardFaceView.phase_spread`,
  6 s, from a hash of the card and its view: no RNG), so a pack's cards never sweep in step.
- Tried and dropped in the engine: Look A; element colours; rounded bars; dark or tinted bars; a stone frame; a crown crest; a rarity
  outline on the art; white, element-coloured or rarity-coloured glyphs; the Epic glow; Mythic holo, rim chase, aurora and rays;
  rose prism, spectrum, holo-stripe, nebula and still-metal Mythic frames.

**Art files (a deviation from 3.2, agreed at the gate):** `CardStyle.icons` / `portraits` became two `CardArtSet` files the builders
create and the style lists in `art_sets`: `presentation/demo/cards/card_icons.tres` (the icon pass: 85 glyphs under
`presentation/demo/cards/icons/<author>/`, credited in `CREDITS.md`) and `card_portraits.tres` (the portrait tool). That way both
builders only ever create new files. Element resolution (3.2) is kept in the face data (`CardFace.element`) though the approved face
no longer shows it.

### 3.4 Files on the player's machine (client only, never uploaded)

| File | Content | Lifetime |
|---|---|---|
| `user://saves/<player>/cards_seen.json` | the seen card ids | kept; a missing or broken file means "nothing seen" (every owned non-core card shows NEW once) |

### 3.5 Icons

Game-icons.net glyphs (CC BY 3.0, decided 2026-11-12, memory "card art direction"): only the icons used are copied from
`H:\assets\game-icons` into `presentation/demo/cards/icons/<author>/<name>.svg`, imported as textures, credited per author in
`CREDITS.md` and the Credits screen. `game/tools/build_card_icon_pass.tscn` proposes an icon per card from a keyword table
(words of the name and the element: "Lantern" → `lantern-flame`, "Fang" → `fangs`, "Seal" → `wax-seal`, fire → `flame`, ...),
prints the proposal with the unmatched cards, and only with `--apply` writes the `icons` entries into `card_style.tres` (a new file
it creates, never someone's existing file without `--force`) and copies the SVGs. Characters need no icon (their art is a
portrait). The user reviews the proposal in the card gallery (section 6) before it is applied.

**Character portraits (user, 2026-11-15: prerendered stills, no generated art).** `game/tools/build_card_portraits.tscn` (a window
tool, not headless: it needs the renderer) stands each character's real view (`UnitAnimator.instantiate_for` with the main
`StyleRegistry` look, attachments and its look effect) alone in a **portrait studio** scene, `presentation/demo/cards/portrait_studio.tscn`:
a dark backdrop and floor at the cube's feet (the room floor's top, not y = 0), a warm key spot, a rim and a low glow in the card's
element colour, a soft fill, rising motes, its own `Environment` (filmic, mild glow), a camera facing the cube's front (facing 0:
turning a cube breaks its face, user 2026-11-15). It saves `presentation/demo/cards/portraits/<character id>.png` (cropped to the
oval's aspect) and writes `CardStyle.portraits` (character id → texture) into a new style file only. Re-run it after a look
changes; `card_portrait_missing` / `card_portrait_stale` (the look file is newer than the PNG) in the validator. The studio's
lights and effects are presentation data the user can tune.

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| 1 | Double click on Buy, Open, Dust or Create | One action in flight; the buttons disable while it is; the second click is ignored | `test_card_ui::test_one_action_in_flight` |
| 2 | The response is lost after the server committed (a drop) | The reconnect re-sends the same key and gets the stored response: the same five cards, revealed once, no second charge (acceptance 2) | `test_card_ui::test_lost_open_replays_same_cards` (fake bridge: commit, drop, replay); e2e `card_ui_replay` |
| 3 | No answer, 5xx, 429 | The connecting pop-up ("Reconnecting…") blocks the game and the action is retried with the same key until the server answers; it offers **Go offline** beneath its window (local mode, back to the main menu) | `test_card_ui::test_retry_keeps_key_through_server_errors`, `test_card_ui::test_give_up_settles_at_once_and_ignores_a_late_answer`, `test_card_ui::test_reconnect_caps_a_long_retry_after`, `test_card_ui::test_shop_reconnects_until_the_buy_is_answered`, `test_card_ui::test_shop_stop_waiting_shows_the_server_state`, `test_card_ui::test_go_offline_returns_to_the_main_menu_in_local_mode`, `test_card_ui::test_go_online_retries_behind_the_pop_up_until_it_answers`, `test_card_ui::test_go_offline_while_going_online_stays_local` |
| 3b | The app crashes or quits mid-action | Nothing is stored and nothing re-sent; the screens show the server's state on the next start | `test_card_ui::test_no_resume_after_restart` |
| 4 | Dust refused by the run lock, Active | The pop-up; Cancel run → abandon → `release_cancelled` → the same key re-sent → dusted | `test_card_ui::test_dust_cancel_run_path`; e2e `card_ui_run_lock` |
| 5 | Dust refused, run Verifying | The wait message; nothing else | `test_card_ui::test_dust_verifying_message` |
| 6 | Abandon refused (1410, the run turned Verifying meanwhile) | The wait message; the dust is not retried | same test, second case |
| 7 | Stale collection (1402, 1404, 1405, 1406) | The server's line in the message bar, the refused sound, the collection refetched | Shop (built): `test_card_ui::test_shop_refusals_show_the_line_and_refetch`; Collection and detail: `test_card_ui::test_stale_refusals_refetch` (not built yet) |
| 8 | Pack retired (1408) | Message, pack list refetched | `test_card_ui::test_pack_unavailable` |
| 9 | Key reused (1407; a bug) | Treated as a refusal: the key is forgotten, an error is logged with `push_error` (deliberate logging, which never fails a test: only a 1407 the test caused itself; user 2026-11-18) | `test_card_ui::test_key_reused_is_an_error` |
| 10 | Catalog drift (server card unknown locally) | "Unknown card" face, one warning | `test_card_ui::test_unknown_card_face` |
| 11 | Server unreachable on the menu | Collection opens in its offline form (core + local pool, read-only, "Offline"); Open packs shows "Needs a server connection" | `test_card_ui::test_offline_collection` |
| 12 | Back during the reveal | Reveal all, then leave; the cards are owned whatever the screen did | `test_card_ui::test_back_reveals_all` |
| 13 | A card with no icon | The default glyph and the validator warning `card_icon_missing` | validator test |
| 14 | Effects off or headless | Flips and labels without effects; `FxManager` inert headless | `test_card_ui::test_reveal_without_fx` |
| 15 | Open with no owned pack left (409 1411: the count on screen was stale) | "You have no pack of this kind left", the collection refetched, the count corrected | `test_card_ui::test_stale_pack_count` |

Replay mismatches and 2002 do not arise: nothing here is verified. No queue, so no dead letters.

## 5. Observability

**N/A for new metrics:** the screens add no server code. The existing slice 5 and 5b0 metrics already show the UI's traffic:
`rpg_packs_bought_total`, `rpg_packs_opened_total`, `rpg_cards_dusted_total`, `rpg_cards_crafted_total`, `rpg_card_actions_refused_total{reason}` (a rise in
`stale` reasons would point at the client's refetch) and `rpg_account_request_replays_total` (every replay is a client retry with a
kept key: the client half of acceptance 2 made visible). Client side: the dev console's `messages` log and `BattleLog`-style lines
for each account action (`cardui log on`).

## 6. Test plan

**Godot unit and system tests** (`tests/game/test_card_ui.gd`, on the card fixtures of `tests/game/card_world.gd`, never the demo
content):
- `CardFaces`: every fixture card gets a face; type lines (passive, usable with cooldown, consumable, equipment slot, food, character
  role) in the `<Kind> — <subtype>` form; the portrait or icon chosen; the element resolution order (override, rules, abilities, default) and the character tie
  rule; corrupted; a golden JSON of the fixture faces (`tests/fixtures/golden/cards/faces.json`, recorded with `--update-goldens`).
- `CollectionModel`: each filter alone and combined, the sort, paging (8 a page, last page short), states incl. locked by run (from
  `lockedByRunId`), NEW from the seen set, local mode (core + local pool, no wallet).
- `PackReveal`: five slots from a fixture response, tiers, pity ribbon, duplicate dust, NEW only for cards not owned before the
  open, reveal order, reveal all, done.
- `CardAccount` over the fake bridge of `test_cards`: the cases of section 4 (1 to 9).
- Class pick: locked characters in server mode, all characters in local mode.
- Screens: the collection, detail and pack screens open and close through the `UIManager`, Back works on each, `UIPolicyCheck`
  passes, the main menu has the two buttons, Open packs is disabled offline.
- Isolation: no file under `presentation/demo/cards/` is reachable from `combat/`, `game/verify/` or the ruleset version's inputs.
- Validator: `card_icon_missing` (warning), `card_style_rarity_missing` (error: a catalog rarity with no look),
  `card_style_element_unknown` (error), `card_icon_pass_stale` (warning: an icon file not in the registry or the reverse).
- Console (dev-tools parity, memory "Dev tools Claude parity"): `cardui open collection|packs|detail <id>`, `cardui page <n>`,
  `cardui filter <field> <value>`, `cardui pack <pack id>` (a real open) and `cardui pack demo [rarity ...]` (a made-up response,
  presentation only, local mode allowed: plays the choreography without touching an account), `cardui reveal <i>|all`,
  `cardui log on|off`; each refused where it makes no sense and tested.

**Headless and window tools:**
- `game/dev/card_gallery.tscn`: every card of the content at every state (owned, missing, locked, NEW) and the five rarity tells;
  `-- --shots <dir>` saves contact sheets (as `fx_gallery` does), used for the user's look gate and smoke-tested headless in the suite
  (no errors, one sheet per page).
- The icon pass: deterministic proposal on the fixtures (golden), `--apply` writes only a new file.

**End to end** (`tools/e2e.sh`, `#! cards`, the real demo catalog, real Godot headless through `dev_run --server`):
- `card_ui_open`: `cardui open packs`, `cardui pack descent`, `cardui reveal all`, `expect` gems down by the price, five cards,
  dust up by the duplicates; `cardui open collection` shows the new cards.
- `card_ui_run_lock`: start a run, `cardui open detail <owned card>`, dust → the pop-up answered "Cancel run" by script (`ui press`),
  the run Abandoned, the card dusted, one `card_ledger` row (`.sql` check).
- `card_ui_replay`: the control folder's `server-stop` right after the open's commit is not timeable, so the scenario stops the
  server before the open, waits until the account reconnects, restarts the server: the open goes through
  once, with the key it started with (`account_requests` has one row, `rpg_account_request_replays_total` unchanged); the
  lost-response half is covered by the fake bridge test above.

- `card_ui_open` buys first: `cardui shop buy descent 2`, `expect` gems down by twice the price and two owned packs, then opens one
  (`expect` one pack left, gems unchanged by the open).

Both suites must pass (`tools/godot_tests.sh`, `tools/dotnet_test.sh`; the .NET suite is unchanged by this slice).

**User gates (studio rhythm, memory "Studio mindset"):** (1) **the first implementation step:** Look A and Look B built as real
face scenes and shown side by side in the card gallery's live window (the same demo cards in both, the way the cube looks were
reviewed in lineups), on the 4K screen; the user picks one there, and the other is removed; (2) the collection and detail screens in a live window; (3) the pack opening in a live window (`cardui pack demo epic
legendary mythic`), on the 4K screen per memory "Godot window monitor".

## 7. Decisions to confirm, and what stays out

**Questions for the review:**
1. ~~The look~~ **decided 2026-11-18: Look B "Grimoire"**, as described in 3.3b; Look A deleted. Before the pick: **A and B both
   built, chosen in the engine** (user, 2026-11-15: "in engine I would like to see both A and B"; C is dropped). Two face scenes, `card_face_tavern.tscn` (A) and `card_face_grimoire.tscn` (B),
   share every field of `CardFace` and the same art; `CardStyle.face_scenes` holds both and `CardStyle.face` names the active one.
   The look is switched live with the console's `cardui look tavern|grimoire` and a dev-build row in the Graphics screen, and the
   card gallery shows both side by side. Once the user picks, the other scene is deleted (with the user's OK) and `face_scenes`
   goes back to one entry. The mock-up is a reference; the cards are adjusted in the engine.
2. ~~The card name font~~ **decided:** Cinzel (user, 2026-11-15), a new OFL font in `presentation/demo/ui/fonts/`, credited like
   Chakra Petch; card names only, the chrome stays Chakra Petch.
3. **Sounds.** The pack burst, the flips and the rarity stings: pick from the existing bank (my proposal: `ui.confirm` for the
   socket, the break sound for the burst, the cue sounds of heal / revive / phase change for Epic / Legendary / Mythic), or import a
   few new takes through `tools/audio_import.py` with the user's picks. Retro Anime stays reserved for the two ults.
4. ~~Opening costs gems~~ **decided:** packs are bought in a separate Shop and opened from the account's unopened packs, whose
   count shows on the Open packs screen, as in Hearthstone (user, 2026-11-15). A buy has no extra pop-up (the button names the
   price); an open needs none (already paid).
5. **The class pick locks unowned characters** (2.6) in this slice. It is a flow fix the UI needs; it could move to 5c.

**Decided in review (user, 2026-11-15):** no ATK / HP corners and no top-left badge; a Magic-style type line names the card's kind;
item art is the game-icons SVGs; character art is prerendered portraits of the in-game cubes, never generated art; portraits face
the camera.

**Decided by the roadmap entry:** Hearthstone's collection viewer and pack opening almost 1 to 1; only Open packs and Collection
reach the screens; the main menu is not redesigned; the FF7 theme for chrome, buttons and text; hybrid 3D stage under 2D chrome;
every effect as `FxDefinition` data; the UI framework. **Decided earlier (memory "card art direction"):** frames per rarity, one
game-icons glyph per card tinted by element, `foil_shimmer` / `glow_aura` / `rays`, no
illustrations. (The live spinning cube on character cards is replaced by prerendered portraits, user 2026-11-15.)

**Stays out:** golden cards, card backs as collectibles, a shop for gems or bundles (5c prices packs), the collection's deck view
(there are no decks), animated card art, the floor item cards (5b2), the balance numbers (5c), trading.
