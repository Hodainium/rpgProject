# Spec: descent-lifebinder (slice 5j2, after 5j `second-pack`, before 5c `card-balance`)

Status: **spec written 2026-11-26, awaiting the user's review.** A small slice the user asked for on 2026-11-26: the
**Lifebinder**, first designed for the Blood Moon pack, joins the **Descent Pack** unchanged (its design, playstyle, three
items and approved look), because its nature theme fits neither Blood Moon nor that pack's playstyle (spec `second-pack`
2.3b, D15). Builds on `specs/second-pack.md` (the kit and the kernel hooks B2-B4 it needs), `specs/card-collection.md` /
`specs/pack-shop.md` (sets, catalog, seeding, openability), `specs/cube-style.md` (looks), `specs/level-cap.md` (the
level rhythm), `specs/bot-play.md` (role and fit tags).

## 1. Purpose & enterprise mapping

**Purpose.** The Descent Pack has five characters (Cryomancer, Pyromancer, Ember Knight, Shatterweaver, Plaguewright) and no
healer: all healing comes from the core Cleric. The Lifebinder makes it six, a support whose meter fills with **all healing
the party receives** and fires a free follow-up attack each time it fills (Honkai: Star Rail style). Card counts after the
slice (catalog of 2026-11-26):

| Set | Characters | Items | Cards |
|---|---|---|---|
| Core (owned by everyone, not sold) | 6 | 115 | 121 |
| Descent Pack | 5 → **6** | 74 → **77** | 79 → **83** |
| Blood Moon Pack (5j) | 5 | 23 | 28 |

**Enterprise mapping.** No new component; the card system end to end with one more character:
- **Catalog:** `build_card_catalog.tscn` adds 4 rows (set `descent`: the Lifebinder, Mythic; Seedling Charm, Common;
  Verdant Heart, Epic; Lifebloom Crown, Legendary) to `infra/economy/card_catalog.json`; `tools/check_card_catalog.sh`
  shows no drift afterwards.
- **Postgres:** `CardSeeder` adds the 4 rows to `cards` (it only refuses a file that takes a core card away); the
  `descent-pack` pack type is unchanged (`setIds` ["descent"]), so the new cards become drawable at once; no migration.
- **Redis:** `catalog:cards` refreshes by its TTL (1 h); the deploy note says to delete the key after seeding.
- **RabbitMQ / Redpanda / outbox:** the existing card and run events; no new topic or queue.
- **Verification:** the Lifebinder's moves are ruleset content; its battles are verified by replay like any other.

**Acceptance scenarios covered:** 5 (a tampered battle with a Verdant Lash meter follow-up is rejected 2002: a tampered
golden).

## 2. Sequence flow

1. **Content** (`content/demo/`, the standing content permission): `characters/lifebinder.tres` (tags `Character.Lifebinder`,
   `Card.Set.Descent`, `Unit.Role.Healer`, `Unit.Role.Support`, `Unit.Role.FollowUp`), its abilities, effects, level rows
   and `growth_support` bands exactly as recorded in `second-pack` 2.3b; the three items with `Card.Set.Descent`, their
   rarity tags and pools (Seedling Charm: Treasure, Shop, Chest; Verdant Heart: Treasure; Lifebloom Crown: Boss), fit tags
   (`Item.Fit.Healing` + `Item.Fit.FollowUp` for the meter items). The meter uses 5j's hooks: B2 heal events
   (`Event.Ally.Heal.Received`, `Event.Heal.Received`), B3 meter abilities (`meter_attribute`, `meter_threshold_of` 50% of
   max HP), B4 the `meter` attribute; Verdant Lash's heal carries `Hit.Meter` so it never refills the meter.
