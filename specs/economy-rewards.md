# Spec: economy-rewards (slice 4c, the immediate next slice, before 4a)

Status: **spec written, review answers applied 2026-11-03**. Builds on `specs/settlement-outbox.md` (slice 4, implemented, not yet merged).
Decided 2026-11-03 with the user: (1) rewards are **per boss**, not flat; (2) they are **economy data owned by the server**,
not game content, so retuning one never changes the ruleset version; (3) the **account economy** (currencies, and from
slice 5 card ownership) lives **outside Godot** and is separate from the run's in-game inventory.

## 1. Purpose & enterprise mapping

**What this slice does.** It replaces slice 4's one configured number (`Settlement:GemsPerBossMark`) with a **versioned
reward-rule table** in Postgres, and it draws the line between the game and the economy so that cards (slice 5)
and anything that may one day involve real money have a home.

**The boundary (the design decision this slice records):**

| | The run (Godot) | The account economy (server) |
|---|---|---|
| Owns | the run's inventory: items found, equipment worn, HP, gold, keys, floors, battles | currencies (gems now, dust later), the ledger, reward rules, and from slice 5 **card ownership**, packs |
| Lives in | Godot, deterministic, replayed and verified | Postgres, owned by one module with one writer path |
| Truth is | the action log + the state hash | the **ledger** (append-only) and holdings tables |
| Changes by | the player's actions during a run | **verified facts** from a replay, or an explicit economy action (open pack, dust, trade) |
| Can change without a client patch | no (it is the ruleset) | **yes** (rules are data) |

Rules that follow from the table:
1. **Godot reports what happened, the economy decides what it is worth.** The replay says "boss `lich` was beaten by
   these characters" (`BattleFacts`, unchanged). It never says a gem amount. The server maps facts to value.
2. **Godot never holds a balance or an ownership record.** The client can show the account (`GET /wallet`, later the
   collection) but the run can never read it while playing or write it.
