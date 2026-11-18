# Spec: pack-shop (slice 5b0)

Status: **spec written 2026-11-15, awaiting implementation.** Split out of `specs/card-ui.md` at the user's request: "just like in
Hearthstone there is a separate buy menu to buy cards. Once cards are purchased you can see how many you have on the card opening
page". Builds on `specs/card-collection.md` (slice 5: the account transaction, request keys, pity, the pack RNG, the 14xx errors).
The screens (Shop, Open packs) are slice 5b `card-ui`; this slice is the server half, the client calls and a console command.

## 1. Purpose & enterprise mapping

**Purpose.** Today `POST /packs/{packId}/open` charges the pack's price in gems at the moment of opening. Hearthstone separates the
two: packs are **bought** in a shop and **owned unopened**, and opening spends one owned pack. This slice makes that the rule:
1. The account holds a **count of unopened packs** per pack type, with an append-only ledger of every buy (+n) and open (-1).
2. **`POST /api/v1/packs/{packId}/buy`** spends gems for 1 to 10 packs, idempotent by request key, in the account transaction.
3. **`POST /api/v1/packs/{packId}/open`** spends one owned pack instead of gems (409 1411 when there is none); the draw, pity,
   duplicates and events are unchanged.
4. **`GET /api/v1/cards/collection`** lists the unopened packs.
5. Client: `Rpg.Client.BuyPackAsync`, `ServerBridge.BuyPack`, `ServerLink.buy_pack`; console `packs buy <pack id> [count] [key]`
   and the owned counts in `packs` / `cards`. No screens (5b).

**Components used** (from `README.md`):

| Component | Role in this slice | Enterprise analogue |
|---|---|---|
| ASP.NET Core API | The buy endpoint, the changed open, the owned packs in the collection | Entitlements service: purchase, then redemption |
| PostgreSQL | `pack_inventory` and `pack_ledger` written in the account transaction with the wallet ledger and the request log | Source of truth, append-only ledger |
| Outbox → Redpanda | `PackPurchased` beside `PackOpened` (for analytics, 4b) | Transactional outbox |
| Prometheus | Packs bought, packs owned, the new refusal reason | Business metrics |

**Not used here:** RabbitMQ, the verifier, Redis (the inventory is never cached; it is read with the collection from Postgres like
ownership), SignalR, the screens.

**Acceptance scenarios covered:** 1 (the same buy key twice → one purchase; the same open key twice → one opening), 2 (an API crash
after the buy's commit and before the response → the retry returns the stored response, gems spent once), 3 (Redpanda down while
buying → `PackPurchased` drains from the outbox after it is back). 4 (no Redis in this path), 5, 6 and 7 do not apply.

## 2. Sequence flow

### 2.1 Buy

```
Godot client ── POST /api/v1/packs/{packId}/buy  { requestKey, count, session, expectedAccountVersion }   (rate-limited as `actions`;
                                          since spec account-session: after step 2 and the count check, an older session → 409 1412,
                                          a moved account version → 409 1413, nothing written)
  API, ONE transaction (the slice 5 account shape):
    1. pg_advisory_xact_lock(acct:<player>)
    2. account_requests (player, requestKey): same kind and hash → return the stored response (200); different → 409 1407
    3. count 1..Cards:MaxPacksPerBuy (10), else 400 1401
    4. the pack type's latest version FROM POSTGRES; unknown or retired → 404 1408
    5. wallet gems >= price x count, else 409 1402; wallet_ledger -price x count, reason 'pack_buy'
    6. pack_inventory (player, pack) += count (upsert); pack_ledger +count, reason 'buy', pack_version, request_key
    7. outbox PackPurchased (key = playerId); account_requests row (the response)
  ◀── 200 PackBuyResponse { packId, packVersion, count, gemsSpent, gems, owned, accountVersion }     DEL wallet:v2:{playerId}
```
The price is fixed at the buy (the version bought is on the ledger row). A pack bought before a retirement still opens (2.2).

### 2.2 Open (changed from slice 5 2.2)

