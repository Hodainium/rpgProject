# Roadmap: slices and design breaks

Agreed 2026-10-14. This is the build order. Each slice gets its own `specs/<slice>.md` via `/spec` before any code.
Cycle per slice: `/spec` → `/implement` → commit `feat:` → `/sync-spec` → commit `spec:`.

## Where we are
| Slice | Status | Date |
|---|---|---|
| 0. `project-skeleton` | ✅ Done | 2026-10-19 |
| 1. `combat-replay-core` | ✅ Done | 2026-10-19 |
| 1b. `game-skeleton` | ✅ Done | 2026-10-19 |
| 1c. `dev-tools` | ✅ Done (spec synced; remaining work listed in `specs/dev-tools.md`) | 2026-10-20 |
| 1c2. `item-pass` | ✅ Done (spec synced; known test gaps listed in `specs/item-pass.md` 6) | 2026-10-20 |
| 1c3. `animation-sets` | ✅ Done (spec synced; `uid://` test for `view` still to add, `specs/animation-sets.md` 6) | 2026-10-21 |
| 1c4. `ult-interrupts` | ✅ Done (spec synced; one known test gap in `specs/ult-interrupts.md` 6) | 2026-10-21 |
| 1c4b. `atomic-battles` | ✅ Done | 2026-10-22 |
| 1c5. `content-pass` | ✅ Done (2026-10-25) | 2026-10-22 |
| 1d. `playable-demo` | 🔨 Implementing (A–C6 done: tools, the ten-floor Descent, 11 classes, XP and rest; smart 4-member 35.33% (2026-10-27); D screens done; D2 `ui-framework` (Lyra-style UI) done; D3 `gameplay-messages` (Lyra-style message bus) done; E Windows export done (player, dev and full builds, release check); next the design break: your tuning on the smart 4-member report, then F `/sync-spec`) | 2026-10-26 |
| 1e. `auto-battle` | ✅ Done (`AutoPolicy` as the player's Auto, `Ability.Role.*` tags incl. RestoreMP, battle panel and Settings; smart 4-member 35.33%; small follow-ups in the spec) | 2026-10-27 |
| 1f. `ff7-ui` | ✅ Done (spec synced; FF7 theme on every screen, battle HUD, toasts and battle feed, exploration HUD and map views, Equipment/Armor/Use/Status screens, Block and Basic tags, descriptions; 389 Godot tests; smart 4-member 35.33%; small follow-ups in the spec's section 6) | 2026-10-27 |
| 1f2. `keys-and-gear` | ✅ Done (spec synced; smart 4-member 33.33%; keyed golden and follow-ups done; keys as a second currency that opens item rooms and shops, the Accessory and Weapon slots with new pieces, one logged swap action for gear and a logged move for use items, Field / Battle usage tags on abilities, a room-reveal item that shows unexplored event rooms on the map) | |
| 1f3. `skill-points` | ✅ Done (spec synced; smart 4-member 31.8% on the 600 balance seeds, sound parties 38.9%, about 3 basics per ability, 0 turn limits; MP is Skill Points: SP from basic attacks per class, +7% a level, costs at 2.5× through the cost pass, SP items; level skills with ranks and passives, enemy levels and secret skills; turn limit 500 as a loss; soft enrage on bosses; the death map, pair and boss analysis, `BattleLog`) | |
| 1f4. `event-items` | 🔨 Implemented, awaiting playtest (who gets an item from an event or a chest: `GiveItem.recipient` FIRST/RANDOM/CHOOSE, chests always CHOOSE, the logged `give_to` and the Give to panel; item toasts for every gift) | 2026-10-27 |
| 1f5. `playtest-fixes` | 🔨 Ongoing, stays open (small UI and game adjustments from playtesting, one numbered entry each; was `ui-fixes`: menu frame, battle HUD panels, run toasts, feed lines, party strip) | 2026-10-27 |
| 2. `run-checkout` | ✅ Done (spec synced; `server-authority` Part A: runs and HMAC floor seeds from the server, the Redis run cache with Postgres fallback (scenario 4), the ruleset version stamped at export, the client's seed source with local mode byte-identical; checked end to end by `tools/e2e.sh`) | 2026-10-27 |
| 2b. `run-authority` | ✅ Done (spec synced; `server-authority` Part B: bearer dev tokens, the action log uploaded in ordered idempotent batches with checkpoint snapshots and battle sessions, the stairs and win gates, local saves and resume from the save or the server's log, presence and the Lua rate limiter; seven `tools/e2e.sh` scenarios; remaining: a manual windowed playthrough of the demo against the dev server) | 2026-10-27 |
| 3. `battle-verify` | ✅ Done (server half: contracts, migration 0003, jobs on RabbitMQ, the reconciler, the verifier worker with retry tiers and DLQ, the verdict endpoint, caches, metrics, Grafana panels; Godot half: `server verdict`, `wait verdict`, the e2e worker/tamper steps and five `verify_*` scenarios, the Linux image check (18 goldens identical on Linux and Windows); open items in `specs/battle-verify.md` section 8: a malformed replay request is retried and never rejected (fix planned in slice 4a); a killed worker's lock delay (removal planned in slice 4)) | 2026-11-02 |
| 4. `settlement-outbox` | ✅ Done (spec synced; one outbox for RabbitMQ jobs and Redpanda events with a relay, exactly-once boss settlement in the verdict transaction behind three gates, the wallet and `GET /wallet`, `BattleFacts` from the Godot replay, `lock:battle` and the sweeper removed; 257 .NET, 539 Godot, 14 e2e scenarios; open: trace continuity through the outbox, retention, pending gems in 4a) | 2026-11-03 |
| 4d. `economy-challenges` | ✅ Done (a reward per challenge id paid once per cycle, no tiers (a score band is independent stars), weekly ISO-week cycles from battle time, event expiry, manual resets for everyone or one player, a Development clock offset, data-driven challenge conditions and stars in Godot content; 377 .NET, 558 Godot, e2e `reward_challenge`, `reward_stars`, `reward_clock_offset`, `reward_reset`) | 2026-11-06 |
| 4c. `economy-rewards` | ✅ Done (commit f501e4e; spec `specs/economy-rewards.md`): per-boss reward rules in a server-owned table, the economy boundary (Godot run inventory vs account economy), admin endpoint and console command, and trace continuity through the outbox | |
| 4a. `run-verify` | ✅ Done (spec synced; steps cut at the claimed snapshots with a genesis anchor the server builds at run start, a worker pool replaying each step in headless Godot with a battle simulated once, the fan-in aggregator (verified prefix, links, floors, win, rollback with epoch, `MaxRollbacks`), the stairs gate 1107 and epoch gate 1108, pending gems claimed at release, the floor read model, run hash `run-v2` covering everything that decides play; the per-battle worker is removed; 416 .NET, 582 Godot, the e2e scenarios and the Linux golden check pass; open: routing by ruleset (9), retention (7b)) | 2026-11-08 |
| 4b. `game-analytics` | ⬜ Not started | |
| 5. `card-collection` | ✅ Done (spec synced; the account's cards on the server: catalog, packs with Epic / Legendary / Mythic pity and a Rare guarantee, dust and craft, the run lock, the run's item pool as a verified input, `POST /runs/{id}/abandon`; Godot: the pool in the run hash and steps, card tags on all 160 demo cards, core-set proposal, console commands, run-end gate; no Vault pool; 535 .NET, 626 Godot, 5 card e2e scenarios; not built: the Grafana row; the screens are 5b, the numbers 5c) | 2026-11-09 |
| 5a. `vfx-framework` | 🔨 Built, awaiting the user's review (`specs/vfx-framework.md`; data-driven FX in 2D, 3D and hybrid, the GodotGAS cue bridge, the hybrid stage, a shader library, a proof set of 12 effects, dev tools, the gallery; 696 Godot tests; every hit in a battle now sparks; spec to sync after tuning) | 2026-11-09 |
| 5a2. `vfx-content-pass` | ✅ Built 2026-11-09 (effects for hits, DoTs, controls, stat statuses, heals, revives, 24 ultimates, battle moments and damage numbers; open for playtest fixes) | `specs/vfx-content-pass.md` |
| 5a3. `vfx-stencil` | ✅ Done (PRs #21, #22, #23, #24; `specs/vfx-stencil.md`, reusable reference `specs/design/stencil-over-own-unit.md`): stencil replaces the depth bias, each unit stamps its battle position's value, effects draw over their own unit in two passes (OWN, OTHER) through `FxStencilMaterial`, the shader copies are prepared at boot, run start and battle start; the leak went from 270 to 6 pixels at equal GPU time and the first-battle hitch is gone (user playtest 2026-11-12). Open items in the spec. | 2026-11-12 |
| 5a4. `cube-style` | 🟨 In progress (`specs/cube-style.md`, an art experiment in rounds with user gates; the primitives preview liked 2026-11-12; round 1, the stage moods, done (PR #26); round 2, attachments as data, built and awaiting its gate) | |
| 5b. `card-ui` | ⬜ Not started (needs 5a; look decided, see its section) | |
| 5c. `card-balance` | ⬜ Not started | |
| 5d. `unique-events` | 📝 Spec written and decided (`specs/unique-events.md`; implemented with 5c) | 2026-11-09 |
| 6. `observability` | ⬜ Not started | |
| 7. `live-dashboard` | ⬜ Not started | |
| 7b. `data-retention` | ⬜ Not started | |
| 8. `load-and-chaos` | ⬜ Not started | |
| 9. `ruleset-versioning` | ⬜ Not started | |

Statuses: ⬜ Not started · ⏭️ Next · 📝 Spec written · 🔨 Implementing · ✅ Done (acceptance scenarios pass).
**Claude keeps this table current:** update it whenever `/spec`, `/implement` or `/sync-spec` moves a slice, and
include the change in that slice's commit.

## Changing the roadmap
The roadmap is a living plan. Slices can be reordered, split, merged, added or dropped whenever the user decides.
- Edit the slice list and the table together, so they never disagree.
- Add a line to the change log below saying what changed and why.
- Claude may propose a change (e.g. a slice turns out too big) but only edits the roadmap after the user agrees.
- Commit roadmap changes as `spec:`.

### Change log
- 2026-10-14: Roadmap created (slices 0–9, four suggested design breaks).
- 2026-10-14: Server renamed `Rpg.BasServer` → `Rpg.GameServerApi`; client HTTP layer moved to its own library `src/Rpg.Client`.
- 2026-10-14: Target .NET 10 LTS instead of .NET 8 (support ends 2026-11-10); Godot fallback recorded in the project-skeleton spec.
- 2026-10-19: Design notes moved to `specs/design/` (`combat-design.md`); slice specs stay at the top of `specs/`.
- 2026-10-19: Added slice 1b `game-skeleton` (the Godot game's bare bones) after slice 1 and before slice 2, at the
  user's request: having the game's structure in place first helps the rest of development. To be specced in a
  separate game-design chat.
- 2026-10-19: Split 1b into 1b `game-skeleton`, 1c `dev-tools`, 1d `items-and-loadouts`, 1e `playable-demo`, at the
  user's request, following the game design outline in `specs/design/game-design.md`.
- 2026-10-19: Added slice 2b `run-authority` (authentication; server-owned run state; batched battles plus quick
  authenticated messages for out-of-battle actions) and a system-design pass after 1d, at the user's request.
- 2026-10-19: Merged `items-and-loadouts` into 1b `game-skeleton` (all game mechanics before any tooling; no tools for
  mechanics that don't exist yet). Order is now 1b skeleton → system-design pass → 1c dev tools → 1d playable demo.
  The demo content moved from 1b to 1d. At the user's request.
- 2026-10-19: 1b also creates a small example set in the user's folders (`content/demo/`, `presentation/demo/`, real
  tags and the AttributeSet in `godot_gas/`) so the hand-made structure is visible early; 1d grows it. At the user's request.
- 2026-10-19: Kept `dev-tools` (1c) before `playable-demo` (1d). Building the demo with the tools is expected to expose
  limits and wrong assumptions in them; fixing those is part of 1d's scope. At the user's request.
- 2026-10-19: The system-design pass writes one spec, `specs/server-authority.md`, split into Part A (slice 2
  `battle-checkout`: sessions, Postgres, Redis) and Part B (slice 2b `run-authority`: auth, run state, items), built in
  that order. Both are client ↔ server work and share contracts. At the user's request.
- 2026-10-19: Added 4b `game-analytics` (after the outbox, which it needs) and live-monitoring and player-analytics
  pages in slice 7: players online and in battle, most played characters and parties, most used moves, items picked
  up, event decisions, gacha banner earnings (general behaviour, not per-player pricing). Root `CLAUDE.md`,
  `README.md` and `game-design.md` now describe the roguelike, not only battles. At the user's request.
- 2026-10-19: Added 1c2 `item-pass` after the dev tools: more items, tested with the console's `give` command
  instead of a temporary in-demo button. At the user's request.
- 2026-10-20: Run authority model decided (section "Run authority model" below): the client gets a whole floor at a
  time and plays it offline; every action inside it is async and server-verified; only floor changes, run start/resume
  and account actions block. Battles inside a floor no longer need a blocking handshake (seeds come from the floor),
  so `server-authority` Parts A and B are to be revised. Added 3b `run-verify` (segment jobs, parallel verification,
  floor fan-in, rollback). Placed nine Redis uses in their slices (presence, rate limiting, floor read model,
  verdict cache, work locks, live counters, leaderboards, SignalR backplane, gacha banner cache). At the user's request.
- 2026-10-20: A won run ends **blocking** (no victory screen before the server verifies the run); a death ends async.
  Local saves added; without one, resume rebuilds the run from the server's acknowledged log. At the user's request.
- 2026-10-20: `server-authority` revised for the floor model. Slice 2 renamed `battle-checkout` → `run-checkout` (runs
  and floor seeds; the blocking battle handshake is gone). 3b `run-verify` moved after the outbox and renumbered 4a:
  it publishes floor verdicts and anti-cheat events and its run-end gate settles rewards. At the user's request.
- 2026-10-20: Room sizes and shapes taken out of 1c `dev-tools` (not a priority; rooms stay 1×1 for now). At the
  user's request.
- 2026-10-20: Added 1c3 `animation-sets` after the item pass and before the demo: a unit animation set with slots
  (idle, walk, hit, block, death…), one AnimationTree shared by characters and enemies, and ability animations as
  montages. The demo's characters and enemies are then built on it. At the user's request.
- 2026-10-20: 1c2 `item-pass` grew: hit tags (crit, weakness, break, follow-up), HSR toughness and break with a
  Persona-style One More, armor slots with an armor inventory. Added 1c4 `ult-interrupts` (ults at any time, HSR) as
  its own later slice. At the user's request.
- 2026-10-20: 1c2 `item-pass` done: 35 new items and 10 armor pieces in the demo, both suites green, spec synced.
- 2026-10-21: Added 1c5 `content-pass` after 1c4 and before 1d `playable-demo`: the polish and content slice. It
  closes the remaining work and test gaps left by 1c, 1c2 and 1c3, and adds more enemies, bosses and items plus
  status effects, buffs and debuffs, so the demo is built on finished tools and a wider content base. The content is
  chosen to push the game design and cover many mechanic interactions, so the later system slices (verify, replay,
  analytics, load) are tested against many real gameplay cases. At the user's request.
- 2026-10-21: 1c4 `ult-interrupts` done: HSR ult windows (BETWEEN and DECISION), enemy interrupts, retargeting, the
  `interrupt` log field; Execute, Resurrection and the Golem's Quake in the demo; both suites green, spec synced.
  Added a verifier-cost consideration to slice 8 (state hash per checkpoint, measured). At the user's request.
- 2026-10-22: Added 1c4b `atomic-battles` after 1c4 and before 1c5: a battle is verified as one atomic unit (no
  per-action checkpoints in the log, only the final hash), with an opt-in determinism trace for tests and dev that
  finds the first divergent action. Placed before 1c5 so 1c5's goldens are recorded once, and before slice 3 because
  nothing stores action logs yet, so the breaking log change costs nothing. Resolves slice 8's verifier-cost
  consideration. At the user's request.
- 2026-10-22: 1c4b spec written. Corrected its goldens example: the tampered goldens were replayed without the
  checkpoint compare and give `TurnMismatch` / `InvalidTarget`, not `FinalHashMismatch`; added two tampered goldens
  for the end-of-battle reasons. At the user's request.
- 2026-10-22: 1c4b done and synced. Slice 8's verifier-cost note updated with the measured saving (the turn loop of
  `ult-seed-7` halved) and the cost that remains per job (content index, setup, process startup).
- 2026-10-22: 1c5 spec written and reviewed: statuses with six battle hooks (control skip, status chance, per-stack
  DoTs, combined break/ult events, boss phases, action delay and advance), two enemy brains, content chosen for
  mechanic coverage, and the earlier slices' gaps. All decisions approved as recommended. At the user's request.
- 2026-10-25: 1c5 done and synced. Added during the build (D10, the user's decision): party units have no toughness
  and are never Broken; an enemy hit on a party weakness knocks the unit down (`State.Downed`) and gives the enemy a
  One More (hook H7). 2026-10-26 (D13): `effect_hit` and `effect_res` removed; a row's `chance` is the chance (unset
  = always lands), immunity tags are the counter; Witch's Eye adds a turn to its holder's debuffs (hook H8,
  `debuff_turns`), Hexbreaker Charm Wards at battle start. Built differently from the spec: the delay sits on the
  execution row (no `Data.Delay`), phase tags are `State.Phase.Two` / `Three`, the break effects are three passives
  per character, no `Event.Ability.Used.FollowUp`, no sandbox layout. Still open: the equip/unequip run-log replay
  (4a), the dev-tools manual checklist, demo content that uses a row delay.
- 2026-10-26: Slice 5 `gacha` replaced by a Hearthstone-style card system, split into 5 `card-collection` (characters
  and items are cards; owning one unlocks it; character copies are eidolons, level = copies held − 1; gems buy packs;
  dust any card for a flat rate; craft the base set for dust) and 5b `card-market` (order book per card, escrow,
  exactly-once trades, a house account that buys at the dust rate and relists its stock). Decided by the user: held
  copies count as eidolons, order-book prices, gems buy packs and dust comes only from cards. Root `CLAUDE.md`,
  `game-design.md` and `server-authority.md` follow. At the user's request.
- 2026-10-27: Added 1f `ff7-ui` after 1e and before slice 2: an FF7 window theme shared by every screen (old ones
  restyled), an FF7-style battle HUD (party window, command window with hints, Honkai turn order) and a new
  exploration HUD (toasts, Equipment, Armor, Use Item and Use Ability menus). Client-only. Added 1f2 `keys-and-gear`
  right after it for the mechanics those menus need (keys, accessories and weapons, logged swaps, Field / Battle
  usage tags). At the user's request.
- 2026-10-26: Added 1e `auto-battle` after 1d and before slice 2: smart auto play becomes a player feature (one shared
  policy for the battle panel and the reports, ability roles as GAS tags). At the user's request.
- 2026-10-26: 1d step E: three export levels instead of one (player release build; dev and full debug builds with
  the dev tools, or everything incl. tests, so Claude can drive and test exported builds), two patched GodotGAS
  bugs (an editor class name in runtime code broke every export; a self-typed export leaked at exit), each with a
  test that fails when an update brings it back, and a release check script. Spec `playable-demo`
  3.12. At the user's request.
- 2026-10-26: 1d `playable-demo` grew (amendments C2 and C3, in the slice spec): encounter grants, brains and
  rewards, armor always to the inventory, rarity tiers with pool weights; then the full ten-floor Descent (six
  chapters: Cellar, Crypt, Ember Forge, Hollow with no item rooms, Silent Cathedral, the Vault with a final boss that
  mirrors the party's items), before the screens. At the user's request.
- 2026-10-27: 2b `run-authority` done and synced (`f254fad`): Part B as specified, plus the decisions made while
  building (spec `server-authority` decision 17). At the user's request, the seed field and run-end line in server
  mode (the dev-tools remaining-work item).
- 2026-11-03: 4 `settlement-outbox` done and synced (`f3ec811`). Built differently from the spec: the settlement config sits on
  the worker, the ledger key includes the boss id (a battle can hold two bosses), the migration backfills only sessions
  not enqueued in the last 10 minutes, the relay has a failure breaker; trace continuity through the outbox is not built
  yet (spec section 9). At the user's request.
- 2026-11-09: Slice 5b `card-market` removed entirely, at the user's request (the matching design was still open and
  the game is single-collection, like Hearthstone: no trading between players). Slice 5 is reshaped the same day: no
  eidolons (one copy unlocks a card, duplicates add no power and are worth dust); a core set every account owns, always in
  the pools and not dustable, so a collection can't be stripped down to one strong item; Hearthstone-style crafting (any
  card for dust); and a removal-only run lock covering every card acquired before the run started, one acquisition time per card. No house account, escrow or market routes.
  Then: Boss stays at 21 cards, Void starts all core, Vault gets five new items to reach 15, core items are picked by
  lowest rarity first, and two sub-slices follow slice 5: 5b `card-ui` (the number 5b, freed by the market, is reused) and 5c `card-balance`.
  Later the same day: a card is owned once (a duplicate is auto-dusted on arrival, so ownership is a set and there is no
  copy cap to decide); the run lock never expires and the player cancels the run from a pop-up to dust; the core set is
  sized like Isaac's starting item pools, with the existing room pool tags on each card. Market mentions in 4b, 7, the Redis plan and the other
  specs and docs are removed.
- 2026-11-09: Slice 5 review answers: 6 core characters, characters are Mythic (above Legendary), Hearthstone-style pity timers for Legendary and Mythic, new Food items, new card fixtures, a Verifying run blocks leaving to the main menu. Numbers open for tuning. See `specs/card-collection.md` section 8.
- 2026-11-09: Added slice 5d `unique-events` next to 5c: an event drawn from a query appears once per run, and a named item already seen falls back to the fallback item (gap found reviewing slice 5; at the user's request).
- 2026-11-08: Added slice 7b `data-retention` before 8, at the user's request: outbox, step, voided and settled-session
  tables grow forever and slice 8 should measure it. Also dropped the per-battle verifier role (`verify.battle`) with 4a:
  a battle is verified inside its step, so legacy runs (started before 4a) are simply never verified.
- 2026-11-03: Added slice 4c `economy-rewards` as the immediate next slice, before 4a, at the user's request: gem rewards
  become per-boss rows in a versioned, server-owned table (not content, not configuration), so retuning never changes the
  ruleset version; and the economy boundary is recorded: the run's inventory stays in Godot, the account economy
  (currencies, the ledger and, from slice 5, card ownership) lives in Postgres in one module, with Godot reporting facts
  and never value. Replaces slice 4's flat `Settlement:GemsPerBossMark`.
- 2026-11-10: Added an open question to 4b `game-analytics`: where the analytics tables live (main Postgres, a separate
  analytics database or schema, or a column store such as ClickHouse), to decide when the 4b spec is written. Added by an
  external chat (resume write-up discussion), at the user's request.
- 2026-11-13: Added slice 5e `audio-pass` (a new sound-effect bank and volume sliders, no music) at the user's request;
  licence check first (OFF's soundtrack ruled out: no reuse licence; the shipped RTP pack's origin to check); it comes
  after the cube-style roll-out and before 5b `card-ui`.


## Design tuning: any time, not just in breaks
The user may tune `client-godot/content/`, `presentation/` and `godot_gas/` at any point in the project.
The "design breaks" below are only suggestions for when there is something new to feel. They are not gates.
- System tests run only on `tests/fixtures/`, so tuning can never fail them. Only content golden replays change;
  re-record them when the change was intentional (see `client-godot/CLAUDE.md` section 0).
- Tuning changes the content hash, so `ruleset_version` changes. Until slice 9, a battle that is open while you tune
  may be rejected with 2002. That's expected in dev.
- Commit tuning on its own as `design:`, separate from `feat:` commits. Running `/sync-spec` afterwards keeps specs truthful.
- Before Claude runs `/implement`, the tree should be clean (commit or stash design work first) and the Godot editor saved.

## Run authority model (decided 2026-10-20)
**The client gets a whole floor at a time and plays it offline.** Every action on the floor is applied at once,
logged in order, uploaded when there's a connection, and verified asynchronously by headless Godot. The server is
authoritative over the *outcome* (verdicts, rollback, rewards), not over each step as it happens. A player on the
subway can play a floor between stops and fetch the next one at the next stop.

- **Floor seed:** `HMAC(serverSecret, runId, floor)`, issued at the stairs. Stateless, the same on retry, and
  recomputable by any worker. Everything on the floor (layout, contents, shop stock, events, battle seeds) comes from
  it. The client never gets a seed for a floor it hasn't reached.
- **Verification in parallel:** the floor log is cut into **steps**: *segments* (out-of-battle actions between
  battles) and *battles*. Each step is its own job, starting from the state the client **claimed** at that point, so
  all of a floor's jobs run in parallel. A fan-in aggregator then checks the **links**: each step's start hash must
  equal the previous step's verified end hash. A floor is valid when every step **and** every link is valid.
- **Bounded lead (gates):** the client may be at most one floor ahead of the last verified floor. A rejected step or
  a broken link rolls the run back to the last valid checkpoint and writes an anti-cheat event through the outbox.
  Rewards that leave the run wait for the whole run to be verified.
- **Accepted cheat:** a modded client can see the whole current floor (and every battle seed on it) and play it
  perfectly. Every action it sends is legal, so replay can't reject it; statistical detection (4b) may flag it later.
  Copying a local save to retry a battle before it uploads is the same cheat (hindsight on a known seed), so it's
  accepted too. Once an action is acknowledged it can't be redone: a different action at the same seq is 409 `1103`.
- **Local saves and the server's copy:** the server's acknowledged log is the run's truth; a local save is a cache of
  it plus the pending tail. A run is event-sourced, so the server never needs game rules to restore one: the client
  rebuilds the state by replaying the log (from the run start in 2b, from the last verified snapshot once 4a exists).
  If the save and the server disagree (played on another device, an old save restored), the server wins and the save
  is discarded.

### Client action policy
**Blocking** = the server must answer before the action completes (needs a connection).
**Async** = applied locally at once, sent as an ordered idempotent quick message (queued while offline), verified
later by a worker; the server's verdict is final. **Free** = client-only, never sent, never trusted.

| Action | Policy | Verified by | Notes |
|---|---|---|---|
| Sign in / dev token | Blocking | | |
| Start a run | Blocking | | Server creates the run and issues floor 1's seed |
| Resume a run | Blocking | | With a local save: the server confirms it (same run, its acknowledged log is a prefix of the save's), then the client uploads what's still pending. Without one (new device, wiped save): the client downloads the last verified checkpoint plus the acknowledged actions after it and replays them locally |
| **Take the stairs (next floor)** | **Blocking** | | Gate: this floor's log fully uploaded and the previous floor verified; returns the next floor's seed. Hidden behind the transition |
| Enter a room / move on the map | Async | segment job | Adjacency and the room's contents checked against the floor regenerated from its seed |
| Event choice | Async | segment job | Outcome comes from the floor seed |
| Item pickup (take) | Async | segment job | Item must be on offer in that room and not taken yet |
| Shop purchase | Async | segment job | Item in stock, enough coins |
| Field item or skill use | Async | segment job | |
| Battle start | Async | battle job + link check | Seed from the floor seed; the encounter must match the room's (floor read model) |
| Battle turns and result | Async | battle job | Action log replayed; mismatch → 2002 |
| **End the run (win)** | **Blocking** | run fan-in | The victory screen appears only after the server has verified every floor; rewards settle in the same step. A short "Verifying run…" screen covers it (usually only the last floor is still pending). Offline: the run waits at that screen until a connection. Rejected: rollback to the last valid checkpoint, no victory |
| End the run (death) | Async | run fan-in | The defeat screen shows at once; nothing is paid out, so there's nothing to protect |
| Save locally | Free | | `user://` save of the run state, the floor seed and the unsent action queue. A convenience copy: the server's acknowledged log always wins |
| Opening packs, dusting, crafting, spending currency, the account collection | Blocking | | Server RNG (packs) and server state; settled with the outbox (5). Cards held by a run in progress are locked |
| Animations, sounds, camera, Auto/Skip, menus, settings, inspecting items, the map view | Free | | |

### Redis plan
Redis is never the source of correctness: every entry can be lost and rebuilt from Postgres or the event log.

| Use | Redis structure | Slice |
|---|---|---|
| Run summary cache (scenario 4), delete-on-write cache-aside | string, 30-min TTL | 2 |
| Battle session cache | string, 30-min TTL | 2b |
| **Live presence** ("players online") | sorted set player → last seen; `ZCOUNT` over 5 min, `ZREMRANGEBYSCORE` to trim | 2b |
| **Per-player rate limiting** (actions, run starts) | token bucket or sliding window in a Lua script | 2b (tripped by Locust in 8) |
| **Verdict cache** for `GET …/result` polling | string, written after the settlement commit | 3 |
| **Work-deduplication locks** (`lock:battle:{id}`, per-step locks) | `SET NX` with TTL; Postgres unique constraints still guarantee exactly-once | 3, 4a |
| **Floor read model** (floor hash, room → encounter and offers, written when a floor's entry step is verified) | hash per run and floor | 4a |
| **Live analytics counters** (items picked today, most played party this hour) | `HINCRBY` / sorted sets, fed from Redpanda; Postgres keeps the history | 4b |
| **Leaderboards** (fastest clear, deepest floor per character; **verified runs only**) | sorted sets, fed from Redpanda, rebuildable from Postgres | 4b (shown in 7) |
| **Pack catalog cache** (pack types, odds, card lists) | string/hash, invalidated when a pack changes | 5 |
| **SignalR backplane** (a verdict reaches whichever API instance holds the player's socket) | pub/sub; the demo runs two API replicas | 7 |

## Slices

### 0. `project-skeleton`
`Rpg.slnx`, `Rpg.Contracts`, `Rpg.Client`, `Rpg.GameServerApi` (`/health` only), test projects, Godot `.csproj`. Server connects to the
compose stack (Postgres, Redis, RabbitMQ). Baseline OpenTelemetry and Prometheus `/metrics` wiring.
Done when `dotnet build` and `dotnet test` pass at the root; update the CLAUDE.md status table.

### 1. `combat-replay-core`
Turn order (HSR-style action value / speed), replay log schema (seed, party snapshot, ordered actions), state hash
(fields, order, integers only). Headless runner: `(seed, snapshot, action log) → final state + hash`.
Golden determinism tests on `tests/fixtures/` content only.

> 🎨 Suggested design break 1, combat feel: characters, enemies, abilities and effects in `content/`; damage formula
> and speed tuning; a battle scene in `presentation/` that plays back sim events.

### 1b. `game-skeleton`
**Purpose:** every game mechanic laid out as data before any tooling is built, so making the game becomes filling in
data files. GAS-first (`specs/design/game-design.md` section 2a). Spec: `specs/game-skeleton.md`.
World and run: rooms, chapters, floor-gen rules, run structure, hand-made floor layouts, Isaac-style seeded floor
generator, RNG streams, run state and run log. Units: characters and enemies (subclasses of `UnitDefinition`),
loadouts with encounter and placement overrides, elite variants, floor scaling. Items (passive/active, pools,
character-specific, triggered passives), equipment, shops and treasure rooms, coin drops, events. HP/MP carry-over,
out-of-battle item and spell use, `BattleSnapshot` schema v2 (touches `combat/`, `Rpg.Contracts` and goldens).
Minimal clickable flow on placeholder (graybox) screens, proven on test fixtures.

> 🧭 After 1b, a system-design pass: plan what the run adds that the wire contracts and backend don't support yet
> (run seed and RNG streams, run log, item grants, purchases, out-of-battle actions, snapshot v2 on the server side).
> **It writes one spec, `specs/server-authority.md`, in two parts that are built in order:** Part A = slice 2
> `run-checkout` (runs, floor seeds, Postgres, Redis), Part B = slice 2b `run-authority` (auth, run state, items). One spec
> so the contracts, schema and auth model are designed once; two parts so each build stays small and testable.
> **The spec opens with an authority map:** every piece of state and every action, marked as **server-authoritative**
> (the server decides; the client asks), **server-verified** (the client runs it, the server replays or checks it), or
> **client-only** (presentation and preferences, never trusted, never sent). Both parts are built from that map.
> Later slices (3–9) pick up what it leaves for them.

### 1c. `dev-tools`
**Purpose:** fast content iteration, built only for mechanics that exist: build a room and play it in seconds, jump to
any state, catch broken content at once.
Isaac-style console, 3D room editor with "Play this room", floor layout editor, seed runner / generation viewer,
content validator (runs as a test), short seed codes. Rooms stay 1×1 (room sizes and shapes deferred).

### 1c2. `item-pass`
**Purpose:** a wider item set, built and tested with the 1c tools (the console's `give <item>` makes every item
testable at once instead of waiting for treasure and shop rolls). More stat, damage-type, triggered and usable items on
the existing item mechanics; new mechanics only if an item needs one. Content work in the user's folders.

### 1c3. `animation-sets`
**Purpose:** a new character or enemy slots in by dragging animations into named slots, instead of hand-wiring each one.
- **Animation set** (presentation resource): slots such as idle, walk, hit react, block, death, victory and a
  generic cast; empty slots fall back to a default set. A unit's view scene picks its set, and `UnitDefinition`
  holds only the view's path, so loading a definition (verifier, replays) never loads models or animations.
- **One AnimationTree for every unit:** a state machine for the slots plus a montage slot on top, where the casting
  ability's own animation plays (its `execute` keys still time the hits, so combat and replay are unchanged).
- Shared animations across models through Godot's humanoid skeleton profile and bone maps.
- Presentation only: combat stays animation-free and the headless verifier never plays any. A new 1c template
  `animation_set` creates an empty set that falls back to the default one; Play shows a unit with its set.

### 1c4. `ult-interrupts`
**Purpose:** ults can be used at any time, as in Honkai: Star Rail: a character with a full ult charge can cast it
between any two actions (including during an enemy's turn order), not only on its own turn. Needs the action log to
record an ult at the point it was cast and the replay to honour it (`specs/combat-replay-core.md` already leaves
room for ultimates that interrupt). Builds on 1c2's break and One More rules.

### 1c4b. `atomic-battles`
**Purpose:** a battle is one atomic unit, end to end. The log carries the party's decisions, the claimed outcome and
the claimed final hash, nothing per action. The client stops hashing after every party action and the verifier
hashes once, at the end. The verdict was already atomic (one job, one Verified or 2002, all rewards or none); this
makes the log match it.
- **Contract:** `ActionEntry` loses `Checkpoint`, so `ActionLog.schemaVersion` becomes 2 (breaking). Now is the
  cheapest time: no server stores logs before slice 2b. **Decided 2026-10-22:** the verifier reads v2 only; a v1
  log is an unsupported `schemaVersion` (runner error, as today for unknown versions), since no v1 logs exist outside
  the goldens, which are re-recorded.
- **Mismatch reasons:** `CheckpointMismatch` goes. Structural reasons keep their turn (`TurnMismatch`,
  `ActorMismatch`, `IllegalAbility`, `InvalidTarget`, `LogExhausted`, `TrailingActions`); any other tampering shows
  up at the end as `OutcomeMismatch` or `FinalHashMismatch`. Still 2002, still deterministic (scenario 5).
- **Determinism trace (tests and dev only, zero cost when off):** an opt-in trace that records the state hash (and,
  on demand, the canonical lines) after **every** action: party, enemy, ult interrupt and One More, finer than
  today's party-only checkpoints. It never enters the wire contract. A test helper and a headless tool replay a
  request twice in fresh processes, and record vs replay, with the trace on, and diff the traces: the first
  divergent action plus the lines that differ (which attribute, tag or effect). The golden test prints that on a
  failure. For a production false 2002 later (slice 3+), the rejected request is kept and rerun locally with the
  trace on.
- **Goldens:** re-recorded on purpose (combat goldens, the scripted-run game golden); the tampered goldens' reasons
  change (measured: `ult-seed-7-tampered-turn` → `TurnMismatch` at turn 2, `squad-seed-42-tampered-target` →
  `InvalidTarget` at turn 11), and two new tampered goldens cover `FinalHashMismatch` and `OutcomeMismatch`.
- **Scope:** battle checkpoints only. Run checkpoints (`RunSnapshot` at checkpoint actions, `specs/server-authority.md`)
  are a different mechanism and stay. Specs to update: `combat-replay-core`, `item-pass`, `ult-interrupts`,
  `dev-tools`, and any `server-authority` text on battle checkpoints.

### 1c5. `content-pass`
**Purpose:** the polish and content slice before the demo. It closes what earlier slices left open and widens the
content, so 1d is spent building a run rather than fixing tools or inventing mechanics.
- **Focus: content that pushes the game design and exercises the mechanics.** Every enemy, boss, item and status is
  chosen to cover a mechanic or an interaction between mechanics (break with One More, follow-ups off statuses, ults
  interrupting during DoT ticks, death and revive under debuffs, stacking and expiry, resist vs weakness…), not for
  volume. The aim is a wide set of real gameplay cases, so that when the system slices land (2b run authority, 3
  battle verify, 4a run verify, 4b analytics, 8 load) the verifier, replay and analytics are fed many different
  mechanic paths instead of a few happy paths. The spec lists which mechanic each piece of content covers.
- **Remaining work and test gaps:** `specs/dev-tools.md` "Remaining work" (`kill` queued during an enemy turn,
  plus the manual checks), `specs/item-pass.md` 6 known gaps (dead character equipped, demo Fire-beats-Physical on
  a Slime, demo break recovery; the equip/unequip run-log replay waits for 4a), `specs/animation-sets.md` 6 (the
  `uid://` test for `view`), and anything 1c4 leaves open (`specs/ult-interrupts.md` 8: items that react to ults,
  smarter enemy ult timing, ults × statuses, party toughness, ult balance; and 6 "Known gaps": a test that a custom
  brain picking an ult as a turn action is a runner error, with the first `EnemyBrain` subclass).
- **Status effects, buffs and debuffs:** design them first (the "Not yet designed" items in
  `specs/design/combat-design.md`: magnitudes, durations, stacking, how they show), then build them as GAS content
  on the existing `Status.*` tags. Damage over time, stat ups and downs, control effects; break effects per damage
  type (`specs/item-pass.md` 8) fit here.
- **More test content:** enemies (incl. variants and resistances), bosses (multi-phase or scripted behaviour as
  data), and items that use the new statuses. Fixtures for the system tests; demo content in `content/demo/` made
  by builder scenes like 1c2's, on request and without changing the user's existing files unasked.
- Any new mechanic stays data on GodotGAS building blocks; new battle code only where a status rule needs a hook,
  with goldens re-recorded only for intentional changes.

### 1d. `playable-demo`
**Purpose:** a short run playable start to finish, to show people, and the first real test of the dev tools.
Grows 1b's example set (`content/demo/`, `presentation/demo/`) into the full demo, built with the 1c tools: coloured-cube units whose ability animations jump, spin or flash;
demo AttributeSet and tags made the GodotGAS way; a short run through battles, an event, a treasure room, a shop and a
boss. **Includes adjusting the dev tools** wherever building the demo exposes limits or wrong assumptions in them.

### 1e. `auto-battle`
**Purpose:** smart auto play as a player feature (client-only). Today the battle panel's Auto plays the first usable
ability on the first target, while the smart policy that the balance reports measure (`SmartController`, spec
`playable-demo` 3.9) is a dev tool left out of the player build. One policy, shipped: the battle panel's Auto and the
dev reports use the same system code, so the reports measure what players get. Abilities say what they do through GAS
tags (heal, revive, buff…) instead of the file-name guess the dev policy uses today, checked by the validator.
Player options to settle in the spec: Auto per battle or run-wide (and a setting), whether Auto may spend ults, a
Simple / Smart choice. Auto picks are ordinary player inputs in the action log (replayed and verified like manual
ones; no wire change); whether to record that a battle was played on Auto, for analytics (4b), is a spec decision.

### 1f. `ff7-ui`
**Purpose:** the game's look and battle screen, client-only (spec `specs/ff7-ui.md`). One theme with FF7 blue
gradient windows that every screen and every later UI element uses; a battle HUD with a party window (HP, MP, ult bar,
ULT button at any time), a command window (Attack, Ability, Block, Item, hints) and the Honkai turn order; on the
map, Isaac-style toasts (pickups, floor and chapter), a battle feed, and Equipment, Armor, Use Item, Use Ability and
Status screens. Built on the existing
Lyra-style UI framework and message bus; no wire change, run hashes and replays unchanged.

### 1f2. `keys-and-gear`
**Purpose:** the game mechanics the new exploration menus need (client-only, run rules, so run logs and hashes
change and the scripted run golden is regenerated on purpose). Keys: a second run currency like Isaac's; a cleared
room may drop one (seeded chance, a "You found a key!" toast); item rooms and shops are locked and cost a key to enter.
Gear: Accessory is a real armor slot with more accessories, Weapon is an equipment slot with more weapons, and use items
sit in Item slots. Equipping a piece or a use item another character holds swaps the two, as a logged run action.
Abilities and items say where they work with GAS tags (Field, Battle, or both), shown as [Field Only], [Battles Only] or
[Field and Battles] and checked by the validator; the Use Item and Use Ability menus read them.

### 1f3. `skill-points`
**Purpose:** a quick game design pass before the distributed slices. MP becomes Honkai: Star Rail's Skill Points
while keeping today's numeric scale (not 5 SP, but pools like 67, 143 or 205), with Persona as the reference for the
numbers: a basic attack gives SP back, an ability costs about two to three basic attacks' worth (a few cost about
one), so the turn rhythm is "attack, attack, ability" as in Honkai. Ability costs and the SP items (Ether and the
other MP restores) are retuned to match; the smart 4-member report stays the balance gate. Spec: `specs/skill-points.md` (done 2026-10-27).

### 2. `run-checkout` (Part A of `specs/server-authority.md`)
**First hookup to the server: runs, floor seeds, SQL, Redis.** The server starts a run and issues **floor seeds**
(HMAC of a server secret, the run id and the floor): floor 0 at run start, each next floor at the stairs. The client
generates and plays each floor offline from its seed. Contracts DTOs; SQL migration runner; Postgres schema
(`players`, `runs`, `run_floors`); `POST /runs`, `POST /runs/{id}/floors/{n}`, `GET /runs/current`, `GET /runs/{id}`;
Redis run-summary cache, delete-on-write, with Postgres fallback (**scenario 4**); `ruleset_version` hash computation;
`ServerBridge` + `ServerLink`; the client's **seed source** (local mode byte-identical to today). No action upload yet.

### 2b. `run-authority` (Part B of `specs/server-authority.md`)
**Auth, the action log, saves.** **Purpose:** the server owns the record of everything the player does; nothing is
trusted until verified.
- **Authentication** (bearer token; a dev token issuer until a real identity provider) on every player-state endpoint.
- **Every in-floor action is an async quick message**, battles included: applied locally at once, queued while
  offline, uploaded in ordered, idempotent batches (`(runId, seq)`), with a claimed **state snapshot** at each
  checkpoint (`start_run`, battle pending, `battle`, `next_floor`) so 4a can verify a floor's steps in parallel.
  Battles become `battle_sessions` rows on upload.
- **Gates:** the stairs need the floor's log fully uploaded; a won run blocks on "Verifying run…"
  (`Run:AutoApproveWins` stands in until 4a).
- **Local saves** and **resume without a save** (latest checkpoint snapshot + replay of the accepted tail on the
  client); the server's log always wins.
- Redis: **live presence** (sorted sets, heartbeat for "in battle"), **per-player rate limiting** (Lua token bucket,
  fails open), battle session cache.

### 3. `battle-verify`
A battle submitted in the run log (conditions + action log) → RabbitMQ job. Headless Godot verifier worker container
replays it and writes a verdict. `GET /runs/{id}/battles/{seq}` shows it. Retries, DLQ, `lock:battle:{id}`.
**Scenario 1** (duplicate submission), **scenario 5** (tampered log → 2002).
Redis: **verdict cache** for result polling (written after the commit) and **work-deduplication locks** (`SET NX` + TTL).

### 4. `settlement-outbox`
Reward settlement + outbox row in one Postgres transaction, then ack; unique constraint makes redelivery a no-op.
**Also in this slice (decided 2026-11-01): remove the `lock:battle:{id}` dedup lock that slice 3 added, or cut its TTL heavily.** A killed worker's lock outlives it for up to `LockTtl` (120 s), so its job waits about 2 minutes for a replacement worker (`specs/battle-verify.md` 8, item 2); correctness never depends on the lock, so it can go.
Outbox relay → Redpanda. **Scenario 2** (killed before ack), **scenario 3** (Redpanda down).

### 4c. `economy-rewards`
**Purpose:** per-boss gem rewards from a server-owned, versioned `reward_rules` table, an admin endpoint and a console
command to set them, the ledger recording the rule version, and the account-economy boundary that slice 5's cards plug
into. Also carries the open item from slice 4: every outbox row stores the `traceparent` of its writer, so one trace follows a
battle from the upload through the relay and the worker to the event. Spec: `specs/economy-rewards.md`. Built before 4a;
needs slice 4 committed first.

### 4a. `run-verify`
**Purpose:** verify whole floors in parallel and keep the client within one floor of the server
("Run authority model"). Comes after the outbox because it publishes `FloorVerified` and anti-cheat events and the
run-end gate settles rewards. Same Godot verifier image, one step queue,
`verify.segment` (actions from a claimed snapshot, a battle included, and floor generation at `next_floor`; the
per-battle `verify.battle` worker of slice 3 was removed with this slice). A C# fan-in aggregator (process manager, idempotent, state in Postgres) checks the links between steps
and emits the floor verdict through the outbox. The `1107` stairs gate (the floor just played must be verified), the real
**run-end verdict** (removes `Run:AutoApproveWins`), `Rejected` + rollback to the last valid checkpoint, resume from
the latest *verified* checkpoint, verdicts pushed to the client, anti-cheat events, and the **floor read model** in
Redis (written when a floor's entry step is verified). Floor N+1 can't be generated ahead of time: its item pools
depend on what was seen and held on floor N.
**Also in this slice (decided 2026-11-02): pending gems.** Slice 4 settles completion-mark gems on a verified battle
while trusting its claimed conditions (`specs/settlement-outbox.md` 8, item 1). 4a adds `wallet_ledger.status`
(`pending`/`released`/`voided`): slice 4's grants start `pending`, are released when the fan-in aggregator confirms the
battle's conditions against the run state, and voided (with an event) if the floor is rejected or rolled back.
**Also in this slice (decided 2026-11-02): reject malformed replay requests.** Today `ReplayRunner` exits 1 for a request
it refuses (unknown content id, bad schema version, unknown field), the worker retries it five times, dead-letters it, and
the session stays `Submitted` with no verdict (`specs/battle-verify.md` 8, item 1). Give the runner a distinct exit code
(e.g. 3) and a `MismatchReason` (e.g. `MalformedRequest`) so the worker commits a `Rejected` 2002 verdict at once, no retries.
Changes `combat/` and the combat-replay-core contract, so it goes in with the rejection semantics. Test: a tampered
request with an unknown encounter id → Rejected 2002, one attempt.

> 🎨 Suggested design break 2, reward loop: payouts, post-battle results screen, progression pacing, more encounters.

### 4b. `game-analytics`
**Purpose:** understand how the game is played (`specs/design/game-design.md` section 10): general player
behaviour, not per-player pricing. Run and battle events (run started and ended, room entered, item picked up, event
decision, field use, battle started and its moves and result) published through the slice 4 outbox to Redpanda; a
consumer projects them into Postgres analytics tables (idempotent by event id, rebuildable from the topic); a read API
for aggregates: most played characters and parties, most used moves, most picked-up items and who holds them, event
decisions, how far runs get, encounter wins and losses, each filterable to verified runs. Pack and dust
figures join in slice 5. No item, character or move ids as Prometheus labels.
Redis: **live analytics counters** (`HINCRBY` / sorted sets fed from Redpanda, for the live tiles; Postgres keeps the
history) and **leaderboards** (sorted sets, fastest clear and deepest floor per character, **verified runs only**,
rebuildable from Postgres). A Redpanda consumer for **anomaly flags** (too-perfect play, abandon rate, inhuman action
speed) feeds a delayed review queue, not instant bans.
**Open question (spec time):** analytics tables in the main Postgres, a separate analytics database or schema, or a
column store (ClickHouse)? A separate store isolates analytics queries from gameplay writes and is the textbook reason
for streaming through Kafka; the main Postgres is simpler for a demo. A separate database or schema on the same
Postgres server is the cheap middle ground.

### 5. `card-collection` (replaces `gacha`, 2026-10-26)
**Purpose:** Hearthstone-style collecting instead of gacha pulls. Every playable character and every item is a
**card** in the player's account collection.
- **What owning a card does:** one copy unlocks it (a character becomes playable; an item enters the run's item
  pools). **A card is owned once** (decided 2026-11-09): there are no eidolons and duplicates add no power, so a copy
  of a card the player already owns is **auto-dusted on arrival** (from a pack; a card that is already owned can't be
  crafted). Ownership is therefore a set, not a count.
- **Rarities:** characters are always **Mythic**, a tier above Legendary (decided 2026-11-09); items are Common, Rare, Epic or Legendary.
- **Core set (Hearthstone's Basic set; decided 2026-11-09):** a fixed set of cards every account owns from the start:
  the starter characters and a baseline of items. Core cards are always in the run's pools, can't be dusted, and are
  never crafted or found in packs. The item pool of a run is the core set plus the collected cards, so the pool is
  never tiny: a player can't strip a collection down to one strong card and get it every run. Collected cards are
  typically stronger items (and the remaining characters), which is why players want them. **Size and shape:** each
  item card already carries the room pool it spawns in (`Pool.Treasure`, `Pool.Shop`, `Pool.Boss`, `Pool.Void`,
  `Pool.Food`, `Pool.Chest`). The core set gives the standard pools (item room and shop) **30 cards each** and the Void pool
  **15** (decided 2026-11-09; no outside benchmark). **There is no Vault pool** (decided 2026-11-09, after this section was first
  written): the Vault floor's treasure rooms draw from `Pool.Treasure` like any item room, and `Pool.Vault` was removed from the
  content and the tag registry, so there is no pool to size and no new Vault items to make.
  The existing demo items become the first cards: the core cards are picked from them, the rest are collectible, so
  a collected card adds to a pool the core set already fills. Only the room pools carry a size
  target; `Pool.Food` and `Pool.Chest` are plain tagged pools with no minimum. Today's demo pools hold 77 Treasure, 39
  Shop, 21 Boss, 15 Void and 4 Food items (and, before the Vault pool was removed, 10 Vault). Decided 2026-11-09: **Boss stays at 21**
  (all core, no 30 target for now) and **Void starts entirely core** (it already meets its 15).
  **Which items are core:** by lowest rarity first (Common, then Rare, then Epic, then Legendary), so the collected
  cards are the stronger ones; an item counts in every pool it belongs to, so the picks are made against the 30 / 15
  targets jointly, with ties broken in the spec. Boss and Void are all core, so their Epic and Legendary items are core
  by exception. A pool that already hits its mark grows later: new cards arrive as **expansion sets** (a card set tag,
  like Hearthstone's expansions and booster sets), which is new content with no schema change, and packs can draw per
  set. Collected cards add to the pools. Which cards are core
  is content (a card set tag beside the pool tags); the balance gate is tuned on the core pool alone, the worst case for
  a new account (the retune is slice 5c, below).
- **Pity timers (Hearthstone-style; decided 2026-11-09):** per pack type and rarity, for Epic, Legendary and Mythic: the Nth pack since that rarity last dropped contains one, and a player's first packs of a type guarantee an Epic within 5, a Legendary within 10 and a character (Mythic) within 15. Set 2026-11-09: Epic pity 10, Legendary pity 20, Mythic pity 30 (Hearthstone: Epic 10, Legendary 40, first set 10); fine-tuned in 5c.
- **Core characters:** 6 starter characters are core. A won run that is still Verifying keeps its lock and the client cannot leave to the main menu until the run is accepted. In server mode all currency and ownership live on the server; local mode only has a configurable test pool.
- **Two currencies:** **gems** (from completion marks) buy **packs**; **dust** comes only from dusting cards.
- **Packs:** several pack types, each with its own card list and rarity odds. Opening is server-side, on a pack RNG
  separate from combat RNG, recorded for audit.
- **Dust:** any collected (non-core) card can be dusted for a flat rate per rarity, unless the run lock holds it. Dusting
  removes the card from the account (as in Hearthstone); there is no trading between players. Auto-dusted duplicates are
  the main source of dust.
- **Crafting (Hearthstone-style):** any card can be crafted for dust at a fixed cost per rarity, whatever set it is from,
  so every card is reachable without trading. Dusting pays a fraction of the craft cost (Hearthstone: a quarter), so
  crafting is a dust sink. The costs and refunds live in a server-owned, versioned table like the reward rules, so
  retuning never changes the ruleset version.
- **Run lock (removal only; decided 2026-11-09):** cards can always be acquired (packs, crafting) while a run is active,
  and a card acquired after the run started never affects it. Every card acquired before the run started is locked: it
  can't be dusted until the run ends or is cancelled, because the run's pools and party were built from it. Each card has
  one acquisition time, compared with `runs.started_at`. The lock **never expires**: an idle or abandoned run keeps
  it until the player cancels the run. Trying to dust while a run is active gets a `409` naming the run, and the client
  shows a pop-up offering to cancel it (the cancel path ends the run as abandoned, not as a death; starting a new run
  already abandons the previous one). A duplicate that arrives during a run is auto-dusted as usual, which never touches
  the locked copy. Verification does not depend on the lock (the run's start inputs are stored at run start); the lock
  stops a player taking dust from cards the run is built on.

Server: account collection (one row per player and card, with its acquisition time), currency ledgers and pack catalog in Postgres; collection, pack, dust and
craft endpoints (blocking account actions, idempotent by request key); currency changes and card moves in one
transaction with an outbox row (pack opened, card dusted, card crafted). Contracts: the collection, plus the unlocked
characters and items (the run's pool) in the run's starting state.
Redis: **pack catalog cache** (pack types, odds and card lists; Postgres is the source; invalidated when a pack
changes).

**Account rules** (requirements of this slice): ownership is one row per player and card with the time it was acquired
(the run lock compares it with the run's start), and every card move is also a ledger row; every gem or dust change is a ledger row with a reason, a
reference id and an idempotency key (the wallet ledger pattern, extended to dust); account actions (pack open, dust,
craft) are idempotent by request key, like the run endpoints; every card or currency move writes an outbox event, so
analytics needs no backfill.

> 🎨 Suggested design break 3, card feel: sets and rarities, dust rates and craft costs, pack odds, which cards are core and their sizes per room pool,
> pack-opening animation.

### 5a2. `vfx-content-pass`
Added 2026-11-09, right after slice 5a. Adds effects to the abilities, statuses, items and events made before the FX framework
existed, by a proposal pass the user approves (it edits existing content).

**Requirement from the user (2026-11-09):** the generic hit spark that slice 5a put on `content/demo/effects/damage.tres`
(`Cue.Fx.HitSpark` in `application_cue_tags`, so every damage application sparks the same way) was accepted for now and must
be **tuned in this slice**. There must be no one generic effect on every damage proc: poison, bleed, burn and other DoTs show
their own effects, and hits differ by damage type (and crit, weakness, break). A cue only receives its target, so per-hit
variants need either separate damage effect variants with their own cue tags, or a listener on `Message.Battle.Damage` (it
carries the hit tags) with a tag filter, which `FxListener` does not have yet. Decide the approach in this slice's spec.

### 5a3. `vfx-stencil`
**Done 2026-11-12** (PRs #21–#24). The experiment, its findings and the open items are in `specs/vfx-stencil.md`; the technique as a reusable reference is `specs/design/stencil-over-own-unit.md`. The text below is the original plan.

Added 2026-11-10 from the VFX playtest (`playtest-fixes` B14), as the user's next task. Stencil buffer support for the project,
with effects as its first user. Today an effect on a unit is kept from being cut by that unit's own mesh by a depth bias (the
unit's radius, Unreal's Pixel Depth Offset), so it still shows through a unit standing less than the bias in front of it. With
stencils, each unit view writes its own value, and an effect on a unit draws over pixels holding its unit's value whatever their
depth, and everywhere else with the normal depth test and no bias. It then draws over its own unit and is hidden by every other
unit, wall and the floor at any distance.

**Reference design: Unreal's Custom Depth-Stencil, as Lyra uses it.** Lyra turns it on (`Config/DefaultEngine.ini`:
`r.CustomDepth=3`, enabled with stencil) and marks its damage-number meshes with `SetRenderCustomDepth(true)` and
`SetCustomDepthStencilValue(123)` so post-process materials can opt them out (`LyraNumberPopComponent_MeshText.cpp`). The model:
a value 0–255 per object, set as data on the object; a buffer of those values that materials **read like a texture** and decide
about in their own code (outlines, x-ray silhouettes, masks). We follow it: a value per unit view set as data, a named table of
values (no magic numbers like Lyra's 123), and readers that decide in their own shader. Using it to draw an effect over its own
unit is our own use: Unreal effects usually do that with Pixel Depth Offset (what we have), a camera offset or no depth test.

**Two implementations, both prototyped and compared (user, 2026-11-10: test both):**
- **(a) Godot's built-in stencil test** (`stencil_mode` in spatial shaders, present in 4.7.2): the units write their value; an
  effect draws in two passes (its own unit's pixels with no depth test, everything else with the depth test). Simple and fast,
  but the comparison is fixed render state, and the reference value may be baked into the shader code (per-slot shader variants).
- **(b) An Unreal-style readable stencil texture:** the unit views' values rendered into a texture of their own (for example
  through a `CompositorEffect` or an extra pass), which effect shaders sample next to the scene depth. One pass, the unit's value
  an ordinary parameter, closest to Lyra; more to build. A Godot shader cannot read the stencil buffer as a texture as far as
  we know (to confirm).

The spec decides:
- a system table of stencil values (units by battle slot, reserved ranges for later outlines, target highlights and silhouettes
  behind walls), so features never collide;
- how a unit view carries and writes its value (as data on the view; the cube material in `presentation/` changes with the
  user's OK; humanoid materials later);
- how an effect knows its unit (its anchor), and effects with no unit (the depth bias stays as the fallback);
- the depth fade away from its own unit as classic soft particles;
- how Godot sets the stencil reference (in shader code or per material) and whether a shader can read stencil values;
- proof: both prototypes in the gallery on the same scene (two cubes close together, an effect on the back one, a floor ring,
  a big disc into the floor), compared on look, cost (passes, shader variants, frame time) and how well each serves later
  outlines and silhouettes; the user picks one; then battle shots and tests.

### 5a4. `cube-style`
Added 2026-11-12. The units stay cubes as an art choice (no humanoids; Mixamo and Quaternius characters were weighed and
rejected: mixed styles and a cost per unit that would shrink the cast). An art experiment in rounds, each ending at a user gate
with comparison shots: the stage (lighting and a mood per chapter, bevelled cubes with rim light), attachments built from
primitives (hats, crowns, horns, wings, weapons), downloaded single models (Poly Pizza, recoloured) only if wanted, then the
roll-out. Presentation only: the data lives in `presentation/`, outside the ruleset version. Spec: `specs/cube-style.md`.
Card art is decided separately (5b): data-driven frames, game-icons glyphs, the existing effects.

### 5b. `card-ui`
Added 2026-11-09, right after slice 5. The screens for the card system, built on the UI framework and the FF7 theme:
the collection (browse by set, rarity and room pool, a core badge, owned or not), pack opening, dust and craft with their
costs, and the pop-up that offers to cancel the active run when a dust is refused by the run lock (409 naming the run).
Local mode keeps working without cards (the core set only).

**Look and feel (user, 2026-11-09), carry into the `card-ui` spec:**
- Aim for an almost 1-to-1 mapping of **Hearthstone's** collection viewer and pack opening: browsing the collection
  (card grid with page turning, set/cost/rarity filters, owned and golden-style states, a crafting/dust side panel)
  and the pack opening (the pack bursts, cards fan out face-down, flip one at a time with a rarity-colored flash,
  extra drama on Epic/Legendary/Mythic and on pity hits).
- It reaches the player only through **Open packs** and **View collection**. The **main menu is not redesigned**;
  the new screens keep the **current FF7 window theme** (`ui_theme.tres`, Chakra Petch) for chrome, buttons and text.
- Hearthstone's card screens have **3D elements** (cards and packs are 3D objects that tilt, flip and catch light).
  So these screens are **hybrid**: a 3D stage (`FxStage`, a SubViewport) under 2D chrome. Our own art and layout in
  that style; Hearthstone's assets are not copied.
- All glow, burst, flip and shake effects come from **`vfx-framework` (5a)** as `FxDefinition` data; this slice authors
  effect data (rarity colors and parameters, the pack-opening choreography), not a new effects system.
- Built on the UI framework (`UIPolicy` states, `UIScreen`s, shared components, Back top left, hover previews, click
  selects) and the server calls already in `ServerLink`.

### 5c. `card-balance`
Added 2026-11-09, after 5b. The game balancing pass for cards: retune the win-rate gate on the core pool alone (30 / 30 / 21
/ 15 / 15 per room pool; the 31.8% figure was measured on the full item pool), then pack odds and prices in gems, dust
and craft costs and refunds, and the gem income per run against them. Also here (decided 2026-11-09): **four new Food items** (Food holds 4, all core, today; this takes it to 8). Also here (decided 2026-11-09): **more events** in the demo content, so slice 5d's one-event-per-run rule rarely runs a chapter dry. Design break 3 (card feel) belongs here.

### 5d. `unique-events`
Added 2026-11-09, next to 5c (the gate moves, so both are measured together). Spec `specs/unique-events.md`: an event picked
from a chapter's event query appears at most once per run (seen = placed on a floor, so it holds inside a floor too; an exhausted
pool gives an empty room; fixed room events and the rest stop stay repeatable), and a named item the run already saw becomes a
food item (like Isaac's drops), so no route hands out a second copy (pool picks already did not). Decided 2026-11-09; implemented together with 5c. Client only; the run hash gains `events_seen=`
when not empty, so the committed run goldens may change and the balance gate is re-measured.

### 5e. `audio-pass`
Added 2026-11-13 at the user's request, a small slice of its own (to be discussed in a separate chat before `/spec`).
**Order (user, 2026-11-13):** after the 5a4 `cube-style` roll-out to the remaining units, before 5b `card-ui`. A new
sound-effect bank to replace or extend the RTP pack in `presentation/audio/rtp/`, plus **volume sliders** on the Settings
screen (Master and effects, a music bus only if music comes later; Godot audio buses, saved in the Settings). **No music is
needed** (user, 2026-11-13). Licence first: only CC0 or clearly redistributable packs (the repo is public), each credited in
`CREDITS.md` (spec `cube-style` 3.7). OFF (Mortis Ghost, 2008) was raised and ruled out: its soundtrack by Alias Conrad
Coldwood is a free download (2017) but carries no reuse licence, and the 2025 remaster itself replaced it because the
composer would not sign the rights over; its sound effects only if they come from an openly licensed source. Also check
where the shipped RTP pack comes from: RPG Maker's RTP is licensed for games made with RPG Maker. Candidates: Kenney's
audio packs (CC0), OpenGameArt filtered to CC0, the Sonniss GDC bundles (royalty-free; check redistribution in a public repo).

### 6. `observability`
End-to-end traces HTTP → RabbitMQ → worker → outbox → Redpanda. Metrics: verify latency, queue age,
`error_code="2002"` rejections, outbox lag, battles started and verified per minute. Grafana dashboards provisioned
as code, including **battles per minute against server load** (CPU, memory, latency, queue age) on one panel.

### 7. `live-dashboard`
SignalR hub pushing verdicts to client and browser. React/TS `web-dashboard` live feed: battles, packs opened, anti-cheat alerts.
**Live monitoring** (players online, players in a battle, runs in progress, service health) and **player analytics
pages** over the `game-analytics` read API: characters and parties, moves, items picked up, event decisions, runs,
encounters, packs and dust flows, leaderboards.
Redis **SignalR backplane** (pub/sub) so a verdict reaches whichever API instance holds the socket; the compose demo
runs two API replicas behind a load balancer.

### 7b. `data-retention`
Added 2026-11-08, before load testing so slice 8 measures table growth. Nothing is ever purged today: published `outbox`
rows, `run_steps`, the voided archives (`run_actions_voided`, `battle_sessions_voided`), settled `battle_sessions` and
`run_actions` of finished runs, and the ledger all grow without bound. For each table a decision (spec first): the outbox
is purged once published and past Redpanda's own retention; the voided archives are evidence (the `AntiCheatAlert` trail)
and are kept N days, then moved to cold storage or dropped; `run_steps` and the claimed logs of verified, finished runs
can be dropped after the analytics projection (4b) has read them; the wallet ledger and completion marks are never purged
(they are the account's record). A retention job (a BackgroundService with a lease, batches, metrics) and a test per
table, including that a purge never touches a row a verifier or the relay can still read.

### 8. `load-and-chaos`
Locust profiles (`/stress`); scripted chaos runs for scenarios 2, 3, 4; **scenario 7** (spike → backpressure →
recovery in Grafana). This is the demo. Locust also trips the 2b rate limiter, and a slow verifier pool shows up as
players waiting at the stairs gate.
- **Consideration: verifier cost per battle.** Measured 2026-10-21 on the ult fixture battles (headless 4.7.2 mono):
  one state hash 0.3–0.4 ms, so the per-party-action checkpoints took ~5 ms of a ~12 ms simulation (30–50%). Almost
  all of it is GDScript building the canonical text, not the SHA-256. **1c4b removed them** (one final hash per
  battle; the opt-in trace locates a false 2002 instead). Measured 2026-10-22 on `ult-seed-7` (16 log entries, 13
  turns; median of 20 in-process runs, before = `f09ddff`, after = `5aadf0e`): turn loop **10.6 → 5.2 ms**; the
  whole in-process job (content index ~6 ms + battle setup ~2 ms + turn loop) **~19 → ~13 ms**. What remains per job:
  `ContentIndex` is built from scratch for every request (~6 ms, now the largest in-process cost) and headless process
  startup (~1 s if the worker launches one per battle) dwarfs everything. If load shows verifier CPU matters, in this
  order: (1) keep warm verifier processes that take many jobs and reuse one `ContentIndex` per ruleset (no contract
  change); (2) faster canonical text for the one final hash (cache unchanged units' lines; `hash-v1` output
  unchanged).

### 9. `ruleset-versioning` (later milestone)
Multiple verifier versions; jobs routed by `ruleset_version`. **Scenario 6** (ruleset changes while a battle is open).

> 🎨 Suggested design break 4, polish: UI, audio, balance pass. Safe to rebalance freely once slice 9 lands.
