# Spec: account-session (slice 5b1)

Status: **spec written and reviewed 2026-11-16 (decisions in section 7).** Builds on `specs/card-collection.md` (slice 5: the account, its advisory lock
`acct:<player>`, request keys in `account_requests`, open / dust / craft), `specs/pack-shop.md` (5b0: buy, owned packs, refunds) and
`specs/card-ui.md` 2.5 (the client's one action in flight, reconnect instead of resume). Decided with the user on 2026-11-16 after the
Shop sub-step of 5b: "It is unacceptable to me to show the client stale item ownership. We definitely need to gate it in some way,
even if it takes longer for the client to connect"; the HTTP design was chosen over a required socket ("I'm ok with the http(s)
version for now"); SignalR stays its own later slice.

## 1. Purpose & enterprise mapping

**Purpose.** Every account action (buy packs, open a pack, dust, craft, settle refunds) is already one Postgres transaction under the
player's account lock and idempotent by its request key, so a retry of one intent applies once. Two gaps are left:

1. **A request from before a crash or a re-login.** The client keeps its key in memory only (card-ui 2.5). If the game dies while a
   buy is unanswered and the player logs back in, the old request may still commit after the new screen has loaded; a second press
   is then a second, unintended purchase, and the screen showed ownership the server no longer had. Two devices on one account have
   the same problem.
2. **A decision made on a stale view inside a session.** A reward released by the verifier, a refund, or a purchase whose answer was
   lost lands between the screen's fetch and the player's press.

This slice closes both with two standard checks, over the HTTP API that exists:

- **Account session (a fencing token).** `POST /api/v1/account/session` takes the account lock, raises the player's session number
  and returns it with the full collection. Every account action carries the session number; an older one is refused with 409 1412
  and writes nothing. Because the call takes the same lock as every action, an old request either commits before it (the snapshot
  shows it) or arrives after it (refused). **The snapshot a login returns is final.** The newest session wins, as in Hearthstone
  ("logged in from another location").
- **Expected version (optimistic concurrency, HTTP `If-Match` in spirit).** Every player decision (buy, open, dust, craft) carries
  the account version the screen showed. A different current version is refused with 409 1413 and writes nothing; the client
  refetches and shows the truth before the player decides again.

The Godot half: `ServerLink` starts the session before any card screen shows ownership (the gate), `CardAccount` sends both numbers
and keeps the version current from every answer, and a 1412 or 1413 refetches before buttons unlock. The screens' own handling
(the "Connecting…" gate, the "opened somewhere else" line) is `card-ui`'s (its 2.5 points here).

**Fenced:** every call that changes the account (buy, open, dust, craft, refunds), the run abandon (`POST /runs/{id}/abandon`,
the dust path's cancel: a stale device must not cancel a run and then have its dust refused; user 2026-11-16) and the run start
(`POST /runs`, which abandons the active run: the same harm; user 2026-11-17), the last two session only, no account version.
Reads are not fenced.

**One name (user, 2026-11-17):** the account version is `account_version` / `AccountVersion` / `accountVersion` everywhere: the
column (`wallets.account_version`, renamed from `wallets.version` by migration 0012), the collection, the session, the wallet
(`WalletResponse.AccountVersion`), the decisions' `expectedAccountVersion`, their answers' `accountVersion` and the 1413's
`currentAccountVersion`.

**Out of scope:** live updates of an open screen (push; the SignalR slice), every other run call (runs have their own epoch, spec
`run-verify`), real accounts and login (dev tokens stay).

| Component | Role in this slice | Enterprise analogue |
|---|---|---|
| Godot client (`ServerLink`, `CardAccount`) | Starts the session, sends session + expected version, refetches on refusal | Client of an entitlements service |
| ASP.NET Core API | `POST /account/session`; the two checks in five actions; two error codes | Account / entitlements service with fencing and conditional writes |
| PostgreSQL | `players.account_session` (new column); `wallets.account_version` (renamed from `version`) is the account version | Source of truth, row-level fencing |

**Not used:** Redis (the session is read and written only inside the locked transaction; the wallet cache is invalidated as today),
RabbitMQ, Redpanda and the outbox (no new event: a session start is not an economy fact; presence covers activity), the verifier.

**Acceptance scenarios covered:** 1 (duplicate requests → one effect, extended across sessions and devices: a request from an older
session never commits after a newer login), 2 (a client that crashed with a request in flight: after the re-login the screen shows
whether it committed, and nothing can commit behind it). New invariant, tested: **an account action commits only when its session
is current and (for decisions) the account is the version the player saw.**

## 2. Sequence flow

### 2.1 Starting a session (the gate)

**When (user, 2026-11-16):** the session is the account login. The game always tries to connect when it starts; signing in
(dev token) is followed at once by `start_account_session()`. If that fails, the game falls back to **offline mode**: runs play as
today, the card screens show no ownership and offer **Go online**, which runs the login again (token, then a new session). A new
session also starts after a give-up (card-ui 2.5) and on "Use it here" after a 1412. **One active client per account**: the newest
login wins, whatever that client is doing.

**Runs are never touched by a session (user: an offline run that completed and was never invalidated must not be thrown away).**
Run uploads, the stairs, the end and resume carry the run's own `epoch` (spec `run-verify`), never the account session: a server run
continued offline ("Not synced" Continue) keeps its save and queue, and when the game is online again its actions upload, are
verified and settle their rewards exactly as today, whichever session is current. Only the account-changing calls of 2.2 are fenced.
A local-mode run (no server at all) stays unverified and unrewarded, as before.

```
Godot ServerLink.start_account_session()  (right after sign-in; again after a give-up, "Use it here" or Go online)
  ─▶ POST /api/v1/account/session   (bearer JWT; rate limited as `actions`; no body)
       BEGIN; pg_advisory_xact_lock(acct:<player>)          ← waits for any account action mid-commit
       EnsurePlayer; UPDATE players SET account_session = account_session + 1 RETURNING account_session
       read the collection inside the same transaction (CardStore's collection query on this connection)
       COMMIT
  ◀─ 200 AccountSessionResponse { session, collection }   (collection.accountVersion = wallets.account_version)
  ServerLink keeps session; CardAccount.account_version = collection.accountVersion
```

The collection inside the lock is what makes the snapshot final: no account action can be between its own lock and its commit while
the session call holds the lock, and every later action from an older session is refused (2.2).

### 2.2 An account action

```
CardAccount.run(kind, target)  ─▶ POST /packs/{id}/buy | /packs/{id}/open | /cards/{id}/dust | /cards/{id}/craft
                                   { requestKey, session, expectedAccountVersion, (count) }
                                 POST /packs/refunds { session }
                                 POST /runs/{id}/abandon { session }   (steps 1, 3 and the abandon; an abandon already done
                                                                        answers 204 before the fence; no account version)
                                 POST /runs { rulesetVersion, runStructureId, characterIds, session }   (step 3 before
                                                                        the previous run is abandoned; no account version)
  BEGIN; lock acct:<player>; EnsurePlayer
  1. malformed (no key, no session, no expectedAccountVersion on a decision; a buy over the count limit) → 400, nothing written
  2. replay: the key is in account_requests → the stored response (`replayed`), whatever the session or version now
     (a committed request is answered even after its own commit moved the version or a newer login happened)
  3. session: body.session != players.account_session → 409 1412 AccountSessionReplaced {currentSession}; nothing written
  4. account version (buy, open, dust, craft): body.expectedAccountVersion != wallets.account_version, read with the wallet
     row locked (FOR UPDATE: a reward released without the account lock waits for this transaction) → 409 1413
     AccountVersionStale {currentAccountVersion}; nothing written
  5. the action as today (5b0 / slice 5), which raises wallets.account_version in the same transaction
  COMMIT
  ◀─ 200 <the action's response> + accountVersion (the account version after it; not on refunds, 2.3)
  CardAccount.account_version = response.accountVersion when it is the one sent + 1 (2.3)
```

Order matters: replay before the checks (step 2) keeps acceptance 1 and 2 intact: a retry with the same key after the commit gets its
answer even though that commit moved the version. A refusal at step 3 or 4 stores nothing under the key, so the client may re-send
the same key after refetching (like the 1403 path). A response stored before this slice has no `accountVersion`: its replay
reads as 0, so the client's next decision is a 1413 and a refetch, which is correct, just one round trip slower.

### 2.3 What the client does with each answer

| Answer | Client (`ServerLink` / `CardAccount`) | Screen (`card-ui`) |
|---|---|---|
| 200 | `accountVersion` from the response **only when it is the one it sent + 1** (its own write and nothing else; true by construction for buy, open, dust and craft, since step 4 refused anything else, and kept as a safety net); otherwise it refetches the collection before the next decision. **A refunds answer carries no account version** (user, 2026-11-17): a refund is not checked against the screen's version, so its version could include changes the screen never showed (a reward); the Open packs page refetches the collection after it | shows the result |
| 409 1413 stale | `account_version = currentAccountVersion`; returned as a refusal | refetches the collection, says "Your account changed. Here is what you have now.", buttons unlock after the refetch |
| 409 1412 replaced | the link's session marked replaced; every account action refused locally until a new session | "Your account was opened somewhere else." with **Use it here** (a new session, then a refetch) and **Back** |
| no answer / 5xx / 429 | card-ui 2.5: reconnect with the same key and the same session and version | "Reconnecting…" |
| given up (card-ui 2.5) | **a new session is started before anything unlocks**: it fences the request that was given up | refetch from the new session's snapshot |

### 2.4 What raises the account version

`wallets.account_version` is the account version: it covers gems, dust, owned cards, owned packs (with their refund holds) and pity. Every
writer of those raises it in its own transaction. Today: buy, open (always, dust or not), dust, craft, refund payout
(`MoveWalletAsync`), a granted challenge reward (`ChallengeSettlement`) and a released pending reward (`PendingGems`). **Missing
today, added here:** setting a refund hold (`CardStore.Refunds`, `pack_inventory.refund_held_version`) changes `OwnedPacks` and must
raise the version too. Run status (`activeRunId`, `activeRunStatus`) is not ownership and does not raise it; the dust run lock stays
checked by the server at step 5.

## 3. Data contracts

### 3.1 C# records (`src/Rpg.Contracts/Cards/`)

```csharp
/// POST /api/v1/account/session (no body). Session: the player's new session number; every account action carries it.
/// Collection: the account at the moment the session started (Collection.AccountVersion is the account version).
public sealed record AccountSessionResponse(long Session, CollectionResponse Collection);

/// Body of open, dust and craft (changed: + Session, ExpectedAccountVersion; both required: null, or a session below 1, is a 400).
public sealed record AccountActionRequest(Guid RequestKey, long? Session, long? ExpectedAccountVersion);

/// Body of buy (changed: + Session, ExpectedAccountVersion; both required).
public sealed record PackBuyRequest(Guid RequestKey, int Count, long? Session, long? ExpectedAccountVersion);

/// Body of POST /packs/refunds (new; was bodiless). A refund is not the player's decision, so no expected version.
public sealed record PackRefundsRequest(long? Session);

/// Body of POST /runs/{runId}/abandon (new; was bodiless; `Runs/`). Session only: abandoning is fenced, not versioned.
public sealed record RunAbandonRequest(long? Session);

/// POST /runs (changed: + Session, required; `Runs/`). Session only: a run start abandons the active run.
public sealed record RunStartRequest(string RulesetVersion, string RunStructureId, IReadOnlyList<string> CharacterIds, long? Session);
```

The fields are nullable only so a missing one is told apart from 0 (`System.Text.Json` would read a missing `long` as 0); the
endpoint refuses null as malformed, next to the existing `requestKey` check (section 7, question 4). The responses
`PackBuyResponse`, `PackOpenResponse`, `DustResponse` and `CraftResponse` gain a trailing `long AccountVersion` (the account
version after the action; a replay returns the stored response with the version of its time). `PackRefundsResponse` carries
none (2.3). Renamed: `CollectionResponse.Version` and `WalletResponse.Version` → `AccountVersion`.

**Errors (`ApiErrors`):**
- `1412 AccountSessionReplaced` (409): the request's session is not the player's current one. Extension `currentSession`.
- `1413 AccountVersionStale` (409): the account changed since the screen read it. Extension `currentAccountVersion`.

**Migration `0012_account_session.sql`:** `ALTER TABLE players ADD COLUMN account_session bigint NOT NULL DEFAULT 0;` (0 = no
session started; the first session is 1) and `ALTER TABLE wallets RENAME COLUMN version TO account_version;`.

**Deploying migration 0012 (once per database):** it renames `wallets.version`, so no old verifier worker may run against it:
restart the whole stack once (`tools/dev_stack.sh restart` stops the API and the worker, then starts the new ones). Every later
launch needs nothing special; tests and e2e make fresh databases.

**Queues, topics, Redis:** N/A (none added). The wallet cache key is now `wallet:v2:{playerId}` (`VerifyPolicy.WalletKey`):
entries cached under the old `version` shape are never read, and the old `wallet:{playerId}` entries expire (60 s). It is invalidated after every action, on a replay too
(review fix 2026-11-17: dust and craft now do it on a replay, as buy and open already did); nothing caches the session.

### 3.2 Godot (`client-godot/game/`)

| Piece | Change |
|---|---|
| `net/ServerBridge.cs` | `StartAccountSession()`; `RefundPacks(json)` now takes a body |
| `ServerLink` | `start_account_session() -> {ok, data, error}` (keeps `account_session`, hands the version to `CardAccount`), `session_replaced` (bool, set by a 1412), the card calls and the run start send `session`, decisions `expectedAccountVersion` |
| `CardAccount` | `account_version` (last known account version), sent with each decision and taken from an answer by the +1 rule (2.3), never from refunds; on 1413 `account_version = currentAccountVersion`; on 1412 `session_replaced` and every later `run` refused locally until a new session; after `give_up()` the account is free only once a new session has been started |
| console | `server session` (start one, print it), `server session steal` (start one without telling the link: another device, for tests), `packs` commands send the numbers |

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| 1 | The same key twice in one session (acceptance 1) | Replay of the stored response; one effect | existing `Buy_same_key_buys_once`, `Open_same_key_once`; new `Replay_answers_after_the_version_moved` |
| 2 | A crash with a buy in flight, then a new login, and the old buy commits first (acceptance 2) | The session call waits on the lock; its snapshot shows the purchase | `AccountSessionTests.Session_waits_for_an_action_mid_commit` (the test holds `acct:<player>` in its own transaction, changes the wallet, starts the session call, commits; the snapshot has the change) |
| 3 | The old buy arrives after the new login | 409 1412; no ledger row, wallet and inventory unchanged | `AccountSessionTests.Old_session_is_refused_and_writes_nothing` (each of the five actions) |
| 4 | Two devices | The newest login wins; the other's next action is 1412 | same test, two sessions in turn |
| 5 | A reward or refund lands between the fetch and the press | 409 1413 with `currentAccountVersion`; nothing written; the same key works after the refetch | `AccountSessionTests.Stale_version_is_refused_and_writes_nothing` (buy, open, dust, craft), `Same_key_after_a_stale_refusal` |
| 6 | A committed request retried after a newer session | Its stored response (replay before the checks) | `AccountSessionTests.Replay_before_the_session_check` |
| 7 | Missing session or expected version | 400, nothing written | `AccountSessionTests.Missing_numbers_are_malformed` |
| 8 | A writer forgets to raise the version | Caught by a test per writer, incl. the refund hold | `AccountSessionTests.Every_account_writer_raises_the_version` (buy, open, dust, craft, refund, refund hold, granted reward, released pending reward) |
| 9 | Postgres down at the session call | 503 as every endpoint; the client stays on its gate ("Connecting…") | existing 503 tests extended with the session endpoint |
| 10 | Client: a 1413 | Version updated, refusal returned, no retry | Godot `test_account_session::test_stale_version_refetches` |
| 11 | Client: a 1412 | Every later action refused locally until `start_account_session` | `test_account_session::test_replaced_session_blocks_until_a_new_one` |
| 12 | Client: give up | The account is free only after a new session; the request given up is fenced | `test_account_session::test_give_up_starts_a_new_session` |
| 12b | Abandon or run start from an old session | 409 1412; the run stays Active, no run is started, nothing written | `AccountSessionTests.OldSession_IsRefusedByEveryFencedCall_AndWritesNothing_TheNewestLoginWins` |
| 12e | A retried abandon (its 204 was lost) after a newer login | 204: it changes nothing | `AccountSessionTests.RetriedAbandon_AfterANewerLogin_IsStillASuccess` |
| 12c | A server run finished offline, then the game goes online (a new session meanwhile) | The queue uploads, the run is verified and its reward settles; the session plays no part | `test_account_session::test_offline_run_survives_a_new_session` (fake bridge); e2e `offline_stairs` passes with a session started on reconnect |
| 12d | No server at start | Offline mode: the card screens offer Go online; runs play; Go online signs in and starts a session | `test_account_session::test_go_online_starts_a_session` |
| 13 | End to end: a second "device" | `server session steal`, then `packs buy` → refused 1412, wallet unchanged (`.sql`), then `server session` and the buy goes through | e2e `account_session_fence` (`#! cards`) |

Replay mismatches and 2002 do not arise: nothing here is verified. No queue, so no dead letters.

## 5. Observability

- `rpg_account_sessions_started_total` (counter, no labels).
- The existing `rpg_card_actions_refused_total{action, reason}` gains the reasons `SessionReplaced` and `AccountVersionStale` (bounded
  labels; `action` adds `refund_packs`, `abandon_run` and `start_run`). A rise in `AccountVersionStale` shows screens deciding on stale views; in `SessionReplaced`, players
  on two devices or crashed clients' late requests.
- `rpg_account_action_duration_seconds{action="account_session"}` (the existing histogram): how long a login waits on the lock.
- Traces: the session call is an ordinary ASP.NET + Npgsql span; `rpg.account_session` tag on every account action's span.

## 6. Test plan

**.NET** (`tests/Rpg.GameServerApi.Tests`, Testcontainers, a database per test; Docker required):
- `AccountSessionTests`: rows 2–9 of section 4, plus the session response's collection equal to a `GET /cards/collection` in the
  same state, and the session number rising by one per call.
- `CardCollectionTests` / pack-shop tests updated to start a session first and send the numbers (a test helper).
- `MigrationTests`: 0012 applies on a database at 0011 and on a fresh one.
- `Rpg.Contracts.Tests`: golden JSON for `AccountSessionResponse`, the changed requests and responses (with `accountVersion`).

**Godot** (`client-godot/tests/game/test_account_session.gd`, the fake bridge of `test_server_mode`): rows 10–12, the numbers sent
on every call, the version taken from each answer, `server session [steal]`.

**End to end:** `account_session_fence` (row 13); the existing card scenarios (`card_pack`, `card_run_lock`, `card_pity`,
`verify_pool_tampered`, `card_redpanda_down`) pass with the session started by `ServerLink`.

Both suites must pass (`tools/dotnet_test.sh`, `tools/godot_tests.sh`).

**Changes to other specs (`/sync-spec` after the build):** `card-collection` 2.x and `pack-shop` 2.x and 3.1 (the request fields, the
two refusals, the response `accountVersion`, the renamed `Version` fields); `card-ui` 2.5 and section 4 (the gate, 1412 / 1413 handling, give-up starts a session);
`card-collection` 2.3 (the abandon's body and its 1412); `server-authority` 3.1 (the run start's session);
`settlement-outbox` 2.4 (`WalletResponse.AccountVersion`, the column's new name); `main-menu` (the offline fallback and Go online, if the menu shows it);
`specs/roadmap.md` (5b1 between 5b0 and the rest of 5b).

## 7. Decisions

Decided with the user on 2026-11-16:
1. **The session is the login:** the game always tries to connect at start and starts a session right after signing in; offline
   mode otherwise, with Go online on the card screens; again after a give-up and on "Use it here". Runs are never fenced or
   discarded by a session (2.1).
2. **The run abandon is fenced** (session only), so a stale device cannot cancel a run (section 1, "Fenced"); **and the run
   start** (2026-11-17), which abandons the active run.
3. **409 for both refusals**, the API's convention for conflicts; the meaning is in the `errorCode`.
4. **Required fields:** a request without the numbers is malformed; the server, `ServerLink`, the console and the e2e scripts change
   together.
5. **No session expiry** (decided 2026-11-17): a session lasts until a newer login replaces it; authentication lifetime stays the bearer token's
   (`Auth:TokenLifetime`, 12 h). The session holds no resource (one number per player), is not a credential, and correctness
   comes from the account lock and the session order, not from time. **Revisit with the SignalR slice**, when a session holds an
   open connection and expiring sessions whose socket is gone becomes the standard choice.
6. **One name for the account version** (2026-11-17): `account_version` everywhere (section 1).
7. **Refunds carry no account version** (2026-11-17): the page reloads the collection after them (2.3).