3. **Account to run is a one-way snapshot taken at run start** (slice 5): the server hands the run what the account
   entitles it to (which characters and unlocked item pools: the core set plus the collected cards) and the run records it in its start state,
   so a replay is still deterministic. A card in an active run is locked in the account (already in the roadmap's "run
   lock"). Nothing flows back from the run except through rule 1.
4. **Run to account is a one-way, idempotent grant**: verified fact in, ledger rows out, in one transaction (slice 4).
5. **One module owns the economy tables.** Nothing but the economy module reads or writes `wallets`, `wallet_ledger`,
   `completion_marks` or `reward_rules`. Today that module is a library (`src/Rpg.Economy/`) called by the worker and
   the API; it can become a service later without changing callers' contracts.

**Also in this slice: trace continuity through the outbox** (the open item from `specs/settlement-outbox.md` 9.1). Nothing
writes `outbox.traceparent` today, so one trace cannot follow a battle from the upload through the relay and the worker to
the event. This slice makes every outbox row carry the `traceparent` of the code that wrote it (3.8). It is folded in here
because this slice adds a new outbox writer (`RewardRuleChanged`) and moves the grant SQL into the economy module, which is
the same insert path.

**Dev tooling added with it:** a console command `server reward [<boss> <amount>]` (list, or set a rule) so Claude and the
user can drive the admin path headless, with the bridge and client methods behind it. This is the only Godot-side change.

**Backend components used:** PostgreSQL (rules, ledger, wallet, marks, outbox), the verifier worker (looks the rule up
inside the verdict transaction), the API (admin endpoints for rules, the existing wallet endpoint), the outbox and
Redpanda (`RewardRuleChanged`, and `RewardGranted` gains the rule version). **Not used:** RabbitMQ (no new queue),
Redis (rules are read from Postgres inside the transaction; see 3.5). No game rule, combat or run code changes in Godot.

**Out of scope, on purpose:** real-money purchases and payment providers (the model must not preclude them: every
ledger row says why and under which rule, and holdings will follow the same append-only pattern); card ownership,
packs and dust (slice 5; section 7 sketches how they plug in); pending gems and run-level
verification (4a); per-character or difficulty modifiers; timed multipliers (live-ops "double gems weekend").

## 2. Sequence flow

### 2.1 A designer sets a reward (admin path, no deploy)
```
Designer tool / curl                API                          Postgres
  PUT /api/v1/admin/reward-rules ─► auth: bearer with the economy-admin role (403 otherwise)
    { sourceKind:"boss", sourceId:"<boss id>", currency:"gems", amount: 25 }
                                    validate (kind known, amount 1..cap, id shape)
                                    one transaction: ─────────────► lock the (kind, id) key (advisory lock)
                                                                    version = max(version)+1
                                                                    INSERT reward_rules (new version)
                                                                    INSERT outbox RewardRuleChanged (redpanda)
                                    ◄───────────────────────────────── commit
  200 { …, version: 3, effectiveFrom }
```
Rules are **append-only**: a change is a new version, never an update. "Retire" a rule by PUT with `amount: 0`
(the latest version wins; amount 0 means no payout; see 4, F2).

### 2.2 Settlement with rules (the worker; changes only step 5c of slice 4 section 2.2)
```
5c. if Verified and Outcome = Victory and facts.bossIds is non-empty:
      for each distinct bossId in facts.bossIds:
        rule = SELECT … FROM reward_rules
               WHERE source_kind='boss' AND source_id=$bossId AND effective_from <= now()
               ORDER BY version DESC LIMIT 1                              (inside the verdict transaction)
        if rule is missing or rule.amount = 0:  no mark, no grant, count it (metric), carry on
        else for each distinct characterId in facts.partyCharacterIds:
          INSERT completion_marks (player, character, boss, battle) ON CONFLICT DO NOTHING
          if inserted:
            INSERT wallet_ledger (… delta = rule.amount, source_kind='boss', source_id=bossId, rule_version = rule.version,
                                  idempotency_key = 'mark:{battleId}:{characterId}:{bossId}') ON CONFLICT DO NOTHING
            UPSERT wallets (gems += rule.amount, version += 1) RETURNING gems
            INSERT outbox RewardGranted { …, amount, ruleVersion } (redpanda)
```
Everything else in slice 4 (the three gates, the outbox rows for the verdict events, the ack after the commit) is
unchanged. `Settlement:GemsPerBossMark` is removed; `Settlement:Enabled` stays.

### 2.3 Reading
`GET /api/v1/wallet` is unchanged (gems, version, recent ledger). `GET /api/v1/admin/reward-rules` (economy-admin)
lists the current rule per source. The client never sees rules.

## 3. Data contracts

### 3.1 C# records (`src/Rpg.Contracts/`, `Economy/`)
```csharp
namespace Rpg.Contracts.Economy;

public static class RewardSourceKinds { public const string Boss = "boss"; }        // later: "floor", "run"

/// <summary>PUT /api/v1/admin/reward-rules (economy-admin). A new version of the rule for one source.</summary>
public sealed record RewardRuleRequest(
    string SourceKind,     // RewardSourceKinds.*
    string SourceId,       // the boss definition id Godot reports in BattleFacts
    string Currency,       // "gems" (a CHECK list that slice 5 extends with "dust")
    int Amount);           // 0 retires the rule; otherwise 1..Economy:MaxRewardAmount

/// <summary>One version of a rule; the response of PUT and each item of GET.</summary>
public sealed record RewardRuleResponse(
    string SourceKind, string SourceId, string Currency, int Amount, int Version,
    DateTimeOffset EffectiveFrom, string CreatedBy);

public sealed record RewardRuleListResponse(IReadOnlyList<RewardRuleResponse> Rules);   // latest version per source

// Additive changes to slice 4 records:
//   RewardGrantedPayload gains: int RuleVersion
//   LedgerEntryDto gains:       int? RuleVersion   (null on rows written before this slice)
// New event payload, topic rpg.economy.events, key "rule:{sourceKind}:{sourceId}":
public sealed record RewardRuleChangedPayload(
    string SourceKind, string SourceId, string Currency, int Amount, int Version, int? PreviousAmount, string ChangedBy);
// EventTypes gains RewardRuleChanged. BattleFacts is UNCHANGED (BossIds = bosses beaten).
```
Error codes: `ApiErrors` gains **1301 RewardRuleInvalid** (400: unknown kind or currency, amount out of range, bad id)
and **1302 AdminRequired** (403). Both are plain request errors, not verdicts.

### 3.2 PostgreSQL: `Migrations/0005_reward_rules.sql`
```sql
CREATE TABLE reward_rules (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_kind text NOT NULL CHECK (source_kind IN ('boss')),
  source_id text NOT NULL CHECK (source_id <> '' AND source_id !~ '[:\s]'),   -- no ':' (ledger keys) and no spaces
  currency text NOT NULL CHECK (currency IN ('gems')),
  amount int NOT NULL CHECK (amount >= 0),
  version int NOT NULL CHECK (version >= 1),
  effective_from timestamptz NOT NULL DEFAULT now(),
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_kind, source_id, version));
CREATE INDEX reward_rules_latest ON reward_rules (source_kind, source_id, version DESC);

ALTER TABLE wallet_ledger
  ADD COLUMN source_kind text,            -- 'boss'; null on older rows
  ADD COLUMN source_id text,
  ADD COLUMN rule_version int;            -- null on older rows (they were paid by the flat Settlement:GemsPerBossMark)
```
No data is migrated: slice 4 is unreleased, so existing rows stay as they are with the new columns null. The
`wallets` and `completion_marks` tables are unchanged. The ledger key stays `mark:{battleId}:{characterId}:{bossId}`;
the new CHECK on `source_id` removes the ':' ambiguity for boss ids (the worker guards character ids; see F10).

### 3.3 RabbitMQ
N/A: no new queue. The verify job and the worker are unchanged.

### 3.4 Redpanda
`rpg.economy.events` gains `RewardRuleChanged` (keyed by `rule:{kind}:{id}`, schema version 1) and `RewardGranted`
gains `ruleVersion` and keeps `amount`. Consumers dedupe on `EventId` as before.

### 3.5 Redis
None. The worker reads the rule inside the verdict transaction (one indexed query per beaten boss), which is the only
way a change and a grant can never disagree. If volume ever needs a cache it must be read-through with a short TTL and
the ledger's `rule_version` still records what was used; not needed now.

### 3.6 HTTP
| Endpoint | Auth | Answer |
|---|---|---|
| `PUT /api/v1/admin/reward-rules` | bearer with role `economy-admin` | 200 `RewardRuleResponse`; 400 1301; 403 1302 |
| `GET /api/v1/admin/reward-rules` | same | 200 `RewardRuleListResponse` |

The client side (`Rpg.Client`): `PutRewardRuleAsync(RewardRuleRequest)` and `ListRewardRulesAsync()`; `ServerBridge`: `PutRewardRule(json)` and
`ListRewardRules()`; console `server reward [<boss> <amount>]` (no arguments: list). The harness gives the e2e player the
role through `Auth__DevAdmins__0=<player>`.

`economy-admin` is a claim on the JWT. In Development the dev-token endpoint issues it to names listed in
`Auth:DevAdmins`; there is no other way to get it. **Known limitation (stated, not solved here):** real operator
identity (SSO, per-person audit, MFA) is not built; the admin path is a dev and demo mechanism until a real identity
provider exists, and `Auth:DevAdmins` has no effect outside Development (a test proves it, like `AutoApproveWins`).

### 3.7 Configuration
API: `Economy:MaxRewardAmount` (default 100000), `Economy:SeedRules` (an optional array applied at startup, only for
sources that have no rule yet; used by demos and the e2e harness), `Auth:DevAdmins` (Development only).
Worker: `Settlement:Enabled` (unchanged). Removed: `Settlement:GemsPerBossMark`.

### 3.8 Trace continuity (no wire change)
`OutboxMessage` (in `Rpg.Verification`) gains an optional `TraceParent`; `OutboxWriter.InsertAsync` fills it from
`Activity.Current` (W3C `traceparent`, `00-<trace id>-<span id>-<flags>`) when the caller passes none. All three writers are covered
without touching their call sites: the upload transaction (`VerifyBattleJob`), the worker's verdict transaction (the
`BattleVerified`, `BattleRejected` and `RewardGranted` rows, which carry the **worker's** span, so an event links back to the
replay that caused it) and the admin rule change (`RewardRuleChanged`). The relay already parents its `outbox.publish` span on
the row's value and sends it as the `traceparent` header (Kafka and RabbitMQ); the verify worker already continues the trace
from that header. A missing, empty or malformed value is ignored: the span simply has no parent and the publish never fails.

