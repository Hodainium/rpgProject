# Spec: player-inbox: a server inbox for the player, rewards as its first messages, runs verified before the menu

Status: **spec written 2026-11-21; questions Q1-Q7 still open (section 7).** Replaces the run-rewards drafts of 2026-11-20 (the
design history is in section 7). Roadmap **4e**, built **just before 4b `game-analytics`**, not now (user, 2026-11-21: the web
dashboard will talk to players, "like sending gems or messages"; the 5-series slices go on first).

## 1. Purpose & enterprise mapping

**A player inbox on the server.** Every message the game or its people send a player is a row in one table: the rewards a verified
run paid (written by the verifier worker in the same transaction that pays them), and messages from support or the developers, with
gems attached or not (sent through an admin endpoint now, the web dashboard later). The game shows unread messages **on the main
menu, one at a time, like The Binding of Isaac's unlock pop-ups**; OK marks a message read on the server, so it never shows again,
on any machine.

**A finished run is verified before the main menu.** Online, a run that ends, won or lost, waits on "Verifying the run…" until the
server has verified all of it; then its rewards are already in the inbox. Every wait on the server, everywhere, offers **Go offline**.
Offline (or after Go offline) the game goes back to the main menu and keeps the finished run in its save; the next time it is online
it uploads the run at once ("Uploading your run…") and waits for its verification the same way.

- The inbox **informs**; it never decides money. A reward's gems are in the wallet when the worker releases them; a gift's gems are
  in the wallet when it is sent (Q2). A message that is never shown changes nothing.
- One general pipeline for later senders: compensation, event gifts, the pack refund notice, the web dashboard (slice 7), a push
  hint over SignalR ("you have mail", slice 7).