Slice 5's step 4, "wallet: gems >= price else 409 1402; debit", becomes:
```
    4. pack_inventory (player, pack) FOR UPDATE: count > 0 else 409 1411 NoPackOwned (nothing written, no pity change);
       count -= 1; pack_ledger -1, reason 'open', opening_id
```
The pack version used for the draw is the type's latest version, **retired or not**: an owned pack of a retired type still opens
with its last version. `404 1408` stays only for "nothing left to draw" (every card it could give retired), and then the pack stays
owned. Everything else is unchanged: pity, the Rare guarantee, duplicates to dust, `pack_openings`, `PackOpened`. The response's
`GemsSpent` is 0 and it gains `PacksLeft`.

### 2.3 Reading

`GET /api/v1/cards/collection` gains `OwnedPacks`: the player's `pack_inventory` rows with a count above 0, sorted by pack id (from
Postgres, inside the same read as the rest of the collection).

### 2.4 Existing accounts and gems

No migration of money: nobody owns a pack before this slice, so `pack_inventory` starts empty. The e2e scenarios and tests that
opened a pack with gems now buy one first.

### 2.5 Openability and retiring with a refund (added 2026-11-15, the user)

**One openability rule** (`CardRules.OpenProblem`): a pack can be opened when some rarity with odds above 0 still has an eligible
card (non-core, not retired, in its sets; the draw spreads the odds over the rarities that have cards), and every rarity it can
give (by its odds, a pity timer or a first-pack guarantee) has a card rate. It is checked when any pack-type version is saved,
**retired versions too** (owned packs open with the latest version), at the buy (404 1408, not sold) and at the open (404 1408,
the pack stays owned). Every pack holds 5 cards (`CardRules.CardsPerPack`; the user: "packs will always have 5 cards").

**Retire with a refund.** When a pack type has to go, the admin saves a retired version with `refundUnopened: true` (only valid on a
retired version, else 400 1401). Such a version skips the set and openability rules: nobody opens it, every unopened pack is
refunded. A retired version may also keep a pack size other than 5 within the old 1-20 bound (it is never sold, but owned packs
open with it), so an old pack type can always be retired.

**Pack types change only during maintenance** (the user, 2026-11-15: the server is taken down while card packs change). So there
is no background job and no polling: a player's refunds are settled **when they open the Open packs page** (the user: the one
place they look for their packs), for that player only, through its own call, so the page can say where the packs went:
```
Open packs page opens → POST /api/v1/packs/refunds { session } (rate limited as `actions`; 200 PackRefundsResponse {refunded: [{packId,
  count, gemsRefunded}]}, empty when nothing was due; the page shows "Your 3 Descent Packs were retired: +300 gems"). Since spec
  account-session: an older session → 409 1412 (checked up front and again in each pack type's transaction; refunds already paid are
  still reported); the answer carries no account version, so the page reads the collection after it; a hold raises the account version
  → PackRefunds.RefundAsync(player): the player's pack_inventory rows with count > 0, not held, whose type's latest
  version is retired with refundUnopened; for each, ONE transaction:
    1. pg_advisory_xact_lock(acct:<player>) and the shared lock on pack_type|<id> (the admin save holds it exclusively);
       re-read the latest version and the count (0: a second visit already paid; skip)
    2. amount = what the player paid for the packs left, by replaying the player's pack_ledger for the type in order: a buy
       joins the back of a queue at its version's price_gems, an open takes the oldest pack (first in, first out), a refund
       takes the packs it paid for (the newest); the n owned are the newest left in the queue. So a held refund cleared later,
       or a type refunded, un-retired, bought again and refunded again, pays only what is still owed, at what it cost.
       Units nothing prices (only a buy adds packs, so a damaged ledger) are never refunded for nothing nor taken away: the
       priced ones are paid, the rest stay in the inventory with pack_inventory.refund_held_version = this retirement's version
       (a support check); visits skip the row for that version until operations sets it back to NULL (a later retirement
       checks again); an error log and rpg_pack_refund_failures_total{pack,reason="held"} tell them
    3. pack_inventory count -= the units paid; pack_ledger -n, reason 'refund', request_key = a UUID derived from (player,
       pack, version, units refunded before)
       (unique on (player, reason, request_key): a second refund is impossible, and a player's own request keys never collide)
    4. wallet_ledger +amount, reason 'pack_refund', key 'pack_refund:<player>:<pack>:<version>:<refunded before>' (unique)
    5. outbox PackRefunded (key = playerId)
  then DEL wallet:v2:{playerId} (also after a hold). A pack type that fails is logged and tried again next time; it never stops the others.
```
Login and the collection read do not refund. Postgres is a hard dependency of the game (the user): with it down the login answers
503 (it checks the database) like every other endpoint. A refund that fails for one pack type (a data problem) is logged and tried
again on the next visit; the others are still paid. Until the player opens the Open packs page, an open of that pack is refused
(404 1408, "its gems come back on the Open packs page") and the pack stays owned.
**Held for a support check**, the collection lists the packs with `refundHeld: true` (`OwnedPackDto.RefundHeld`, left off the JSON
otherwise) and the open refusal says the refund needs a support check, so the player is never told to wait for gems that will not
come on their own.
A type un-retired in the same maintenance window, before the player signs in, is not refunded.