## 4. Failure modes

| # | Situation | Behaviour | Test |
|---|---|---|---|
| F1 | A boss was beaten but has **no rule** | nothing is granted **and no completion mark is written**, so adding the rule later still pays that character's first win. The verdict still commits; `rpg_reward_rule_lookups_total{result="missing"}` counts it | `NoRule_GrantsNothing_WritesNoMark_AndALaterRulePaysTheNextWin` |
| F2 | The latest rule has amount 0 (retired) | treated like F1 | `RetiredRule_PaysNothing` |
| F3 | A rule is changed while a battle is being settled | the worker reads the rule inside its transaction, so it pays exactly one version and records it in the ledger; the next grant uses the new one | `RuleChangedBetweenTwoBattles_EachLedgerRowRecordsItsVersion` |
| F4 | Two admins PUT the same source at once | the advisory lock on (kind, id) serialises them; versions are consecutive, no gap, no duplicate (also protected by `UNIQUE`) | `ConcurrentPuts_ProduceConsecutiveVersions` |
| F5 | Invalid request (unknown kind or currency, amount < 0 or over the cap, id with ':' or spaces) | 400 1301, nothing written | `InvalidRule_Is400_1301` |
| F6 | Caller is not `economy-admin` or not authenticated | 403 1302 / 401, nothing written | `Admin_RequiresTheRole`, `DevAdmins_HasNoEffectOutsideDevelopment` |
| F7 | A redelivered job or a second worker settles the same battle | unchanged from slice 4: the three gates make it a no-op, whatever the rule now says | slice 4 tests, re-run with rules |
| F8 | The rule write succeeds but the event write fails | one transaction: both or neither | `RuleChange_AndItsEvent_AreOneTransaction` |
| F9 | `SeedRules` and an admin PUT disagree | seeds only fill sources with **no** rule; an admin version always wins and a restart never overwrites it | `SeedRules_NeverOverwriteAnAdminRule` |
| F10 | A character or boss id in `BattleFacts` contains ':' or whitespace (the ledger key `mark:{battle}:{character}:{boss}` would be ambiguous: `a:b` + `c` and `a` + `b:c` build the same key, so the second grant would be skipped as a duplicate) | the worker refuses to grant for that pair: no mark, no ledger row, `rpg_settlements_total{result="bad_id"}`, the verdict still commits. Content ids use dots, so this is a guard against a future bad id, not a case seen today | `AnIdWithAColon_IsNeverGranted_AndTheVerdictStillCommits`, `TwoColonIds_NeverShareALedgerKey` |
| F11 | An outbox row has no or a malformed `traceparent` (older rows, a writer with no active span) | the relay publishes it with no parent span and no `traceparent` header; nothing fails and nothing is retried | `ARowWithNoTraceParent_StillPublishes`, `AMalformedTraceParent_IsIgnored` |

