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
Godot client ── POST /api/v1/packs/{packId}/buy  { requestKey, count }        (rate-limited as `actions`)
  API, ONE transaction (the slice 5 account shape):
    1. pg_advisory_xact_lock(acct:<player>)
    2. account_requests (player, requestKey): same kind and hash → return the stored response (200); different → 409 1407
    3. count 1..Cards:MaxPacksPerBuy (10), else 400 1401
    4. the pack type's latest version FROM POSTGRES; unknown or retired → 404 1408
    5. wallet gems >= price x count, else 409 1402; wallet_ledger -price x count, reason 'pack_buy'
    6. pack_inventory (player, pack) += count (upsert); pack_ledger +count, reason 'buy', pack_version, request_key
    7. outbox PackPurchased (key = playerId); account_requests row (the response)
  ◀── 200 PackBuyResponse { packId, packVersion, count, gemsSpent, gems, owned }     DEL wallet:{playerId}
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

## 3. Data contracts

### 3.1 C# records (`src/Rpg.Contracts/Cards/`, additive; `WhenWritingNull`)

```csharp
/// <summary>Body of POST /packs/{packId}/buy. Count 1..10 (Cards:MaxPacksPerBuy).</summary>
public sealed record PackBuyRequest(Guid RequestKey, int Count);
public sealed record PackBuyResponse(string PackId, int PackVersion, int Count, int GemsSpent, int Gems, int Owned);

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

Error code (`ApiErrors`): **1411 `NoPackOwned`** (409): an open with no unopened pack of that type.

`Rpg.Client`: `BuyPackAsync(string packId, PackBuyRequest request)`. Godot: `ServerBridge.BuyPack(packId, json)` and
`ServerLink.buy_pack(pack_id, count, key)` (data = `PackBuyResponse`).

### 3.2 PostgreSQL: `Migrations/0009_pack_inventory.sql`

```sql
CREATE TABLE pack_inventory (
  player_id uuid NOT NULL REFERENCES players(player_id), pack_id text NOT NULL,
  count int NOT NULL CHECK (count >= 0), updated_at timestamptz NOT NULL,
  PRIMARY KEY (player_id, pack_id));
CREATE TABLE pack_ledger (                      -- append-only: +n per buy, -1 per open
  id bigserial PRIMARY KEY, player_id uuid NOT NULL REFERENCES players(player_id), pack_id text NOT NULL,
  pack_version int NOT NULL, delta int NOT NULL CHECK (delta <> 0),
  reason text NOT NULL CHECK (reason IN ('buy','open')),
  request_key uuid NOT NULL, opening_id uuid NULL, created_at timestamptz NOT NULL);
CREATE INDEX pack_ledger_player ON pack_ledger (player_id, created_at);
```
Invariant: `pack_inventory.count` equals the sum of the player's `pack_ledger.delta` for that pack (checked by a test). Both tables
are written only inside the account transaction under `acct:<player>`, so a buy and an open of one player never interleave.
Timestamps are the database's `clock_timestamp()` inside the lock, as in slice 5.

### 3.3 Redis, queues

N/A: no Redis key (the inventory is not cached), no RabbitMQ queue. The event goes through the existing outbox relay.

### 3.4 Configuration

`Cards:MaxPacksPerBuy` (default 10). Prices stay on the pack types (`infra/economy/card_economy.json`, placeholder 100 gems; 5c
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

No verdicts, so no 2002; no queue, so no dead letters.

## 5. Observability

- `rpg_packs_bought_total{pack}` (counter of packs bought; `pack` is the pack type id, a handful of values, like the existing
  `rpg_packs_opened_total{pack}`).
- `rpg_packs_owned` (gauge: unopened packs across all players, set by the existing monitor loop from `SUM(count)`).
- `rpg_card_actions_refused_total{reason="no_pack_owned"}` (a new reason on the existing counter).
- The buy runs inside the existing `rpg_account_action_duration_seconds{action="buy"}` histogram and the replay counter
  `rpg_account_request_replays_total`.

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

**Godot** (`tests/game/test_cards.gd`, fake bridge): `ServerLink.buy_pack` sends the key and count and returns the response;
`packs buy` prints the key and the new count, retrying with the same key buys once; `packs` lists owned counts; the console's
`packs open` refuses with the server's 1411 line when nothing is owned.

**End to end** (`tools/e2e.sh`, `#! cards`): `card_pack`, `card_pity` and `card_run_lock` buy before opening; `card_redpanda_down`
buys while Redpanda is stopped and checks `PackPurchased` with `e2e redpanda-check`.

Both suites must pass (`tools/dotnet_test.sh`, `tools/godot_tests.sh`).

## 7. Decisions and what stays out

- Hearthstone's model: buy, own, open (user, 2026-11-15). Up to 10 packs per buy; no discount for bulk (5c may add one).
- An owned pack opens with the type's latest version even when retired; the price is the one at the buy.
- **Stays out:** the screens (5b), real prices (5c), gifting or refunding packs, packs as rewards (a later slice can add a reason
  `reward` to `pack_ledger`), retention of `pack_ledger` (7b).