## 3. Data contracts

### 3.1 C# records (`src/Rpg.Contracts/Cards/`, additive; `WhenWritingNull`)

```csharp
/// <summary>Body of POST /packs/{packId}/buy. Count 1..10 (Cards:MaxPacksPerBuy).</summary>
public sealed record PackBuyRequest(Guid RequestKey, int Count, long? Session, long? ExpectedAccountVersion);   // the last two: spec account-session 3.1
public sealed record PackBuyResponse(string PackId, int PackVersion, int Count, int GemsSpent, long Gems, int Owned, long AccountVersion);
    // Gems: wallets are 64-bit (0010); AccountVersion: spec account-session 3.1

/// <summary>Unopened packs the player owns, per pack type (0 counts are left out).</summary>
public sealed record OwnedPackDto(string PackId, int Count);
// CollectionResponse gains:  IReadOnlyList<OwnedPackDto> OwnedPacks   (an empty list when none)
// PackOpenResponse  gains:   int PacksLeft                             (GemsSpent stays on the record and is 0)
```
Event (`Events/CardEvents.cs`, topic `rpg.economy.events`, key = playerId; `EventTypes.PackPurchased`):
```csharp
public sealed record PackPurchasedPayload(string PlayerId, string PackId, int PackVersion, int Count, int GemsSpent);
```
`PackOpenedPayload.GemsSpent` is 0 from now on (the gems are on `PackPurchased`).

Refunds (2.5): `PackRefundsRequest(long? Session)` (spec account-session), `PackRefundsResponse(IReadOnlyList<PackRefundDto> Refunded)`
(no account version, spec account-session 2.3) and `PackRefundDto(string PackId, int Count,
int GemsRefunded)` for `POST /packs/refunds` (`Rpg.Client.RefundPacksAsync(PackRefundsRequest)`, `ServerBridge.RefundPacks(json)`, `ServerLink.refund_packs`,
console `packs refunds`); `PackTypeRequest` and `PackTypeResponse` gain `bool? RefundUnopened = null` (left off the JSON unless true, so the
existing goldens and seed files are unchanged), and the event
```csharp
public sealed record PackRefundedPayload(string PlayerId, string PackId, int PackVersion, int Count, int GemsRefunded);
```
(`EventTypes.PackRefunded`, topic `rpg.economy.events`, key = playerId; `PackVersion` is the retirement version).

Error code (`ApiErrors`): **1411 `NoPackOwned`** (409): an open with no unopened pack of that type.

`Rpg.Client`: `BuyPackAsync(string packId, PackBuyRequest request)`. Godot: `ServerBridge.BuyPack(packId, json)` and
`ServerLink.buy_pack(pack_id, count, key)` (data = `PackBuyResponse`).

### 3.2 PostgreSQL: `Migrations/0011_pack_inventory.sql` (0009 and 0010 were taken by review fixes)