Backend components used:
- **PostgreSQL**: a new table `player_inbox` (the source of truth for messages and their read state), written in the transactions
  that already exist (the worker's release) or new ones (an admin send), read and marked by the player.
- **ASP.NET Core API**: `GET /api/v1/inbox`, `POST /api/v1/inbox/read`, `POST /api/v1/admin/inbox`; `GET /runs/{id}` gains `settled`.
- **Rpg.Economy**: `PendingGems.ReleaseAsync` writes a reward message per released row; a new `Gifts` writes a gift (wallet, ledger,
  message) in one transaction.
- **Verifier worker**: unchanged code path, one more insert inside its existing settlement transaction (through `Rpg.Economy`).
- **Outbox → Redpanda**: `InboxMessageCreated` and `InboxMessagesRead` (analytics; slice 7's push will read them), `GiftGranted` on
  the economy topic. Never published directly.
- **Not used:** RabbitMQ (no new queue), Redis (3.4).

## 2. Sequence flow

### 2.1 A reward message

```
Verifier worker (one transaction, as today)
  step verdict → RunAggregator advances the verified prefix → PendingGems.ReleaseAsync
     per released ledger row: wallet += delta, completion mark, RewardGranted (outbox)  … today
                              + INSERT player_inbox (kind reward, payload {runId, seq, challengeId, characterId, amount},
                                source_key 'reward:<ledger id>' UNIQUE)                 … new
                              + InboxMessageCreated (outbox)                             … new
  commit → ack RabbitMQ (as today)
```

Exactly once: the message is inserted with the payment or not at all; a redelivered step finds the ledger row already released
(today's guard) and inserts nothing; `source_key` is unique besides. A row voided as AlreadyPaid or by a rollback gets no message (Q4).

### 2.2 A message or a gift from support

```
web dashboard (later) / console `server inbox send`
  POST /api/v1/admin/inbox {requestKey, playerIds[1..100], title, body, gems?}      (role ops-admin; gems > 0 also economy-admin)
  one transaction per call, under each player's account lock (acct:<id>, as the card actions):
     per player: INSERT player_inbox (kind message, or gift when gems > 0; source_key 'admin:<requestKey>:<player>')
                 gems > 0: wallet += gems (account_version + 1), wallet_ledger (reason 'gift', key 'gift:<requestKey>:<player>'),
                           GiftGranted (outbox)
                 InboxMessageCreated (outbox)
  → 200 {sent, alreadySent}   (a repeated requestKey sends nothing again: idempotent per player)
```

### 2.3 Reading the inbox (main menu)

```
main menu active (server mode, signed in, no run waiting)
  GET /api/v1/inbox?unread=true&limit=50 → {messages (oldest first), unreadCount}
  notices: rewards of one run and one challenge grouped into one notice ("Defeated The Lich · 3 × 25 gems", the characters named);
           a message or gift one notice each (title, body, "+N gems", "From the developers")
  OK → POST /api/v1/inbox/read {ids of that notice} → 204 → the next notice … until none
```

- Checked each time the main menu becomes active online, after a run's upload settles, after Go online. One read per visit; no
  polling. More than 50 unread: the next visit shows the rest.
- "OK to all" when more than three notices wait (Q3): one `read` call with every shown id.
- A failed `read` (no answer, 5xx, 429) is retried in the background with backoff; the notice is not shown again this session (the
  ids are remembered in memory); a later session may show it again (at least once).
- Never during a run, never in local mode.

### 2.4 A finished run: verified before the menu

```
the run ends (won or lost), online
  the queue drains; won: POST /runs/{id}/end; lost: the queued end (today's paths)
  connecting pop-up "Verifying the run…" + Go offline     (a lost run now waits too)
  poll GET /runs/{id} every 2 s until settled: true       (2.5)
  → the run-end screen → Menu → the main menu → the inbox (its rewards are there)

Go offline while waiting (or the server never answered)
  the server-mode save keeps the finished run (snapshot, queue, the pending end, lastAckedSeq)
  → the run-end screen (the local outcome, "Not verified yet") → the main menu, local mode for this session

back online (Go online, or the app starts with the server answering)
  the save holds a finished run → connecting pop-up "Uploading your run…" + Go offline
  the queue drains, the end is sent, poll until settled → the save is deleted → the inbox shows its rewards
```

- `GameMain.leaving_blocked()` covers a finished online server run (won or lost) until it is settled; Go offline is the way out.
- A finished run in the save is never played again: Continue does not offer it; only the upload uses it.
- A rollback while verifying (1108, a won run) is today's path: the run continues at the checkpoint, "The server rolled your run back…".
- A refusal while uploading (a 4xx other than a rollback) is today's: the run stops with its dialog (spec ui-feedback row 24) and the
  save goes.

### 2.5 Settled

`GET /runs/{id}` and `GET /runs/current` gain `settled`: the run is terminal (`Won`, `Lost`, `Abandoned`, `Rejected`) and
`verified_seq` ≥ its last stored action seq (a legacy run is settled). Computed on read from Postgres, never cached (3.4).

### 2.6 Go offline on every wait (client)

The connecting pop-up shows **Go offline** under every wait on the server, from the moment it shows (user, 2026-11-21: "there will
always be a button on any connecting to server or waiting for server that says go offline"): run start, resume, a floor seed, the
stairs' 1107 wait, a conflict or rollback rebuild, the run's verification and upload, an account action, Go online. What it does:
- **On the main menu or in a menu screen:** today's `GameMain.go_offline()` (local mode for this session, back to the main menu).
- **In a run:** the run is saved (server-mode save, as Save and quit), then the same: local mode for this session, the main menu.
  Continue then offers the saved run as today's offline "Not synced" copy (spec main-menu D6); a floor that still needs its seed
  waits for the server when it is reached, with Go offline again.
- **A finished run:** 2.4.

## 3. Data contracts

### 3.1 C# records (`src/Rpg.Contracts/Inbox/`)

```csharp
namespace Rpg.Contracts.Inbox;

/// <summary>GET /api/v1/inbox (spec player-inbox 2.3).</summary>
public sealed record InboxResponse(IReadOnlyList<InboxMessageDto> Messages, int UnreadCount);

public sealed record InboxMessageDto(
    long Id,
    InboxMessageKind Kind,
    string Sender,                       // "system" for rewards, "developers" / "support" for admin sends
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Title,   // admin sends; rewards: null (the game words them)
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Body,
    int Gems,                            // reward: the amount paid; gift: the gems sent; message: 0 (all already in the wallet)
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] InboxRewardDto? Reward,
    DateTimeOffset CreatedAt,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] DateTimeOffset? ReadAt);

public enum InboxMessageKind { Reward, Message, Gift }

public sealed record InboxRewardDto(string RunId, int Seq, string ChallengeId, string? CharacterId);

/// <summary>POST /api/v1/inbox/read: 1..100 ids; ids not the caller's or already read are ignored (204 either way).</summary>
public sealed record InboxReadRequest(IReadOnlyList<long> Ids);

/// <summary>POST /api/v1/admin/inbox (spec player-inbox 2.2).</summary>
public sealed record InboxSendRequest(string RequestKey, IReadOnlyList<string> PlayerIds, string Title, string Body, int Gems = 0,
    string Sender = "developers");
public sealed record InboxSendResponse(int Sent, int AlreadySent);
```

`Runs/RunSummary.cs`: `bool Settled = false` at the end, left off the JSON at its default (`WhenWritingDefault`), so every existing
answer and golden stays byte-identical.

Events (`Events/InboxEvents.cs`, topic `EventTopics.Player` = `rpg.player.events`, new):
`InboxMessageCreated(MessageId, PlayerId, Kind, Sender, Gems, ChallengeId?)` and `InboxMessagesRead(PlayerId, MessageIds, ReadAt)`;
`GiftGranted(PlayerId, Gems, Balance, RequestKey, Sender)` on `rpg.economy.events`.

`ApiErrors`: **1501** `InboxSendInvalid` (400: no players, more than 100, a title or body too long, gems out of range),
**1502** `InboxPlayerUnknown` (404, extension `playerIds`: nothing is sent when any is unknown). Roles: 1302 `AdminRequired` (403) as
today.

### 3.2 Postgres (migration `0013_player_inbox.sql`)

```sql
CREATE TABLE player_inbox (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  player_id uuid NOT NULL REFERENCES players,
  kind text NOT NULL CHECK (kind IN ('reward','message','gift')),
  sender text NOT NULL,
  title text, body text,
  gems int NOT NULL DEFAULT 0 CHECK (gems >= 0),
  payload jsonb,                               -- reward: {runId, seq, challengeId, characterId, ledgerId}
  source_key text NOT NULL UNIQUE,             -- 'reward:<ledger id>' | 'admin:<requestKey>:<player id>': the exactly-once key
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz);
CREATE INDEX player_inbox_unread ON player_inbox (player_id, id) WHERE read_at IS NULL;
CREATE INDEX player_inbox_player ON player_inbox (player_id, id DESC);
```

Rewards released before this migration get no message (the inbox starts empty). `wallet_ledger` gains the reason `gift` (its
idempotency key `gift:<requestKey>:<player id>`). Retention of read messages joins slice 7b's open item.

### 3.3 Limits (configuration)

`Inbox:MaxTitle` (80), `Inbox:MaxBody` (1000), `Inbox:MaxGems` (`Economy:MaxRewardAmount`), `Inbox:PageSize` (50), rate limit
bucket `actions` on `read`.

### 3.4 Redis, RabbitMQ

**N/A.** One indexed read per main-menu visit; `settled` and the inbox are read from Postgres. No new queue.

### 3.5 Godot

- `ServerLink`: `get_inbox()`, `mark_read(ids)` (retried in the background), `send_inbox(...)` (debug builds, admin: `#if DEBUG` in the
  bridge like the other admin calls); the end poll covers a lost run and ends on `settled`; the upload of a finished run from the save
  on coming online (`upload_finished_run`); every `begin_wait` offers Go offline.
- `ServerBridge.cs`: `GetInbox`, `MarkInboxRead`, `SendInbox` (`#if DEBUG`); `GameServerClient`: the three calls.
- `Inbox` (`game/inbox/`, pure): the notices from messages (grouping rewards by run and challenge, titles from the content index:
  "Defeated <enemy>", "<challenge>: <star description>", the id when unknown), the shown ids.
- `GameMain`: `leaving_blocked()` for a finished online run until settled; `go_offline()` works in a run (2.6).
- The notice `presentation/demo/ui/inbox_notice.tscn` (Modal, theme window, `UIScreen`: title, body, gems line, OK, OK to all) pushed by
  the main menu; the connecting pop-up's Go offline on every wait.
- Console (tool parity): `inbox [all]` (unread, or every message), `inbox read <id|all>`, `server inbox send <player|me> "<title>"
  "<body>" [gems=N]`, `wait inbox <n> [s]`, `wait settled [s]`, `server go-offline` in a run.

## 4. Failure modes

| Case | Behaviour | Test |
|---|---|---|
| Worker killed after commit, before ack (scenario 2) | the redelivered step finds the rows released: no second message, no second payment | `StepProcessorTests` (inbox rows counted), e2e `verify_worker_kill` checks one message per mark |
| The same step verified twice (scenario 1) | `source_key` unique + the release guard: one message | `StepProcessorTests` |
| Redpanda down (scenario 3) | messages are written in Postgres; their `InboxMessageCreated` events drain from the outbox later | `OutboxTests` case with the new topic |
| Redis flushed (scenario 4) | unaffected: nothing here reads Redis | `InboxTests` |
| A tampered battle (scenario 5) | the 2002 verdict voids its pending rows: no message; the rest of the run is paid and announced | `StepProcessorTests`, e2e `inbox_tampered` |
| A reward already paid this cycle, or voided by a rollback | no message | `StepProcessorTests` |
| An admin send repeated (same requestKey) | `alreadySent` counts it; no second message, no second gems | `InboxTests` |
| An admin send with an unknown player | 404 1502, nothing sent to anyone | `InboxTests` |
| A send without the role | 403 1302; gems without economy-admin: 403 1302 | `InboxTests` |
| Another player's ids in `read` | ignored (204), nothing changes | `InboxTests` |
| `read` lost (no answer) | retried in the background; at worst the notice shows again next session | `test_player_inbox` |
| Offline at the run's end, or Go offline while verifying | the main menu; the save keeps the finished run; uploaded and verified when back online; then its rewards show | `test_player_inbox`, e2e `inbox_offline_upload` |
| The game closed while verifying | the save keeps it; the next online start uploads and waits | `test_player_inbox` |
| Go offline in a run while a floor seed or the stairs wait | the run is saved; the main menu in local mode; Continue offers it Not synced | `test_player_inbox` |
| A rollback while verifying (1108) | play goes on at the checkpoint (today) | existing `test_run_authority` |
| Postgres down | 503 everywhere (today); the menu shows no notices this visit | `InboxTests`, `test_player_inbox` |
| More than 50 unread | the next visit shows the rest | `test_player_inbox` |
| Local mode | no inbox, no wait, no upload | `test_player_inbox` |

## 5. Observability

- `rpg_inbox_messages_created_total{kind}`, `rpg_inbox_messages_read_total`, `rpg_inbox_reads_total{result}`,
  `rpg_inbox_read_duration_seconds` (histogram), `rpg_inbox_sends_total{result}` (admin), `rpg_gifts_granted_gems_total`.
- `rpg_run_settle_wait_seconds{outcome}` (histogram): from a run's end request (or its queued end) to the first settled answer.
- `rpg_finished_run_uploads_total{result}` (a finished run uploaded on coming online: `settled`, `refused`).
- No player, message, item or challenge ids as labels.

## 6. Test plan

**.NET**
- `InboxTests` (API, Testcontainers): the read (unread, all, order, page size, another player's messages never seen); `read` (own ids
  only, idempotent, the event); the admin send (roles, validation, unknown player, idempotent key, a gift's wallet row, ledger row,
  account version and events in one transaction); `settled` on the summary (won, lost, rejected, legacy, an unverified tail); Redis
  stopped and flushed; 503 with Postgres stopped; the metrics.
- `StepProcessorTests` / `SettlementTests` (worker): a released row writes one reward message and its event; a redelivered step and a
  repeated release write none; AlreadyPaid and rollback voids write none.
- `MigrationTests`: 0013 on a database at 0012.
- `Rpg.Contracts.Tests`: golden JSON of the inbox records, the send records, the events, the summary with and without `settled`.

**Godot** (`tests/game/test_player_inbox.gd`, fixtures, fake bridge):
- `Inbox`: grouping, titles (boss, star, unknown), gifts and messages, OK to all.
- The main menu: reads on activation online only; one notice at a time; OK marks read; a lost `read` is retried and not shown again
  this session; nothing during a run or in local mode.
- The run's end: a won and a lost online run wait until settled; Go offline shows on the wait; Go offline and an unanswered server go
  to the main menu with the finished run saved; coming online uploads it ("Uploading your run…") and the inbox follows; a closed game
  resumes the upload; Continue never offers a finished run.
- Go offline on every wait (start, resume, floor seed, 1107, rebuild, account action, Go online); in a run it saves first.
- Console: `inbox`, `inbox read`, `server inbox send`, `wait inbox`, `wait settled`.

**e2e** (`tools/e2e.sh`, real server, worker and Godot): `inbox_rewards` (the titan party wins a paid boss: the wait ends settled, the
main menu's inbox holds the reward, `inbox read all` empties it), `inbox_tampered` (a tampered battle: no message for it),
`inbox_offline_upload` (the server stopped at the run's end: Go offline, the menu; the server back: the upload, settled, the reward),
`inbox_gift` (`server inbox send me … gems=50`: the wallet and the message), and `verify_worker_kill` extended (one message per mark).

**Window check:** shots of a reward notice, a gift, the verifying wait with Go offline and the upload wait, to
`H:\claudeOutShots\<date> player inbox\`; a live playtest on the dev stack.

**No golden changes:** nothing touches combat, the run log, a hash or a snapshot.

## 7. Review

Design history (user, 2026-11-20 and 21): a pop-up on the run-end screen → notices on the main menu, Isaac-style, acknowledged by a
click → acknowledgement on the client → rewards on `GET /runs/{id}` with the run verified before the menu → **a server inbox**
(2026-11-21: "it allows for communication to the player from support or the devs. It also adds a proper pipeline to have queued
messages like Isaac rewards once the run finishes on the main menu. We should add this slice before the game analytics as we will
probably have the web dashboard interact with the player like sending gems or messages"). Written in the paying transaction, not
through Kafka (a direct write is atomic with the payment; Redpanda carries the events about it). Kept from the earlier drafts: the
run verified before the menu, Go offline on every wait, the upload of a finished run when back online.

Open questions:

| # | Question | Proposal |
|---|---|---|
| Q1 | "If they are online the game can exit back to the main menu and save that there is a pending completed run": did you mean **offline**? | Yes, read as offline: online waits for verification (with Go offline); offline or Go offline goes to the menu and keeps the run to upload |
| Q2 | A gift's gems: in the wallet when sent (the message informs), or when the player presses Claim | When sent: one rule for every inbox message (it never decides money), no claim state, no expiry |
| Q3 | Skipping notices | One OK each, "OK to all" when more than three wait |
| Q4 | Rewards that were not paid (already earned this week, a voided battle): a message saying so? | No message |
| Q5 | An Inbox screen on the main menu to read old messages again | Not now: notices only; the table keeps read messages for a later screen |
| Q6 | A finished run waiting for its upload: may the player start a new run meanwhile (offline)? | Yes, in local mode (nothing paid); online, the upload runs first |
| Q7 | Roadmap place | Decided (user, 2026-11-21): **4e `player-inbox`**, built just before 4b `game-analytics`, not now |