**Acceptance scenarios covered.** 1 and 2 (duplicate submission, worker killed) still hold with variable amounts: the
existing slice 4 tests and the `verify_worker_kill` e2e are re-run against rules and must still show one settlement.
3 (Redpanda down) is unaffected; the new event rides the same outbox. No new acceptance scenario is added by this slice.

## 5. Observability

| Metric | Type | Labels |
|---|---|---|
| `rpg_reward_rule_lookups_total` | counter | `result` = `found` \| `missing` \| `retired` |
| `rpg_reward_rule_changes_total` | counter | `result` = `ok` \| `invalid` \| `forbidden` |
| `rpg_gems_granted_total` (exists) | counter | `reason` (unchanged; now sums real amounts) |
| `rpg_settlements_total` (exists) | counter | `result` gains `no_rule` |

Never a boss id or a rule id as a label. No new metric for trace continuity; the proof is in the spans: the `outbox.publish` span's
parent is the span that inserted the row, and the event row's `traceparent` is the worker's. A rising `missing` count is the signal that a boss was added to the game
without a reward rule; the Grafana "Battle verification" dashboard gets one panel for it. The ledger's `rule_version`
column is the audit trail for "why did this player get 25".

## 6. Test plan

- **Contract goldens:** `RewardRuleRequest`, `RewardRuleResponse`, `RewardRuleListResponse`, `RewardRuleChangedPayload`,
  `RewardGrantedPayload` with `ruleVersion`; slice 4's goldens still read (additive fields).
- **Economy library (Testcontainers):** rule lookup picks the latest version; effective-from in the future is ignored;
  F1-F4, F8, F9; the `source_id` CHECK refuses ':' and spaces.
- **Worker:** a boss with a 25-gem rule pays 25 to each party character and writes `rule_version`; two bosses with
  different rules in one battle; F1 and F2 (no mark written); F3 (version recorded per row); the slice 4 settlement
  tests re-run with a seeded rule instead of the flat config.