```sql
CREATE TABLE pack_inventory (
  player_id uuid NOT NULL REFERENCES players(player_id), pack_id text NOT NULL,
  count int NOT NULL CHECK (count >= 0), updated_at timestamptz NOT NULL,
  PRIMARY KEY (player_id, pack_id));
CREATE TABLE pack_ledger (                      -- append-only: +n per buy, -1 per open
  id bigserial PRIMARY KEY, player_id uuid NOT NULL REFERENCES players(player_id), pack_id text NOT NULL,
  pack_version int NOT NULL, delta int NOT NULL CHECK (delta <> 0),
  reason text NOT NULL CHECK (reason IN ('buy','open','refund')),
  request_key uuid NOT NULL, opening_id uuid NULL, created_at timestamptz NOT NULL);
CREATE INDEX pack_ledger_player ON pack_ledger (player_id, created_at);
CREATE UNIQUE INDEX pack_ledger_request ON pack_ledger (player_id, reason, request_key);   -- one row per request or refund (reason: own key spaces)
ALTER TABLE pack_types ADD COLUMN refund_unopened boolean NOT NULL DEFAULT false;
-- account_requests.kind gains 'pack_buy'
```
Invariant: `pack_inventory.count` equals the sum of the player's `pack_ledger.delta` for that pack (checked by a test). Both tables
are written only inside the account transaction under `acct:<player>`, so a buy and an open of one player never interleave.
Timestamps are the database's `clock_timestamp()` inside the lock, as in slice 5.

### 3.3 Redis, queues

N/A: no Redis key (the inventory is not cached), no RabbitMQ queue. The event goes through the existing outbox relay.

### 3.4 Configuration

`Cards:MaxPacksPerBuy` (default 10, checked at startup to be at least 1). Prices stay on the pack types (`infra/economy/card_economy.json`, placeholder 100 gems; 5c
sets real prices).

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| 1 | The same buy key twice (acceptance 1) | One debit, one inventory increment, one ledger row, one `PackPurchased`; the replay returns the stored response | `CardCollectionTests.Buy_same_key_buys_once` |
| 2 | API crash after the buy's commit, before the response (acceptance 2) | The client's retry with the kept key gets the stored response; gems spent once | `CardCollectionTests.Buy_replayed_after_commit_spends_once` |
| 3 | The same key for a buy and then an open | 409 1407, nothing written | `CardCollectionTests.Buy_key_reused_for_open_is_refused` |
| 4 | Not enough gems / count out of range / unknown or retired pack type | 409 1402 / 400 1401 / 404 1408; nothing written | `CardCollectionTests.Buy_refusals_write_nothing` |
| 5 | Open with no owned pack | 409 1411; no draw, no pity change, no request row | `CardCollectionTests.Open_without_owned_pack_is_refused` |
| 6 | Two opens race for the last pack | The account lock serialises them; the second gets 1411; the count never goes below 0 | `CardCollectionTests.Concurrent_opens_spend_one_pack_each` |
| 7 | An owned pack whose type was retired after the buy | Opens with the type's last version | `CardCollectionTests.Retired_pack_type_still_opens_owned_packs` |
| 8 | An owned pack with nothing left to draw | 404 1408; the pack stays owned | `CardCollectionTests.Undrawable_owned_pack_stays_owned` |
| 9 | Redpanda down while buying (acceptance 3) | `PackPurchased` waits in the outbox and is published after the restart | e2e `card_redpanda_down` extended with a buy before the open |
| 10 | Ledger and count disagree | Never: one transaction writes both | `CardCollectionTests.Inventory_equals_ledger_sum` after a mixed run of buys and opens |
| 11 | A retirement (or any version) that packs could not be opened with | 400 1401 at the save, unless it refunds | `CardCollectionTests.Admin_ARetirementThatWouldTrapOwnedPacks_IsRefused` |
| 12 | A pack type that became unopenable after its save (catalog, rates) | Not sold (404 1408); an owned one is refused and stays owned | `CardCollectionTests.APityOnlyRarity_NeedsACardRate_AtTheSaveTheBuyAndTheOpen` |
| 13 | Retire with a refund | Each owner is paid what they paid for the packs left, once, when they open the Open packs page; counts 0; `PackRefunded`; opens refused until then | `CardCollectionTests.RetireWithRefund_PaysEachOwnerWhatTheyPaid_OnTheOpenPacksPage` |
| 14 | Two visits at once, a crash, a retry | Only uncommitted work repeats; the unique ledger keys stop a second payment | `CardCollectionTests.Refund_TwoVisitsAtOnce_PayOnce` |
| 15 | The type is un-retired before the player visits the page | That player keeps the packs and can open them | `CardCollectionTests.Refund_SkipsATypeUnretiredBeforeThePlayerVisits` |
| 16 | `refundUnopened` on a version that is not retired | 400 1401 | `CardCollectionTests.RetireWithRefund_ARefundNeedsARetiredVersion` |
| 17 | A player buys with the key their refund will derive | Refund rows have their own key space; the refund is paid | `CardCollectionTests.Refund_APlayersOwnKeyCannotBlockIt` |
| 18 | Packs no buy row prices (a damaged ledger) | The priced ones paid; the rest kept and held (`refundHeld`), the open says "support check", later visits skip it, metric reason held | `CardCollectionTests.Refund_UnpricedPacks_AreHeldForASupportCheck_AndThePricedOnesPaid` |
| 19 | Postgres down at login | 503, no token (Postgres is a hard dependency) | `CardCollectionTests.Login_WithPostgresUnreachable_Is503` |

