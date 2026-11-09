# Spec: card-collection (slice 5)

Status: **spec written 2026-11-09, review answers applied 2026-11-09 (section 8); the pity numbers are still to be discussed and tuned.** Builds on `specs/economy-rewards.md` (the economy module, the
wallet and ledger, versioned server-owned rules), `specs/settlement-outbox.md` (outbox, wallet), `specs/run-verify.md`
(the run's start inputs live on `runs`; the genesis step rebuilds the start from them) and the roadmap entry "5.
`card-collection`" (the decisions of 2026-11-09 are the requirements; this spec makes them buildable). The screens are
slice 5b `card-ui`; the numbers (odds, prices, dust rates, which cards are core after the retune) are slice 5c
`card-balance`. This slice ships the mechanism with **placeholder numbers** in a seed file.

## 1. Purpose & enterprise mapping

**Purpose.** Hearthstone-style collecting. **All currency and all card ownership live on the server**: Godot holds neither,
never writes them, and only receives the run's pool. Every playable character and every item or piece of equipment that spawns
from a room pool is a **card**. A player's **account collection** is a *set* of cards (owned once; a duplicate is
auto-dusted on arrival). A **core set** is owned by everyone, always in the pools, never dusted, crafted or packed.
**Gems** (from slice 4c's completion marks) buy **packs**; **dust** comes only from dusting cards (duplicates included)
and buys **crafts**. The run is built from the account: the party must be unlocked characters, and the item pool of a
run is the core set plus the cards owned **when the run started**. Cards owned before the run started cannot be dusted
until the run ends (the **run lock**).

What this slice builds:
1. **Card catalog** (what a card is): generated from Godot content by a tool, seeded into Postgres. The server never
   reads item data; it knows id, kind, rarity, set, core flag and room pools as opaque catalog rows.
2. **Account state:** `card_holdings` (a set, one acquisition time per card), an append-only `card_ledger`, dust as a
   second currency next to gems, in the existing wallet and wallet ledger.
3. **Server-owned rules, versioned like reward rules:** pack types (price, odds, card sets) and card rates (dust value
   and craft cost per rarity). Retuning never changes the ruleset version.
4. **Account actions** (blocking, idempotent by request key): open a pack, dust a card, craft a card; each is one
   Postgres transaction with its ledger rows and an outbox event.
5. **Run integration:** the run start validates the party against the account, snapshots the item pool onto the run,
   and the pool becomes a verified input (run hash, step request). Godot filters pool-drawn picks by it.
6. **Content support (Godot):** card set tags, the catalog export, a core-selection pass, validator
   rules.
7. **Reading:** catalog, collection and pack list endpoints; Redis only for the two catalog caches.

**Components used** (from `README.md`):

| Component | Role in this slice | Enterprise analogue |
|---|---|---|
| ASP.NET Core API | Account endpoints, admin rule endpoints, run-start pool snapshot, run abandon | Account/entitlements service |
| PostgreSQL | Source of truth: catalog, holdings, both ledgers, pack openings (with RNG seed), rules, request log | Managed Postgres, append-only ledgers |
| Outbox → Redpanda | `PackOpened`, `CardDusted`, `CardCrafted` and rule-change events for analytics (4b) | Transactional outbox, Kafka |
| Redis | Catalog caches only (`catalog:cards`, `catalog:packs`); never ownership, never currency | Cache-aside reference data |
| Verifier worker / headless Godot | Reads the run's pool from `runs` as a step input; a pool the client did not receive fails the run hash | Versioned calculation worker |
| Prometheus / OpenTelemetry | Pack, dust and craft counters, dust faucet/sink, refusals, durations | GUTS metrics, tracing |

**Not used here:** RabbitMQ (account actions are synchronous; no job), SignalR (7), trading between players (removed),
real money, the screens (5b). Godot never writes the account: it reports nothing about
cards and receives the pool.

**Acceptance scenarios covered:** 1 (a duplicate request key → one purchase / dust / craft), 2 (an API crash after the
commit and before the response → the retry returns the stored result, no double spend), 3 (Redpanda down → the card
events drain after it is back), 4 (Redis flushed → the catalog reads fall back to Postgres), 5 (a tampered start: a pool
the server did not issue fails the run hash and the run is rejected with 2002, no rewards). 6 and 7 are not this slice.

## 2. Sequence flow

### 2.1 Catalog (content → server)

```
Developer/Claude: godot game/tools/build_card_catalog.tscn   → infra/economy/card_catalog.json
   (reads content/: every item or equipment with a Pool.* tag, every character; tags Card.Set.*, Item.Rarity.*, Pool.*;
    catalogHash = SHA-256 of the canonical card list)
API startup: CardCatalogSeeder (Cards:CatalogFile)
   one transaction under an advisory lock:
     - insert cards not in the table; update rarity/set/pools of existing ones, bump catalog_version when the hash changed
     - REFUSE (startup fails, log names the card): a core card turned non-core (owners would silently lose it)
     - a card missing from the file: retired = true (stays owned and dustable, leaves packs and new pools)
     - upsert the rate and pack seeds (Cards:SeedFile) only for rarities / packs that have no row yet
   DEL catalog:cards, catalog:packs
```
Content and the server catalog can disagree between a content change and the next export. `tools/check_card_catalog.sh`
(a report for the user, **not a test**: system tests never depend on the user's content) lists the difference. A card
the server does not know is simply not in any pool the server issues; a card the server lists but content lacks is
ignored by Godot (it filters by what exists).

### 2.2 Open a pack

```
Godot client ── POST /api/v1/packs/{packId}/open  { requestKey }
  API, ONE transaction:
    1. pg_advisory_xact_lock(player)                      (serialises every account action and the run start)
    2. account_requests (player, requestKey): found → same kind and hash → return the stored response (200); different → 409 1407
    3. read the pack type's latest version and the card rates FROM POSTGRES (never the cache); retired / unknown → 404 1408
    4. wallet: gems >= price else 409 1402; debit (wallet_ledger -price, reason 'pack_open')
    5. draw_seed = 64 random bits (RandomNumberGenerator.GetBytes); read this player's pity counters for the pack (pack_pity,
       FOR UPDATE); draw N cards with the pack RNG and the pity rules (3.4, 3.4a); update the counters
    6. per drawn card: owned (holdings, or drawn earlier in this pack) or core?  →  duplicate:
           wallet_ledger +dust_value (reason 'duplicate', ref pack opening), no holding
       else holdings insert (acquired_at = now(), source 'pack'), card_ledger +1
    7. pack_openings row (draw_seed, pity_before, pack and catalog versions, result), account_requests row (the response)
    8. outbox: PackOpened (key = playerId)
  ◀── 200 PackOpenResponse                     DEL nothing in Redis (ownership and wallet are not cached; wallet:{id} is deleted)
```
`wallet:{playerId}` (slice 4's read cache) is deleted on every wallet change.

### 2.3 Dust a card

```
Godot client ── POST /api/v1/cards/{cardId}/dust  { requestKey }
  API, ONE transaction: advisory lock → account_requests check →
    card must be held (409 1406), not core (400 1404), and not locked by the run (below, 409 1403 with runId) →
    DELETE holding; card_ledger -1; wallet dust += dust_value(rarity, latest rate version); wallet_ledger row (rate version recorded);
    outbox CardDusted; account_requests row.
  ◀── 200 DustResponse
```
**Run lock** (decided 2026-11-09): the player's run with `status IN ('Active','Verifying')` (at most one is Active; a
won run stays `Verifying` until the verifier says Won, then the lock goes). A holding is locked when
`acquired_at <= runs.started_at` of that run. A card acquired after the start (a pack or a craft during the run) is not
locked and never affects the run. The lock never expires; an abandoned-by-idleness run keeps it until the player
cancels the run or starts another.

```
Godot client ── POST /api/v1/runs/{id}/abandon                    (new: the cancel path the 409 pop-up uses)
  API: the same code path "start a new run" already uses to abandon the previous one → status Abandoned, caches deleted,
       steps voided as today. Not a death: no event for analytics beyond the existing run-ended.
```

### 2.4 Craft a card

```
Godot client ── POST /api/v1/cards/{cardId}/craft  { requestKey }
  API, ONE transaction: advisory lock → request check →
    card known, not core, not retired (400 1404 / 404); not already owned (409 1405); dust >= craft_cost (409 1402);
    wallet dust -= cost (ledger row with rate version); holding insert (source 'craft'); card_ledger +1; outbox CardCrafted.
```
Crafting is allowed during a run. Any card in the catalog can be crafted whatever set it is from, so every card is
reachable without luck.

### 2.5 Run start with the account

```
Godot client ── POST /api/v1/runs  { rulesetVersion, runStructureId, characterIds }          (request unchanged)
  API, in the existing run-start transaction (the player's advisory lock is taken first):
    - Cards:Enabled false → exactly today's behaviour, no pool (CardPool absent)
    - unlocked characters = core characters + owned characters; any characterId not in it → 400 1409 CharacterLocked
    - item pool = core item cards + owned item cards that are not retired-and-unowned   → runs.card_pool (jsonb array, sorted)
    - the genesis outbox job and every step request take the pool from runs (run-verify 3.3 already reserved this row)
  ◀── 201 RunStartResponse { …, UnlockedCharacterIds, CardPool }
```
`GET /runs/{id}/resume` returns `CardPool` and `UnlockedCharacterIds` from `runs`; the pool is not in the snapshots.

**Godot side (the pool is a verified input).** `RunState.card_pool` is a set of content ids, or `null` (unrestricted;
local mode in this slice, so every golden is unchanged). It restricts only **picks from `Pool.*` queries** (item rooms,
shops, boss and Vault/Void rewards, chests, events that pick by pool tag). It never touches starting loadouts, items
named by id in an outcome, enemy drops, or boss mirrors. A pick that finds its filtered pool empty falls back as the
room already does for an empty pool. `card_pool=<sha256 of the sorted ids>` joins the run hash **only when the pool is
set**, so unset runs hash as before (`run-v2`, same rule as `floor_seeds`). `test_snapshot_fields_are_covered` gets the
new field. The verifier gives `StepRequest.Setup.CardPool` from `runs`; the step restores the claimed snapshot and a
different pool changes the hash → the existing `WrongSetup` mismatch, verdict 2002.

### 2.6 Reading

```
GET /api/v1/cards/catalog      → CatalogResponse         Redis catalog:cards (string, TTL 1 h, deleted by the seeder), Postgres on miss or error
GET /api/v1/packs              → PackListResponse         Redis catalog:packs (string, TTL 1 h, deleted by an admin put), Postgres on miss or error
GET /api/v1/cards/collection   → CollectionResponse       Postgres only (holdings with each card's lock state, gems, dust)
```
Pack and rate **correctness reads never use the cache** (2.2 step 3): a stale price could sell below the current one.

### 2.7 Rules admin (no deploy)

```
PUT /api/v1/admin/pack-types    (economy-admin)  → new version of one pack type           + outbox PackTypeChanged
PUT /api/v1/admin/card-rates    (economy-admin)  → new version of one rarity's rates      + outbox CardRatesChanged
GET  of each (latest version per row)
```
Same mechanism as `reward_rules` (append-only versions, an advisory lock per source, latest-in-force lookup, role from
the dev-token endpoint in Development only, the `Economy:*` bounds). Validation: odds are whole numbers per 10000 and
sum to exactly 10000; `CardCount` 1..20; price 1..`Economy:MaxPackPrice`; `CraftCost > DustValue` for every rarity
(otherwise dust and craft loop for free). Retiring a pack type is `Retired = true` (new version).

## 3. Data contracts

### 3.1 C# records (`src/Rpg.Contracts/Cards/`)

```csharp
namespace Rpg.Contracts.Cards;

public static class CardKinds   { public const string Character = "character", Item = "item"; }     // equipment is an item card
/// <summary>Mythic is one tier above Legendary and is only for characters; items are Common..Legendary.</summary>
public static class CardRarities { public const string Common = "common", Rare = "rare", Epic = "epic", Legendary = "legendary", Mythic = "mythic"; }

/// <summary>One card of the catalog. DustValue / CraftCost are the rates in force when the response was built.</summary>
public sealed record CardDto(string Id, string Kind, string Rarity, string SetId, bool Core,
    IReadOnlyList<string> Pools, bool Retired, int DustValue, int CraftCost);

public sealed record CatalogResponse(int CatalogVersion, string CatalogHash, IReadOnlyList<CardDto> Cards);

public sealed record OwnedCardDto(string CardId, DateTimeOffset AcquiredAt, string Source, string? LockedByRunId);   // Source: pack | craft
/// <summary>Core cards are implied (everyone owns them) and not listed in Owned.</summary>
public sealed record CollectionResponse(IReadOnlyList<OwnedCardDto> Owned, int Gems, int Dust, long Version, string? ActiveRunId,
    string? ActiveRunStatus, IReadOnlyList<PityStateDto> Pity);   // ActiveRunStatus: Active | Verifying

public sealed record PackTypeDto(string PackId, string Name, int Version, int PriceGems, int CardCount,
    IReadOnlyDictionary<string, int> OddsPer10000, IReadOnlyList<string> SetIds, IReadOnlyList<string> CardIds,
    IReadOnlyDictionary<string, int> PityPacks, IReadOnlyDictionary<string, int> FirstGuarantees,   // spec 3.4a: rarity -> within N packs
    string? MinRarityPerPack);   // spec 3.4a: every pack holds at least one card of this rarity or better (seed: "rare")

/// <summary>The caller's counters for one pack type: packs opened since each tracked rarity last dropped.</summary>
public sealed record PityStateDto(string PackId, IReadOnlyDictionary<string, int> MissedPacks);
public sealed record PackListResponse(IReadOnlyList<PackTypeDto> Packs);

/// <summary>Body of open, dust and craft. The key is generated by the client per action and kept until it gets a response.</summary>
public sealed record AccountActionRequest(Guid RequestKey);

public sealed record PackCardDto(string CardId, string Rarity, bool Duplicate, int DustGained, bool Pity);   // Pity: this card was forced by a pity timer
public sealed record PackOpenResponse(string OpeningId, string PackId, int PackVersion, int GemsSpent,
    IReadOnlyList<PackCardDto> Cards, int Gems, int Dust, string DrawSeed);          // DrawSeed: decimal string (int64)
public sealed record DustResponse(string CardId, int DustGained, int RateVersion, int Dust);
public sealed record CraftResponse(string CardId, int DustSpent, int RateVersion, int Dust);

// Admin
public sealed record PackTypeRequest(string PackId, string Name, int PriceGems, int CardCount,
    IReadOnlyDictionary<string, int> OddsPer10000, IReadOnlyList<string> SetIds, bool Retired,
    IReadOnlyDictionary<string, int> PityPacks, IReadOnlyDictionary<string, int> FirstGuarantees, string? MinRarityPerPack);
public sealed record CardRateRequest(string Rarity, int DustValue, int CraftCost);
public sealed record CardRateResponse(string Rarity, int DustValue, int CraftCost, int Version, DateTimeOffset EffectiveFrom, string CreatedBy);
public sealed record CardRateListResponse(IReadOnlyList<CardRateResponse> Rates);
```
Additive changes to existing records (`WhenWritingNull`, so Cards-off responses are byte-identical):
`RunStartResponse` and `RunResumeResponse` gain `IReadOnlyList<string>? UnlockedCharacterIds` and
`IReadOnlyList<string>? CardPool`; `StepRequest.Setup` gains `CardPool`; `LedgerEntryDto.Currency` may now be `dust`.

Events (`Events/CardEvents.cs`, `DomainEvent<T>`, topic `rpg.economy.events`, key = playerId; the rule events key `rule:…`
as in 4c):
```csharp
public sealed record PackOpenedPayload(string OpeningId, string PlayerId, string PackId, int PackVersion, int GemsSpent,
    IReadOnlyList<PackCardDto> Cards, int DustGained, int NewCards, string DrawSeed, int CatalogVersion, int PityTriggers);
public sealed record CardDustedPayload(string PlayerId, string CardId, string Rarity, int DustGained, int RateVersion);
public sealed record CardCraftedPayload(string PlayerId, string CardId, string Rarity, int DustSpent, int RateVersion);
public sealed record PackTypeChangedPayload(string PackId, int Version, int PriceGems, bool Retired, string ChangedBy);
public sealed record CardRatesChangedPayload(string Rarity, int DustValue, int CraftCost, int Version, string ChangedBy);
```
`EventTypes` gains the five names.

Error codes (`ApiErrors`, new range 14xx; plain request errors, not verdicts):

| Code | Name | HTTP | Meaning |
|---|---|---|---|
| 1401 | CardRuleInvalid | 400 | Admin put: bad odds sum, unknown rarity or set, `CraftCost <= DustValue`, amount out of range |
| 1402 | InsufficientCurrency | 409 | Not enough gems (pack) or dust (craft) |
| 1403 | CardLockedByRun | 409 | Dust refused; the problem carries `runId` and `runStatus` (Active: the pop-up offers to cancel it; Verifying: it says to wait for the verdict) |
| 1404 | CardNotCollectible | 400 | Unknown card, or a core card (cannot be dusted or crafted) |
| 1405 | CardAlreadyOwned | 409 | Craft of a card already held |
| 1406 | CardNotOwned | 409 | Dust of a card not held |
| 1407 | RequestKeyReused | 409 | The key was used for a different action or body |
| 1408 | PackUnavailable | 404 | Unknown or retired pack type |
| 1409 | CharacterLocked | 400 | Run start with a character the account does not own |
| 1410 | RunVerifying | 409 | Abandon refused: a won run is waiting for its verdict and cannot be cancelled |

### 3.2 PostgreSQL: `Migrations/0008_cards.sql`

```sql
CREATE TABLE cards (
  card_id text PRIMARY KEY, kind text NOT NULL CHECK (kind IN ('character','item')),
  rarity text NOT NULL CHECK (rarity IN ('common','rare','epic','legendary','mythic')),
  set_id text NOT NULL, core boolean NOT NULL DEFAULT false, pools text[] NOT NULL DEFAULT '{}',
  retired boolean NOT NULL DEFAULT false, catalog_version int NOT NULL);
CREATE TABLE catalog_versions (catalog_version int PRIMARY KEY, catalog_hash text NOT NULL UNIQUE, created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE card_holdings (
  player_id uuid NOT NULL REFERENCES players, card_id text NOT NULL REFERENCES cards,
  acquired_at timestamptz NOT NULL DEFAULT now(), source text NOT NULL CHECK (source IN ('pack','craft')),
  PRIMARY KEY (player_id, card_id));                              -- a set: owned once
CREATE TABLE card_ledger (                                        -- append-only; holdings must equal its sum per (player, card)
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, player_id uuid NOT NULL REFERENCES players, card_id text NOT NULL REFERENCES cards,
  delta smallint NOT NULL CHECK (delta IN (1,-1)), reason text NOT NULL CHECK (reason IN ('pack','craft','dust')),
  ref_id text, idempotency_key text NOT NULL UNIQUE, created_at timestamptz NOT NULL DEFAULT now());

ALTER TABLE wallets ADD COLUMN dust int NOT NULL DEFAULT 0 CHECK (dust >= 0);
ALTER TABLE wallet_ledger DROP CONSTRAINT wallet_ledger_currency_check;      -- name checked at build time
ALTER TABLE wallet_ledger ADD CONSTRAINT wallet_ledger_currency_check CHECK (currency IN ('gems','dust'));
ALTER TABLE wallet_ledger ADD COLUMN rule_ref text;                          -- 'pack:{id}:{v}' or 'rate:{rarity}:{v}' (rule_version stays for rewards)

CREATE TABLE pack_types (pack_id text NOT NULL, version int NOT NULL, name text NOT NULL, price_gems int NOT NULL CHECK (price_gems > 0),
  card_count int NOT NULL CHECK (card_count BETWEEN 1 AND 20), odds jsonb NOT NULL, set_ids text[] NOT NULL, retired boolean NOT NULL DEFAULT false,
  pity jsonb NOT NULL DEFAULT '{}', first_guarantees jsonb NOT NULL DEFAULT '{}', min_rarity text,
  effective_from timestamptz NOT NULL DEFAULT now(), created_by text NOT NULL, PRIMARY KEY (pack_id, version));
CREATE TABLE card_rates (rarity text NOT NULL, version int NOT NULL, dust_value int NOT NULL CHECK (dust_value > 0),
  craft_cost int NOT NULL, effective_from timestamptz NOT NULL DEFAULT now(), created_by text NOT NULL,
  PRIMARY KEY (rarity, version), CHECK (craft_cost > dust_value));

CREATE TABLE pack_pity (player_id uuid NOT NULL REFERENCES players, pack_id text NOT NULL, rarity text NOT NULL,
  missed int NOT NULL CHECK (missed >= 0), PRIMARY KEY (player_id, pack_id, rarity));   -- spec 3.4a; a row appears at a player's first open of the pack
CREATE TABLE pack_openings (opening_id uuid PRIMARY KEY, player_id uuid NOT NULL REFERENCES players, pack_id text NOT NULL, pack_version int NOT NULL,
  catalog_version int NOT NULL, draw_seed bigint NOT NULL, pity_before jsonb NOT NULL, result jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE account_requests (player_id uuid NOT NULL REFERENCES players, request_key uuid NOT NULL, kind text NOT NULL CHECK (kind IN ('pack','dust','craft')),
  request_hash text NOT NULL, response jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (player_id, request_key));

ALTER TABLE runs ADD COLUMN card_pool jsonb;   -- null = card system off for this run; written at run start, never updated
```
The ledger idempotency keys are `pack:{playerId}:{requestKey}[:{n}]`, `dust:…`, `craft:…`: a second line of defence behind
`account_requests`. Existing rows are untouched (additive migration, the wallet's `gems` column and ledger keep working).
Card ids are content ids; retention for `pack_openings` and `account_requests` joins slice 7b.

### 3.3 Redis

| Key | Value | TTL | Rules |
|---|---|---|---|
| `catalog:cards` | `CatalogResponse` JSON | 1 h | Deleted by the seeder and by a card-rate put. Miss or any Redis error → Postgres |
| `catalog:packs` | `PackListResponse` JSON | 1 h | Deleted by a pack-type put and by the seeder. Same fallback |
| `wallet:{playerId}` | existing slice 4 key | existing | Now also deleted on every pack, dust and craft |

No locks: serialisation is the Postgres advisory lock `pg_advisory_xact_lock(hashtextextended('acct:'||player, 0))`,
taken by the three actions and by the run start, in that order of acquisition only (it is the sole lock, no deadlock).

### 3.4 The pack RNG (server-owned, separate from combat RNG)

Not Godot's RNG: pack opening is economy, not combat. Integer-only **SplitMix64** seeded with `draw_seed`:
`state += 0x9E3779B97F4A7C15; z = state; z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) * 0x94D049BB133111EB; return z ^ (z >> 31)` (unsigned wrap).
For each of the `CardCount` slots: draw `r = next() % 10000`, walk the rarities in the fixed order common, rare, epic, legendary, mythic
over the cumulative odds to pick the rarity (a rarity with 0 odds only ever comes from pity); draw `next() % n` to pick uniformly among the eligible cards of that rarity,
sorted by id. **Eligible** = catalog at the opening's `catalog_version`, set in the pack's `set_ids`, not core, not
retired. Legendary draws cover Legendary items; Mythic draws cover characters (the only Mythic cards). A rarity with zero eligible cards re-draws the rarity
with that rarity's odds removed (renormalised by the same walk over the remaining cumulative range). Modulo bias is below
10⁻¹⁵ and accepted. Because the seed, pack version and catalog version are stored, an audit re-derives any opening byte for
byte (`PackDrawer` is a pure function and has golden vectors). Draws are **independent of what the player owns**: a
duplicate is detected after the draw and auto-dusted.

### 3.4a Pity timers (Hearthstone's, researched 2026-11-09; the numbers are placeholders to tune)

What Hearthstone does (community-measured and Blizzard-quoted; sources: hearthstone.wiki.gg "Pity Timer" and "Card pack
statistics", esports.gg "Hearthstone pity timer", cardgamer.com): a **legendary is guaranteed within 40 packs** (sources
differ by one on whether the 40th or the 41st pack is the guaranteed one), an **epic within 10 packs**, a **new set
guarantees one legendary within its first 10 packs**, the timers are **kept per set** and **reset when that rarity drops
by any means**. Golden versions have their own, much longer timers (361 packs legendary, 142 epic; sources disagree on the
golden legendary) and are out of scope: we have no golden cards. The pity can hand you a card you already own.

What we build, the same shape with our own rarities:
- A pack type carries `PityPacks`: rarity → N. `N = 0` or absent means no timer. **The Nth pack opened since that rarity last
  dropped contains at least one card of that rarity** (so N = 20 means at most 19 misses, then a guaranteed pack). Decided
  2026-11-09: `legendary` **20** (Hearthstone has 40; halved on purpose), `mythic` **30** (Mythic has no Hearthstone
  equivalent), `epic` **10** (Hearthstone's number).
- `FirstGuarantees` (rarity → within N packs; decided 2026-11-09: `mythic` **15**, i.e. a character card within a new
  set's first 15 packs; `legendary` **10** (Hearthstone's rule); `epic` **5**): on a player's **first open of a pack type**,
  the counter for each such rarity starts at `pity - within` misses (Mythic: 30 - 15 = 15; Legendary: 20 - 10 = 10; Epic: 10 - 5 = 5), so the
  guarantee lands by the `within`-th pack, exactly Hearthstone's "set the timer to 10". A rarity needs a `PityPacks` entry
  to have a first guarantee, and `within <= pity`. Nothing changes afterwards: the next guarantee is the normal timer.
- **Counters** live in `pack_pity`, per (player, pack type, rarity): `missed` = packs opened without that rarity. Hearthstone
  keeps them per set; our pack types are per set, so the pack type is the scope.
- **Resolution** (inside the draw, deterministic): draw the N slots as in 3.4. Then for each tracked rarity from the highest
  to the lowest, if `missed + 1 >= N` and the pack holds no card of that rarity, **force one**: it replaces the pack's
  lowest-rarity slot not already forced (ties: the last slot), and its card is drawn from the same SplitMix64 stream
  (uniform among the eligible cards of that rarity, as in 3.4). Flag `Pity = true` on that `PackCardDto`.
- **Rare guarantee** (`MinRarityPerPack`, Hearthstone's "every pack holds a Rare or better"; decided 2026-11-09, seed `rare`),
  applied **after** the pity step: if no card in the pack is of that rarity or better, the pack's last slot not forced by
  pity is redrawn from the same stream among that rarity and above, with the pack's odds restricted to those rarities
  (renormalised, Rare 78.85%, Epic 16.13%, Legendary 3.58%, Mythic 1.43% at the seed odds). Not flagged as pity. It counts as
  a natural drop for the counters (a redraw that lands on an Epic resets the Epic counter). A pack type may leave it unset.
  Validation: the rarity is one of the five, and the pack's odds give it at least one rarity at or above it with odds above 0.
- **Counter update** after resolution: for each tracked rarity, `missed = 0` if the pack holds a card of exactly that rarity
  (natural or forced), else `missed + 1`. A Mythic does **not** reset the Legendary counter (open question 8.1).
- Ownership is ignored: a forced card can be a duplicate and is auto-dusted like any other (a pity pull is never wasted
  entirely, it pays dust). This keeps the draw a pure function of (seed, pack version, catalog version, counters).
- Audit: `pack_openings.pity_before` stores the counters used, so the opening is reproducible byte for byte.
- The counters are readable (`CollectionResponse.Pity`) so the UI (5b) can show "legendary guaranteed in N packs", as
  Hearthstone's client cannot but players track it.

### 3.4b Seed numbers (`infra/economy/card_economy.json`; matched to Hearthstone, 2026-11-09; the gem price is 5c)

| Rarity | Craft (dust) | Dust back | Per-card odds | Chance a 5-card pack holds one |
|---|---|---|---|---|
| Common | 40 | 5 | 72.10% (7210) | n/a |
| Rare | 100 | 20 | 22.00% (2200) | 86.5% (71.1% before the Rare guarantee) |
| Epic | 400 | 100 | 4.50% (450) | 23.7% (20.6% before the guarantee; Hearthstone: 21% official) |
| Legendary | 1600 | 400 | 1.00% (100) | 5.60% (about 1 in 17.9 packs; 4.90% before the guarantee; Hearthstone: 1 in 20 official) |
| Mythic | 3200 | 800 | 0.40% (40) | 2.26% (about 1 in 44 packs; 1.98% before the guarantee) |

The guarantee fires in the 19.5% of packs that would be all Common (0.721^5) and lifts every rarity above Common by
the amounts shown; 5c can lower the natural Epic odds if the real rate should stay at Hearthstone's 21%. Pity: Epic 10, Legendary 20, Mythic 30; first packs of a pack type: Epic within 5, Legendary within 10, Mythic within 15. `CardCount` 5, `MinRarityPerPack` `rare` and a
placeholder price of 100 gems (5c sets real prices against the gem income). Craft is four times the dust value for every
rarity, as Hearthstone's. The Hearthstone per-card odds are community-measured (Common about 71%, Rare 23%, Epic 4.3%,
Legendary 1.3%); Blizzard publishes only per-pack averages. Pity pulls make the real Legendary and Mythic rates higher than
the natural ones (the timers fire in a share of packs), which 5c measures.

### 3.5 Configuration (`Cards:*`)

`Cards:Enabled` (default true; false = the run start ignores the account, no pool, the character check is off, so the
existing e2e scenarios run unchanged; the new card scenarios run with it on over the **card fixtures**, 3.6), `Cards:CatalogFile` (`infra/economy/card_catalog.json`),
`Cards:SeedFile` (`infra/economy/card_economy.json`: placeholder rates and one pack per set, flagged as placeholders for 5c),
`Economy:MaxPackPrice`, `Economy:MaxCardCost` (both Development defaults 100000).

### 3.6 Godot side

- Tags (`godot_gas/`, the user's folder: the tags are **proposed, applied after approval**): `Card.Set.Core`,
  `Card.Set.Descent` (every other demo card), future `Card.Set.<Name>` per expansion, and `Card.Rarity.Mythic` for
  characters (item rarity keeps `Item.Rarity.*`). Existing item and character files
  gain one set tag each; they are the user's, so the pass writes a proposal (3 below) and applies it only on `--apply`
  after the user's OK.
- `CardRules` resource (`game/defs/`): `pool_targets` (`Pool.Treasure` 30, `Pool.Shop` 30, `Pool.Vault` 15, `Pool.Void` 15)
  and `all_core_pools` (`Pool.Boss`, `Pool.Void`); one instance in `content/demo/cards/`.
- **Card fixtures** (`tests/fixtures/cards/`, built by a builder that only adds missing files like the other fixtures): a small
  fixture set with two sets (core and one expansion), characters of every card rarity incl. one Mythic, items of every rarity
  in every pool, a pool deliberately short of its target, and a matching fixture `card_catalog.json`. The new Godot tests,
  the .NET tests (as the seeded catalog) and the new e2e scenarios use these, never the demo content.
- **Run-end gate (client):** in server mode, while a won run is `Verifying` the run-end screen shows "Verifying run…" and
  offers no way back to the main menu or to a new run; it leaves only on the server's verdict (Won, or Rejected and the run
  is rebuilt from the rollback). Closing the app is allowed; Continue after a restart returns to the same screen. This is a
  client rule matched by the server's (the lock in 2.3 holds and `abandon` of a Verifying run is refused with 1410).
- **Local mode** has no account: no wallet, no gems, no dust, no ownership, and nothing is ever stored as if owned. For testing
  and design work a **local test collection** can be configured: the console command `cards local core|all|<id> …` (and a
  Settings key `local_cards`) sets `RunState.card_pool` for local runs only. It is not synced, rewards nothing and cannot
  reach a server run.
- `game/tools/build_card_catalog.tscn` (exports the catalog, 2.1), `game/tools/build_card_pass.tscn` (the proposal below),
  `RunState.card_pool`, `RunController.start_server_run(…, card_pool)`, `ServerBridge` + `Rpg.Client` methods for the endpoints,
  console commands (dev-tools parity): `cards` (collection), `packs`, `open <pack>`, `dust <card>`, `craft <card>`,
  `abandon`, `pity` (the counters), and admin `server pack-type …` / `server card-rate …` (the `reward` pattern).
- Validator (`UIPolicyCheck`-style rules): `card_set_missing` (a card with a pool tag and no set), `card_set_unknown`,
  `core_pool_empty` (**error**: a room pool tag used by a room with no core card in it, the invariant that pools are never
  empty), `core_pool_short` (warning: under its target), `card_rarity_mismatch` (a character not Mythic, or an item Mythic),
  `core_character_count` (error: the core set must hold exactly 6 characters); `core_not_in_catalog` is a tool report.

**Core selection (the proposal pass, deterministic).** Targets above; Boss and Void are all core; items whose only pools
are `Pool.Food` / `Pool.Chest` are core (those pools have no minimum and must never be empty); items with no pool tag are
not cards. Food holds four items today and all four are core; **four more Food items are made later, in the 5c
content/balance pass (decided 2026-11-09)**, not in this slice. Then, until every target pool is met: sort the remaining items by (rarity ascending Common→Legendary, number of
target pools still short descending, id ascending) and take the first item that belongs to at least one short pool. An item
counts in every pool it carries, so overshoot is possible and reported. The pass reports per-pool core counts, the list of
core ids. Vault holds ten items today, so until 5c adds five more all ten are core and the pass reports Vault
as short of its 15 (the `core_pool_short` warning, expected).

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| F1 | Same `requestKey`, same action and body, again (client retry, timeout) | Returns the stored response, 200, nothing changes (scenario 1) | `OpenPack_Replayed_SpendsOnce`, `Dust_Replayed_PaysOnce`, `Craft_Replayed_ChargesOnce` |
| F2 | Same key, different pack, card or kind | 409 1407, nothing changes | `RequestKey_ReusedForOtherAction_Rejected` |
| F3 | API dies after the commit, before the response | The client retries with the same key → F1 (scenario 2) | `OpenPack_ConnectionKilledAfterCommit_RetryReturnsSameCards` |
| F4 | Two opens at once with gems for one | The advisory lock serialises; the second gets 409 1402; wallet never negative | `OpenPack_Concurrent_NeverOverdraws` |
| F5 | Dust or craft with too little currency | 409 1402, no change | `Craft_NotEnoughDust_Rejected` |
| F6 | Dust a core card, an unknown card, a card not held | 400 1404 / 409 1406 | `Dust_Core_Refused`, `Dust_NotOwned_Refused` |
| F7 | Dust a card acquired before the run started | 409 1403 with the run id; nothing changes; passes after `abandon`, after Lost, after Won | `Dust_LockedByActiveRun`, `Dust_FreedWhenRunEnds`, `Dust_AfterAbandon_Succeeds` |
| F8 | Dust a card acquired after the run started | Allowed (never in that run's pool) | `Dust_AcquiredAfterRunStart_Allowed` |
| F9 | Dust races a run start | The advisory lock orders them: either the run snapshots the card and it is then locked, or the dust wins and the card is not in the pool | `RunStart_ConcurrentWithDust_PoolMatchesHoldings` |
| F10 | A duplicate in a pack, or two of the same card in one pack | Auto-dusted at the card's dust value, never a second holding; works during a run and never touches the locked copy | `Pack_Duplicate_AutoDusted`, `Pack_SameCardTwice_OneHolding` |
| F11 | Craft a card already held | 409 1405 | `Craft_Owned_Refused` |
| F12 | Run start with a locked character | 400 1409, no run created | `RunStart_LockedCharacter_Refused` |
| F13 | A client plays with a pool the server did not issue (tampered start) | The run hash differs → the step fails `WrongSetup`, verdict 2002, rollback as today (scenario 5) | `step_rejects_foreign_pool` (Godot), `verify_pool_tampered` (e2e) |
| F14 | Redis down or flushed | Catalog reads fall back to Postgres; opens never read the cache (scenario 4) | `Catalog_RedisFlushed_ReadsPostgres`, `OpenPack_RedisDown_Works` |
| F15 | Redpanda down | Account actions still commit; their outbox rows drain after it is back, none lost (scenario 3) | `CardEvents_RedpandaDown_DrainAfterRestart` (real Redpanda, `docker pause`, like `WalletTests`) |
| F16 | Postgres unreachable | 503 ProblemDetails as every other endpoint | `AccountEndpoints_PostgresDown_503` |
| F17 | Content and server catalog disagree (a new item not yet exported) | The item is not in any issued pool; `check_card_catalog.sh` reports it | script check, no test |
| F18 | Seed demotes a core card | The API refuses to start, naming the card | `Seeder_CoreDemotion_FailsStartup` |
| F19 | Admin puts invalid rules | 400 1401 (odds not 10000, `CraftCost <= DustValue`, unknown set); non-admin 403 1302 | `PackType_Put_Validates`, `CardRates_Put_RequiresAdmin` |
| F20 | A pack is retired while a client holds its old listing | Open returns 404 1408 | `OpenPack_Retired_404` |
| F22 | Pity timer reaches N | The Nth pack since the last drop holds that rarity, forced into the lowest slot; counters reset; a replayed open does not move the counters twice | `Pity_GuaranteedAtN`, `Pity_ResetsOnNaturalDrop`, `Pity_Replay_CountsOnce`, `Pity_ScopedPerPack`, `FirstGuarantees_LandWithinN`, `Pity_ForcedCardDuplicate_AutoDusted` |
| F25 | A pack with no Rare or better | The last unforced slot is redrawn among Rare and above; a pack is never all Common; the redraw is deterministic from the seed | `Pack_NeverAllCommon`, `RareGuarantee_RedrawsLastUnforcedSlot`, `RareGuarantee_ResetsExactRarityCounter` |
| F23 | Abandon a Verifying run | 409 1410; the lock stays until the verdict | `Abandon_Verifying_Refused` |
| F24 | Client tries to leave the main menu while its run is Verifying | The UI offers no way out; restart returns to the same screen | `test_run_end_gate` (Godot) |
| F21 | An open pack's price changes between the listing and the open | Price in force at the transaction is charged and returned in `GemsSpent` | `OpenPack_PriceChanged_ChargesCurrent` |

No dead-letter handling: no queue. Redelivery does not exist here; retries are the client's, made safe by the request key.

## 5. Observability

Prometheus (no card or character ids as labels; `pack` is a configured pack id, a bounded set):
- `rpg_packs_opened_total{pack}`; `rpg_pack_cards_total{rarity,duplicate}`
- `rpg_cards_dusted_total{rarity}`, `rpg_cards_crafted_total{rarity}`
- `rpg_gems_spent_total{reason="pack"}`; `rpg_dust_total{direction="in|out",reason="duplicate|dust|craft"}` (faucet and sink; the Grafana panel shows the ratio)
- `rpg_card_actions_refused_total{action,reason}` (`reason` = the error name: InsufficientCurrency, CardLockedByRun, …)
- `rpg_account_request_replays_total{action}` (F1 working)
- `rpg_account_action_duration_seconds{action}` histogram (the whole transaction)
- `rpg_card_catalog_reads_total{source="redis|postgres"}`, `rpg_card_rule_changes_total{kind="pack|rate"}`
- `rpg_cards_owned_total` gauge (rows in `card_holdings`, sampled by the monitor every `Monitors:Interval`)

Traces: one span per account action with `player.id`, `pack.id`, `request.replay`; the outbox row carries `traceparent` (slice 4c).
Grafana: a "Card economy" row (packs per minute, dust faucet/sink, refusals by reason, action latency). Metrics are
named in `Observability/RpgMetrics.cs` with the others.

## 6. Test plan

**.NET (`tests/Rpg.GameServerApi.Tests`, Testcontainers; Docker required)** — every row of section 4, plus:
- `PackDrawerTests` (pure): Rare-guarantee vectors (all-common natural draw → redrawn slot, conditional odds, a pack that already holds a Rare is untouched, interplay with a pity-forced slot), 100 000 packs at a fixed seed never all Common and the per-pack chances of 3.4b within ±1%; pity golden vectors (counters in → exact pack out, with forced slots and flags), two guarantees
  in one pack (Mythic and Legendary) take distinct slots, counter update rules, `FirstGuarantees` start values; golden vectors (fixed seed → exact rarity and card sequence for a fixture catalog and pack),
  SplitMix64 first outputs pinned, rarity-empty re-draw, 100 000 draws at a fixed seed within ±2% of the odds,
  independence from ownership, byte-identical re-derivation from a stored `pack_openings` row.
- Ledger invariants (a helper run after every test): `wallets.gems/dust` = sum of released ledger rows per currency;
  `card_holdings` = sum of `card_ledger` per (player, card) (always 0 or 1); every account action has exactly one outbox event.
- Rules: versions are append-only, the latest in force is used, a put never changes an existing ledger row.
- Run start: pool = core + owned (not owned-after), stored on `runs.card_pool`, returned on start and resume; Cards off →
  responses and behaviour equal today's (existing tests unchanged).
- Seeder: first run, re-run is a no-op, an added card, a retired card, a demotion refused, hash change bumps the version.
- Auth: every card endpoint 401 without a token; a player cannot read or change another's account.

**`Rpg.Contracts.Tests`:** golden JSON for every record in 3.1 and the five event payloads; additive fields absent when null
(a start response with Cards off equals today's golden); catalog export wire shape cross-checked against the Godot export
fixture (the `test_battle_facts` pattern); purity guard still passes (no game logic in Contracts).

**Godot (`client-godot/tests/`, fixtures only):**
- `test_run_end_gate`: a Verifying run offers no exit to the main menu or a new run, leaves on Won, and rebuilds on Rejected.
- `test_card_local`: `cards local` sets a pool for local runs, is never written to a server run or counted as ownership.
- `test_card_pool`: with `card_pool` set, shop / item room / boss / chest picks come only from it; with it `null`, every
  existing golden (floors, scripted run, keyed run) is unchanged; starting loadouts, named gifts, drops and mirrors ignore it;
  an empty filtered pool falls back.
- `test_run_authority` / `test_step_runner`: `card_pool=` joins the hash only when set; snapshot round trip and field coverage
  with the pool; a step with a different pool is rejected `WrongSetup`; resume with the pool from the server response.
- `test_card_catalog`: the export of a fixture content tree matches a committed JSON (golden), canonical hash stable under key order.
- `test_card_pass`: the core selection on a fixture item set reaches targets, takes lowest rarity first, breaks ties by
  shortfall then id, takes all of Boss and Void, never touches existing files without `--apply`.
- Validator: `card_set_missing`, `card_set_unknown` (broken fixtures), `core_pool_short` warning.
- Console commands: `cards`, `packs`, `open`, `dust`, `craft`, `abandon` against a fake bridge (the `test_server_mode` pattern).

**End to end (`tools/e2e.sh`, on demand):** `card_pack` (a boss win pays gems, the player opens a pack, the collection and the
wallet agree, the duplicate path pays dust), `card_run_lock` (dust refused during the run, passes after `abandon`),
`verify_pool_tampered` (a start with a foreign pool is rejected, nothing paid), `card_redpanda_down` (scenario 3).
`card_pity` (a fixture pack with a tiny timer guarantees a Mythic by the Nth pack, counters persist across a restart of the API). The new scenarios use the card fixtures with `Cards:Enabled=true`. Existing scenarios keep running with `Cards:Enabled=false`.

**Not a test:** `tools/check_card_catalog.sh`, the comparison of content against `card_catalog.json`.

## 7. Decisions, assumptions to confirm, and what stays out

**Decided by the roadmap (2026-11-09):** a card is owned once and a duplicate is auto-dusted; a core set every account owns;
sizes 30 / 30 / 15 / 15 with Boss all core, Void all core and five new Vault items; core picked by lowest rarity first;
craft any card for dust, dust pays a fraction of the craft cost; the run lock is removal-only, covers cards acquired
before the run started, never expires, and the player cancels the run from a pop-up; no trading.

**Decided with the user (2026-11-09, answers to the first review):**
1. **Local mode** has no account. Cards can be configured locally for testing (`cards local …`, 3.6), which only sets a pool;
   it is never ownership, currency or something a server run can see. In server mode **all currency and card ownership live on
   the server**. The default local pool stays "everything" in this slice, so goldens and the 31.8% gate are unchanged; the move
   to core-only is a change of default for 5c.
2. `Cards:Enabled=false` keeps the existing e2e scenarios as they are, and the card mechanics get **new fixtures**
   (`tests/fixtures/cards/`, 3.6) with their own tests and e2e scenarios.
3. The core set has **6 starter characters**.
4. Food/Chest-only items are core, the 4 existing Food items are core and **four more Food items are made in the 5c content/balance pass**, and the invariant "no room pool is
   ever empty" is a validator **error**, not a warning.
5. **Characters are a rarity tier above Legendary: Mythic** (items stay Common..Legendary). The name is mine; rename freely.
6. **Pity timers like Hearthstone's**, for Epic, Legendary and Mythic; researched figures and the mechanism
   are in 3.4a, the numbers are placeholders to discuss.
7. A **won run that is Verifying keeps the lock and the client cannot return to the main menu** until the server accepts the
   run; the abandon of a Verifying run is refused (1410).
8. **Equipment is a card** (an item card); items with no pool tag are not cards.
9. **Pack RNG is a server-side integer SplitMix64**, seed and versions stored per opening.
10. **Cancel run** is a new `POST /runs/{id}/abandon`, reusing the abandon path of "start a new run".

**Stays out:** trading and any market, golden cards (and so their long pity timers), bundles and real-money purchase,
pack-opening animation and every screen (5b), the balance retune and real numbers (5c), expansion sets themselves (only
the tag and per-set packs work), card-based analytics projections (4b consumes the events), retention of `pack_openings`,
`pack_pity` and `account_requests` (7b).

## 8. Open items for the next review

1. **Does a Mythic reset the Legendary counter?** Proposed: no (each rarity counts its own drops). The alternative is
   friendlier to players and cheaper for us to explain; it makes Legendary supply a little lower.
2. **Which 6 characters are core?** Proposed: Warrior, Cleric, Arcanist, Ranger, Bard, Bulwark (frontline, healer, magic damage,
   ranged damage, support, tank); the collectible five are Cryomancer, Pyromancer, Ember Knight, Shatterweaver, Plaguewright.
   Please confirm or name others. Core characters are never in packs, so the Mythic pool of a pack is those five.
3. **Pity and pack odds: final (2026-11-09)**, in 3.4a and 3.4b (including the Rare guarantee). Still to show the player: pity counters (the collection response carries them).
4. **New content moved to 5c (decided 2026-11-09)**: four more Food items and the five new Vault items (Vault 10 → 15) are
   made in the 5c content/balance pass, not here. Until then Vault is all core and 5 short of its target.
5. **Names: decided 2026-11-09**: the rarity above Legendary is `Mythic`; the second set tag is `Card.Set.Descent`.
6. **Dust and craft values: set to Hearthstone's** (3.4b), Mythic at twice Legendary (craft 3200, dust 800).