2. **Look** (`presentation/`, the user's folder): the approved look of 2026-11-26 joins the main style registry
   (`bm_lifebinder_crown` Top, `bm_face_lifebinder_a` Front, `bm_lifebinder_staff` Right offset (-0.14, -0.1, 0), body
   colour (0.45, 0.78, 0.58)) plus its own combined floor effect, a green glow and green orbs (previewed as `golden_glow`
   and `wisp_motes`; every particle takes the effect's colour). The three shape files are renamed from `bm_lifebinder_*` to
   `lifebinder_*` (they are no longer Blood Moon's), only with the user's OK at build time (design files are never renamed
   without it). Then a 4K portrait (`build_card_portraits.tscn --only demo.character.lifebinder`), a card face, a class-pick
   preset in `party_presets.tres` (an edit, shown old → new), animations from the default set and sounds by the audio pass's
   rules (its ult sound picked by the user).
3. **Catalog:** `build_card_catalog.tscn` regenerates `card_catalog.json`; the API's `CardSeeder` adds the rows on start.
4. **Play:** an account that opens a Descent Pack can draw the Lifebinder (Mythic) and its items; owned, it joins the class
   pick and the items enter that account's run pools (the run's card pool, as for every card). Nothing changes for an
   account that does not own them.

## 3. Data contracts

N/A: no new record, queue, topic or Redis key. The catalog rows, the pack type and the card events use the existing shapes;
the Godot fields come from 5j (B2-B4).

## 4. Failure modes

- **5j not built:** the Lifebinder needs B2-B4; this slice starts only after 5j is merged.
- **Catalog drift:** the validator's card rules (`card_set_missing`, `card_rarity_mismatch`, ...) and
  `tools/check_card_catalog.sh` fail until the catalog file is regenerated.
- **Openability:** the Descent set gains a Mythic, an Epic, a Legendary and a Common, so every rarity the pack can give
  still has a card (the seeder and the openability rule of `pack-shop` re-check it).
- **Meter loops:** as in `second-pack` (meter heals never fill meters, at most 3 fires per check, the chain cap).
- **Existing runs and saves:** a run's card pool is fixed at its start and hashed; a run started before the new cards were
  owned keeps its pool, so no hash changes.
- **Balance:** the Lifebinder is measured on the gate after the slice and tuned in 5c with everything else.

## 5. Observability

N/A for new metrics: the existing `rpg_packs_opened_total{pack}`, `rpg_pack_cards_total{pack,rarity}` and
`rpg_cards_owned` cover it. The play report adds the Lifebinder's per-class row and `meterFires` (from 5j).

## 6. Test plan

Godot:
- Content: the Lifebinder and its three items validate (`validate_content.tscn`, `test_content_valid`); card faces render
  (no "Unknown card"); the catalog is in sync; the style validator accepts its look.
- `test_demo_lifebinder`: the meter fills from heals the party receives from any source (the Cleric, lifesteal, its own),
  Verdant Lash fires at 50% of its max HP and subtracts the threshold, its heal never refills the meter, Bloom adds half
  the threshold, Deep Roots lowers it, Evergreen hits every enemy.
- A golden `lifebinder-seed-*` with a meter fire, its trace and a tampered copy (rejected 2002); every existing golden
  replays unchanged.
- Auto: the Lifebinder's heals are chosen by `AutoPolicy._heal` (spec `auto-support`).

.NET (Testcontainers):
- The seeder adds the 4 rows; a second seeding changes nothing; the Descent pack type stays openable.

Balance: the gate on 100 seeds with the Lifebinder in the pool (spec `gate-size-by-change`), the class row in the report.

## 7. Decisions, open questions, what stays out

**Decisions (user, 2026-11-26):** the Lifebinder moves to the Descent Pack unchanged (design, playstyle, three items,
look); it is a small slice of its own after 5j.

**Open questions:**
- Q0. Verdant Heart ("your meter fills 30% faster") works only for the Lifebinder, against `second-pack` D26
  (no single-character items): it gets a generic effect in this slice, proposed with the build.
- Q1. Rename the three shape files to `lifebinder_*` (proposed) or keep the `bm_` names?

**Stays out:** retuning the Descent Pack's odds and prices (5c), new Descent items beyond the Lifebinder's three, events
for the Lifebinder.