No verdicts, so no 2002; no queue, so no dead letters (a refund that fails is retried on the player's next visit of the Open packs page).

## 5. Observability

- `rpg_packs_bought_total{pack}` (counter of packs bought; `pack` is the pack type id, a handful of values, like the existing
  `rpg_packs_opened_total{pack}`).
- `rpg_packs_owned` (gauge: unopened packs across all players, set by the existing monitor loop from `SUM(count)`).
- `rpg_card_actions_refused_total{reason="NoPackOwned"}` (a new reason on the existing counter; the reasons are the failure names).
- The buy runs inside the existing `rpg_account_action_duration_seconds{action="buy_pack"}` histogram (beside `open_pack`) and the
  replay counter `rpg_account_request_replays_total`.
- `rpg_packs_refunded_total{pack}` and `rpg_pack_refund_gems_total` (2.5); `rpg_pack_refund_failures_total{pack,reason}`
  (reason `held`: packs waiting for a support check, `error`: a refund that failed and is retried on the next visit), an alert
  candidate.

## 6. Test plan

**.NET** (`tests/Rpg.GameServerApi.Tests`, Testcontainers, a database per test):
- `CardCollectionTests`: every row of section 4 except 9; the collection lists owned packs sorted by id and leaves out zero counts;
  an open's response has `GemsSpent` 0 and the right `PacksLeft`; the buy's ledger row carries the version bought.
- The existing pack-open tests (pity, first guarantees, the Rare guarantee, duplicates, the run lock) buy first; their expectations
  on cards are unchanged, and expectations on gems move from the open to the buy.
- `CardContractTests`: golden JSON for `PackBuyRequest`, `PackBuyResponse`, `OwnedPackDto`, the changed `CollectionResponse` and
  `PackOpenResponse`, `PackPurchasedPayload`; `ApiErrors` 1411.
- Migration test: `0009` applies on top of `0008` and on an empty database.
- Metrics: `rpg_packs_bought_total` and the new refusal reason move as expected.
- Refunds (rows 13-16): the amount at each buy's price with the oldest packs opened first, the ledger rows and event, a second run
  paying nothing, an un-retired type skipped, the open refused while pending, the openability rule skipped for a refund version.

**Godot** (`tests/game/test_cards.gd`, fake bridge): the console's `server pack-type ... retired=true refund=true` sends
`refundUnopened`; `ServerLink.buy_pack` sends the key and count and returns the response;
`packs buy` prints the key and the new count, retrying with the same key buys once; `packs` lists owned counts; the console's
`packs open` refuses with the server's 1411 line when nothing is owned.

**End to end** (`tools/e2e.sh`, `#! cards`): `card_pack`, `card_pity` and `card_run_lock` buy before opening; `card_redpanda_down`
buys while Redpanda is stopped and checks `PackPurchased` with `e2e redpanda-check`.

Both suites must pass (`tools/dotnet_test.sh`, `tools/godot_tests.sh`).

## 7. Decisions and what stays out

- Hearthstone's model: buy, own, open (user, 2026-11-15). Up to 10 packs per buy; no discount for bulk (5c may add one).
- An owned pack opens with the type's latest version even when retired; the price is the one at the buy (the user: packs always
  hold 5 cards, so the newest version is right whenever it was bought).
- A forced retirement refunds the unopened packs in gems (the user, 2026-11-15), at what each player paid; a refund version may
  break the openability rule, since nobody opens it.
- **Stays out:** the screens (5b), real prices (5c), gifting packs, refunds of opened packs, packs as rewards (a later slice can add a reason
  `reward` to `pack_ledger`), retention of `pack_ledger` (7b).