- **API:** F5, F6, the admin list, the `RewardRuleChanged` event and its outbox row.
- **Trace continuity (Testcontainers, an `ActivityListener`):** an upload stores the request's `traceparent` on its outbox row and
  the relay's publish span has that parent (the Kafka and RabbitMQ `traceparent` header equals it); the worker's event rows store
  the worker's `traceparent` (not the upload's); `RewardRuleChanged` stores the admin request's; F11.
- **Console (`test_e2e_tools`, fake bridge):** `server reward` lists the rules; `server reward <boss> <amount>` sends the
  PUT and prints the new version; a non-admin refusal (403 1302) is reported, not swallowed; usage errors fail.
- **e2e (`tools/e2e.sh`, on demand):** `settle_boss` sets its rule through the admin step (a new `e2e reward-rule
  <boss> <amount>` control action calling the endpoint) and asserts the wallet equals the rule times the marks and
  the ledger rows carry the rule version; **new `reward_rule_change`**: beat the boss with rule v1, raise it, beat it
  with another character, and assert each ledger row carries its own version and amount; `verify_worker_kill` re-run.
- **Godot:** only the dev console command and the bridge methods change, so every golden and every game test stays as
  it is (that is the point of the boundary). `test_tool_parity` covers the new command.

## 7. Decisions, what stays out, and how slice 5 plugs in

**Decided 2026-11-03:**
1. Rewards are rows in a server-owned table, not content and not configuration. Consequence: retuning an economy
   number does not touch the ruleset version, so slice 9's routing is not involved.
2. Godot reports facts, never value (`BattleFacts` unchanged).
3. A boss with no rule pays nothing and writes no mark (F1), so adding a boss to the game before its reward is set
   loses nothing.
4. The economy is one module (`src/Rpg.Economy/`: rule lookup, ledger write, wallet upsert, the SQL for them) used by
   the worker and the API. Slice 4's grant SQL moves out of `VerdictStore` into it, with no behaviour change and the
   existing tests as proof.
5. Admin access is a JWT role, dev-only for now (3.6).

**How cards (slice 5) fit without another redesign** (a sketch to constrain this slice, not a spec):
- Ownership is a server table (`card_holdings`: player, card id, copies) with an append-only `card_ledger` beside the
  currency ledger, each row naming its cause (pack opened, dusted, crafted, traded) and idempotent by a request key.
  Same pattern, same module, same transaction-plus-outbox rule. Godot never writes either.
- The run reads the account once, at run start, as a snapshot (rule 3 in section 1); the run lock keeps those cards
  from being dusted or sold meanwhile.
- Gems spent on packs, dust from dusting are more ledger rows. `reward_rules.currency` and
  `wallet_ledger.currency` CHECK lists widen in slice 5's migration. Pack odds and prices are table data like rewards.
- Real money, if ever added, is a source of ledger credits behind a payment provider's webhook, with the same
  idempotency key discipline; nothing in the run or the replay changes.

**Stays out:** timed multipliers and live-ops events, per-character or difficulty modifiers, floor and run-win
rewards (the `source_kind` column is ready for them), a rules admin UI, rule caching, real operator identity.

## 8. Decisions on the open items (2026-11-03)

1. **The demo's reward numbers: a seed file, proposed below, amounts yours to tune.** The demo has many bosses on The
   Descent and, with no rule, each pays nothing (F1). `infra/economy/reward_rules.json` lists every boss id with an amount
   and is loaded through `Economy:SeedRules`, which fills only sources that have no rule yet, so an admin edit is never
   overwritten by a restart. I fill it with placeholder amounts by chapter (an obvious ramp, flagged as placeholders in
   the file) so the game pays something from the first run; you retune them, either in the file (a fresh database) or
   live through the admin endpoint or the console. The file lives in `infra/`, outside your design folders. A small
   script, `tools/check_reward_seed.sh`, lists every `Enemy.Boss` in `content/` that has no entry in the file; it is a
   report for you, **not a test**, so adding a boss to the game can never fail the suite (system tests never depend on
   your content). The `missing` metric is the runtime safety net.
2. **Slice order.** This is the **immediate next slice**, built before 4a. The roadmap now carries `4c. economy-rewards`
   as "Next" (after slice 4 is committed and synced). Prerequisite: slice 4 is committed.
3. **Console command for Claude.** `server reward [<boss> <amount>]` is in scope (sections 1, 3.6, 6).
4. **Placeholders accepted:** the 100000 cap and the gems-only currency list stay until slice 5.
5. **Trace continuity is part of this slice** (decided 2026-11-03, the open item `settlement-outbox` 9.1), see 3.8.
