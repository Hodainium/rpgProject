# Spec: economy-challenges (slice 4d, after 4c, before 4a and slice 5)

Status: **implemented 2026-11-06, synced to the code the same day.** Builds on `specs/economy-rewards.md` (slice 4c, commit
`f501e4e`). The first draft modelled a reward as a *ladder of tiers*; during implementation the user decided against tiers
(see "Decisions"), and this document describes what was built.

Decided with the user on 2026-11-04 and 2026-11-06: (1) **the unit is the challenge id**: a reward belongs to a challenge, and
a fact says "challenge X was completed"; **a boss is never keyed by its own id**: its challenge id is derived from it by one
deterministic rule (1.1); (2) **there are no tiers**: a challenge pays one amount, once per cycle, and a score band is several
independent challenges (a *star* each, in content); (3) the reset is **weekly at a fixed UTC boundary** (ISO week, Monday
00:00), never configurable per challenge; (4) **event challenges expire**; (5) **a cycle can be reset by hand**, for everyone
or one player, and a Development-only clock offset lets a test cross a week boundary without waiting; (6) **challenge
conditions are data**: a star is a list of `ChallengeCondition` resources (turns, units with a GAS tag query or attribute test,
event counts, AllOf / AnyOf / Not), never hard-coded kinds; (7) **stars are independent**: each is earned on its own, in any
order (star 3 without star 2).

## 1. Purpose & enterprise mapping

**What this slice does.** It generalizes slice 4c's "boss → one amount, once ever" into **challenge → one amount, per cycle**.
A *challenge* is anything a player can complete and be rewarded for: beating a boss, or one star of an encounter's challenge
in the content. The same table, admin path and settlement code serve a once-ever boss reward, a weekly bounty and a limited
event.

| | Boss, once (4c today) | Weekly boss bounty | A content star (weekly) |
|---|---|---|---|
| Challenge id | `boss/demo.enemy.lich` (derived) | `boss/demo.enemy.lich` | `demo.challenge.lich_trial.fast` (challenge id + star id) |
| Amount | 25 | 25 | 5 |
| Cycle | `once` | `weekly` | `weekly` or `once` |
| Ends at | none | none | the event's end date, if any |
| Fact Godot reports | `BossIds` (as today) | same | `Completions: [{challengeId}]` |

### 1.1 Challenge ids and the boss link
A **challenge id** is a key-safe string (1–200 characters, no `:` and no whitespace; `/` and `.` are fine). It is the only
key of a reward, a mark and a ledger row; there is no separate "kind".

**A boss's challenge id is derived, never typed:** `ChallengeIds.ForBoss(bossId) = "boss/" + bossId`. It is a pure function in
`Rpg.Economy` with a **shared vector file** (`tests/Rpg.Contracts.Tests/golden/challenge-id-vectors.json`) that the .NET tests
read. Rules:
1. **The server derives it, Godot does not.** Godot keeps reporting `BossIds` (the verified fact "this boss was beaten"). The
   worker turns each into `ForBoss(bossId)` before settling.
2. **The prefix `boss/` is reserved.** An authored completion fact (`Completions`) may not use it (counted `ignored_fact`), so a
   challenge cannot masquerade as a boss clear. The console builds boss ids for you: `server reward boss <bossId> …`.
3. **Deterministic and total:** an invalid boss id (not key-safe, or over 195 characters so the derived id would pass 200)
   gives no challenge and is dropped as `bad_id`.
4. **A star's reward id is `<challenge id>.<star id>`** (built by the Godot content, see 3.8). Each star has its own rule, so
   its amount, cycle and end are set per star. "Harder than a plain win" is a star with conditions, never a tier.

**The rules that follow (extending the boundary of 4c):**
1. **Godot reports what happened; the server decides what it is worth.** A fact is a challenge id. Amounts are server data.
2. **Once per cycle.** Per player, character, challenge and cycle key, the first completion pays and writes the mark; the rest
   pay nothing.
3. **A cycle is a key, not a delete.** The mark carries a `cycle_key` (`once`, or `2026-W45`, plus `.r<n>` / `.p<n>` after
   resets), so a reset is "a new key has no mark yet". Old weeks and generations stay for audit; no job clears anything.
4. **Fixed boundary, battle time.** The week is the ISO 8601 week in UTC of the battle's `submitted_at` (not the verdict time),
   so a battle played late Sunday and verified Monday still counts for Sunday, and redelivery computes the same key.
5. **Expiry is by battle time too.** A challenge with `ends_at` pays nothing for a battle submitted at or after it, and writes
   no mark.
6. **A cycle can be reset by hand** (1.2), for live ops ("run the event again") and for tests.

### 1.2 Resetting a cycle, and testing without waiting a week
- **Manual reset (any environment, role `economy-admin`):** `POST /api/v1/admin/reward-cycles/reset { challengeId, playerId?, reason? }`
  appends a row to `reward_cycle_resets`. Two scopes:
  - **Everyone** (`playerId` omitted): the challenge's **global generation** goes up by one ("run the event again").
  - **One player** (`playerId` given): that player's **generation for that challenge** goes up by one (a support or test tool).

  The cycle key gains `.r<global>` when the global generation is above 0 and `.p<player>` when the player's is above 0 (both can
  apply: `2026-W45.r1.p2`). Marks under the old key are untouched but no longer match, so the next clear pays again. It resets
  `once` challenges too. It never claws anything back. It writes a `RewardCycleReset` event. Console:
  `server reward-reset [boss] <id> [player=me|<playerId>] [reason]`.
- **Clock offset (Development only):** `Settlement:CycleClockOffset` (a time span, default zero) is added to the battle's
  `submitted_at` for the cycle key and for `ends_at`. The worker ignores it, and logs a warning, in any environment but
  Development (a test proves it).

**Backend components used:** Postgres (rules, resets, marks, ledger, wallet, outbox), the verifier worker (settlement inside
the verdict transaction), the API (admin endpoints), the outbox and Redpanda (`RewardRuleChanged`, `RewardCycleReset`,
`RewardGranted`). **Not used:** RabbitMQ (no new queue), Redis.

**Out of scope, on purpose:** run-level and floor-level completions (the fact shape is ready, 4a will emit them); a
player-facing progress read; multipliers and boosts; items and cards as rewards (slice 5 widens the currency list); per-challenge
cycle lengths.

## 2. Sequence flow

### 2.1 A designer sets a reward (admin path)
```
PUT /api/v1/admin/reward-rules           (role economy-admin)
  { challengeId:"demo.challenge.lich_trial.fast", currency:"gems", amount:5, cycle:"weekly", endsAt:"2026-12-01T00:00:00Z" }
  validate (id key-safe, currency, cycle, amount 0..cap, endsAt in the future)
  one transaction: advisory lock on challenge id → version = max+1; INSERT reward_rules; INSERT outbox RewardRuleChanged
  200 { …, amount, cycle, endsAt, generation, version, effectiveFrom }
```
`amount: 0` retires the challenge. A rule is replaced as a whole (a new version), so its amount, cycle and end never disagree.

### 2.2 A manual reset
```
POST /api/v1/admin/reward-cycles/reset { challengeId, playerId?, reason? }     (role economy-admin)
  the challenge must have a rule, and the player (when given) must exist (else 404 1303)
  one transaction: advisory lock on (challenge id, player id or 'all')
                   → INSERT reward_cycle_resets (generation = previous in that scope + 1, reset_by, reason); INSERT outbox RewardCycleReset
  200 { challengeId, playerId?, generation, resetAt, resetBy }
```

### 2.3 Settlement (the worker; replaces step 5c of 4c)
```
Input: the Verified Victory's facts, and the battle's submitted_at.
completions = facts.BossIds mapped by ChallengeIds.ForBoss         (an invalid boss id → bad_id)
            ∪ facts.Completions                                    (a "boss/…" or bad id → ignored_fact)
            → merged by challenge id
at = submitted_at + Settlement:CycleClockOffset (Development only, otherwise zero)
for each challenge id:
  rule = latest version with effective_from <= the battle's submitted_at (battle time, C10), read inside the transaction
  if none or retired:     count missing/retired, no mark, carry on
  if rule.ends_at ≤ at:   count expired, no mark, carry on
  global/player generation = max(generation) of the resets for (challenge, everyone) and (challenge, this player), 0 if none
  cycle_key = (rule.cycle = 'once' ? 'once' : ISOYear + '-W' + ISOWeek(at, UTC)) + ('.r' + global) + ('.p' + player)   (suffixes when > 0)
  for each distinct character in facts.PartyCharacterIds:
    INSERT completion_marks (player, character, challenge_id, cycle_key, battle) ON CONFLICT DO NOTHING   → 0 rows: already paid
    INSERT wallet_ledger (… delta = rule.amount, challenge_id, rule_version, cycle_key,
                          idempotency_key = 'mark:{battleId}:{characterId}:{challengeId}') ON CONFLICT DO NOTHING
    UPSERT wallets (gems += amount, version += 1); INSERT outbox RewardGranted { …, challengeId, cycleKey }
```
The three exactly-once gates of slice 4 hold: the session guard, the mark row, and the ledger key. The whole rule (amount,
`rule_version`, retirement, cycle and end time) is the version that was in force at the battle's `submitted_at`
(battle time; the user, 2026-11-09, closing a review finding: the amount, the retirement and the cycle used to be read at
the verdict while the end time was read at the battle, so a challenge retired or re-cycled between a battle and its verdict
paid nothing or paid under the new cycle, and a rule created after a battle paid it). A rule put by mistake and corrected
later therefore still pays its amount for battles fought before the correction. Both generations are read in the same
transaction, and they too count only the resets made by the battle's submit time (C21).

### 2.4 Reading
`GET /api/v1/wallet` is unchanged apart from two optional ledger fields (`challengeId`, `cycleKey`). `GET /api/v1/admin/reward-rules`
lists the current rule per challenge, with its global generation.

## 3. Data contracts

### 3.1 C# records (`src/Rpg.Contracts/`)
```csharp
namespace Rpg.Contracts.Economy;
public static class RewardCycles { public const string Once = "once"; public const string Weekly = "weekly"; }
// RewardSourceKinds is REMOVED (the challenge id is the one key).

/// PUT /api/v1/admin/reward-rules. A new version of one challenge's reward. REPLACES slice 4c's kind/id.
public sealed record RewardRuleRequest(string ChallengeId, string Currency, [JsonRequired] int Amount,   // 0 = retire; required
    string Cycle = RewardCycles.Once, DateTimeOffset? EndsAt = null);                                    // null = never expires
public sealed record RewardRuleResponse(string ChallengeId, string Currency, int Amount, string Cycle, DateTimeOffset? EndsAt,
    int Generation, int Version, DateTimeOffset EffectiveFrom, string CreatedBy);
// RewardRuleListResponse: unchanged (latest rule per challenge).

public sealed record RewardCycleResetRequest(string ChallengeId, Guid? PlayerId = null, string? Reason = null);   // PlayerId null = everyone
public sealed record RewardCycleResetResponse(string ChallengeId, Guid? PlayerId, int Generation, DateTimeOffset ResetAt, string ResetBy);

namespace Rpg.Contracts.Battle;
/// One challenge the battle completed. Bosses stay in BossIds.
public sealed record CompletionFact(string ChallengeId);
// BattleFacts gains: IReadOnlyList<CompletionFact>? Completions = null   (omitted from JSON when null)

namespace Rpg.Contracts.Events;
// RewardGrantedPayload gains (additive, schema version stays 1): string ChallengeId, string CycleKey.
//   BossId stays, filled when the challenge id is "boss/…" (the boss id) and null otherwise (kept for slice 4 consumers).
// RewardRuleChangedPayload: SourceKind/SourceId become ChallengeId; + Cycle, EndsAt; PreviousAmount stays.
// New RewardCycleResetPayload(ChallengeId, PlayerId?, Generation, ResetBy, Reason?); EventTypes.RewardCycleReset; key "rule:{challengeId}".
//   Nothing consumes rpg.economy.events yet, so these are version-1 corrections, not a v2.
// LedgerEntryDto gains: string? ChallengeId, string? CycleKey (null on older rows).
```
Error codes: **1301 RewardRuleInvalid** also covers an unknown `cycle` and an `endsAt` in the past. New **1303 RewardTargetUnknown**
(404, a reset for a challenge with no rule or a player that does not exist).

### 3.2 PostgreSQL: `Migrations/0006_reward_challenges.sql`
- `reward_rules`: `source_id` → `challenge_id` (4c rules move to `boss/<id>`), `source_kind` dropped, `+ cycle`, `+ ends_at`,
  `UNIQUE (challenge_id, version)`.
- `reward_cycle_resets (challenge_id, player_id null, generation, reset_by, reason, reset_at)`, unique per scope and generation.
- `completion_marks`: `boss_id` → `challenge_id`, `+ cycle_key` (existing rows: `once`), primary key
  `(player_id, character_id, challenge_id, cycle_key)`. The row's existence is "paid for this cycle".
- `wallet_ledger`: `source_id` → `challenge_id`, `source_kind` dropped, `+ cycle_key`; older rows stay null.

Existing data keeps its meaning (a 4c boss rule becomes `boss/<id>`, cycle `once`; a mark becomes the `once` cycle). The ledger's
key is `mark:{battleId}:{characterId}:{challengeId}`; the challenge id has no `:` (key-safe), so the key is unambiguous.

### 3.3 RabbitMQ
N/A: no new queue.

### 3.4 Redpanda
`rpg.economy.events`: `RewardGranted`, `RewardRuleChanged` and the new `RewardCycleReset` as in 3.1. Keys: `playerId` for
grants, `rule:{challengeId}` for rule events. Consumers dedupe on `EventId`.

### 3.5 Redis
None.

### 3.6 HTTP and console
| Endpoint | Auth | Answer |
|---|---|---|
| `PUT /api/v1/admin/reward-rules` | role `economy-admin` | 200 `RewardRuleResponse`; 400 1301; 403 1302 |
| `GET /api/v1/admin/reward-rules` | same | 200 `RewardRuleListResponse` |
| `POST /api/v1/admin/reward-cycles/reset` | same | 200 `RewardCycleResetResponse`; 400 1301; 403 1302; 404 1303 |

Console: `server reward` lists. `server reward <challengeId> <amount> [cycle=once|weekly] [ends=<UTC ISO>]` sets;
`server reward boss <bossId> <amount> …` is the same for `boss/<bossId>`; `0` retires. `server reward-reset [boss] <id>
[player=me|<playerId>] [reason]` resets a cycle. Client side: `PutRewardRuleAsync`, `ListRewardRulesAsync`, `ResetRewardCycleAsync`
(admin calls stay inside `#if DEBUG` in `ServerBridge`).

### 3.7 Configuration
API: `Economy:MaxRewardAmount` (unchanged). `Economy:SeedRules` / `infra/economy/reward_rules.json` use `challengeId` + `amount`
(+ `cycle`); seeds still fill only challenges with no rule. Worker: `Settlement:CycleClockOffset` (Development only, default
`00:00:00`), `Settlement:Enabled` (unchanged).

### 3.8 Content: challenges and stars (Godot, `combat/`)
- `ChallengeDefinition` (`id`, `display_name`, `encounter_id`, `stars`) is a content resource indexed by `ContentIndex.challenges`.
- `ChallengeStar` (`id`, `description`, `conditions`): earned when the battle was won and **every condition holds**; no conditions
  means "win". Stars are independent and unordered: one can be earned without another.
- `ChallengeCondition` is the abstract base (`met(battle, tally)`, `describe()`, `problems()`); built-ins: `ChallengeTurnsCondition`,
  `ChallengeUnitsCondition` (side, quantifier ALL/ANY/NONE, alive filter, a `GameplayTagQuery`, an attribute or percent-of-attribute
  comparison), `ChallengeEventCondition` (events of a tag received by a side, counted by `ChallengeTally`), and the composites
  `ChallengeAllOf`, `ChallengeAnyOf`, `ChallengeNot`. A new kind is a new subclass; nothing else changes.
- The replay reports one completion per earned star, `"<challenge id>.<star id>"` (`ReplayRunner._completions`), absent when the
  encounter has no challenge, so every existing fact and golden is unchanged. Facts are never hashed.
- The validator checks challenges (`bad_challenge`): key-safe id, not under `boss/`, known encounter, at least one star, star ids
  unique and key-safe, every condition's `problems()`.
- Content: `tests/fixtures/challenges/boss_trial.tres` (win / fast / flawless on the boss encounter) and the demo's
  `content/demo/challenges/lich_trial.tres`.

## 4. Failure modes

| # | Situation | Behaviour | Test |
|---|---|---|---|
| C1 | Same battle settled twice (redelivery, two workers) | the session guard, then the mark, then the ledger key | `RedeliveredBattle_PaysEachChallengeOnce`, `TheLedgerKey_StopsADoublePayment…` |
| C2 | Independent stars in any order | each pays on its own; star 3 without star 2 is fine | `EachStarIsItsOwnChallenge_PaidOnItsOwn_InAnyOrder`, `OneBattle_PaysEveryStarItEarned…` |
| C6 | A completion fact with a bad id or the reserved `boss/…` prefix | dropped and counted (`ignored_fact`); other facts and the verdict still commit | `BadCompletionFacts_AreDropped…`, `AuthoredFact_CannotUseTheBossPrefix` |
| C7 | A new week starts (ISO week changes) | the `cycle_key` differs, so no mark exists and it pays again; last week's rows are untouched | `WeeklyChallenge_PaysOncePerWeek_AndAgainInTheNext` |
| C8 | The week boundary | a battle submitted Sunday 23:59:59 UTC counts for that week even if verified on Monday | `WeekBoundary_UsesSubmissionTime` |
| C9 | ISO year edge | the key uses the ISO year and week, never the calendar year | `IsoWeekKey_AtYearEnd` |
| C10 | The event has ended (`ends_at ≤ submitted_at`) | nothing is paid, no mark; counted `expired`. A battle submitted before the end but verified after still pays. The same holds for every field of the rule: a retirement, a cycle change or a new rule put after the battle was submitted does not change what it pays | `EndedEvent_PaysNothing…`, `BattleSubmittedBeforeTheEnd_StillPays…`, `TheRuleAtTheBattlesTime_Pays_NotOneChangedBeforeTheVerdict` |
| C11 | The designer edits a rule (amount, cycle) | a new version; marks already written stay; switching `once` → `weekly` pays again on the next clear (new key); switching back reuses the old `once` mark | `RuleEdit_PaysTheNewAmount_OnlyWhereNothingWasPaid`, `CycleSwitch_UsesTheNewKey…` |
| C13 | Two battles of one player and character settled at once | the mark's primary key serialises them; nothing is paid twice | `ConcurrentBattles_NeverPayTheSameChallengeTwice` |
| C14 | One battle reports the same challenge twice | merged by challenge id, one pass | `DuplicateFacts_AreMerged…` |
| C15 | An invalid PUT (bad cycle, amount out of range, `endsAt` in the past, a bad id) | 400 1301, nothing written | `InvalidRule_Is400_1301…` |
| C16 | A challenge with no rule, or retired | as 4c F1/F2: nothing paid, no mark, so a later rule pays the next win | `ACompletionWithNoRuleOrARetiredOne…` |
| C17 | Concurrent admin PUTs on one challenge | the advisory lock keeps versions consecutive | `ConcurrentPuts_ProduceConsecutiveVersions` |
| C18 | A manual reset for everyone | global generation +1; the next clear pays again under the new key; old marks and ledger rows stay | `Reset_LetsTheNextClearPayAgain_AndKeepsHistory` |
| C19 | A reset of a challenge with no rule, an unknown player, or a bad id; a non-admin caller | 404 1303 / 404 1303 / 400 1301 / 403 1302; nothing written | `AResetOfUnknownTargets…`, `Admin_RequiresTheRole` |
| C20 | Two resets at once in one scope | the advisory lock gives consecutive generations (also the unique index) | `ConcurrentResets_AreConsecutive…` |
| C21 | A battle is settled after a reset but was played before it | pays under the generations **as of the battle's submit time**, like the rule (battle time; the user, 2026-11-09): a reset made after the fight does not move it to the new cycle, a fight after the reset pays in the new one | `BattlePlayedBeforeAReset_PaysInTheOldGeneration_EvenSettledAfterIt` |
| C22 | `Settlement:CycleClockOffset` outside Development | ignored, with a warning; inside it, the cycle key and `ends_at` use `submitted_at + offset` | `ClockOffset_IsIgnoredOutsideDevelopment`, `ClockOffset_MovesTheWeekAndTheEnd` |
| C23 | A boss id the rule cannot map | no challenge id, no grant, `bad_id` counted, the verdict commits | `ForBoss_IsDeterministicAndTotal`, `AnInvalidBossId_IsNeverGranted…` |
| C24 | A reset for one player | only that player's key changes (`.p<n>`); a later global reset stacks (`.r1.p1`) | `PlayerReset_AffectsOnlyThatPlayer`, `PlayerAndGlobalReset_Stack` |

**Acceptance scenarios covered.** 1 (duplicate settlement) and 2 (worker killed after commit) are proven for challenge payouts:
C1 and `verify_worker_kill`. Scenario 3 (Redpanda down) is unchanged: more event types on the same outbox.

## 5. Observability

| Metric | Type | Labels |
|---|---|---|
| `rpg_reward_rule_lookups_total` (exists) | counter | `result` gains `expired` |
| `rpg_completion_marks_total` | counter | `result` = `new` \| `existing` |
| `rpg_reward_cycle_resets_total` | counter | `result` = `ok` \| `unknown` \| `forbidden` \| `invalid` |
| `rpg_settlements_total` (exists) | counter | `result` gains `ignored_fact` |
| `rpg_gems_granted_total` (exists) | counter | `reason` (sums real amounts) |

Never a challenge id, character id or week key as a label. A resets spike on the dashboard is how an operator notices a manual
reset in production. The ledger's `rule_version` and `cycle_key` are the audit trail for "why did this player get 10 gems on
2026-W46.r2".

## 6. Test plan

- **Contract goldens:** the rule request and response (a boss, a weekly with an end), the reset request and response,
  `BattleFacts` with and without `Completions` (a golden without the field is byte-identical to slice 4), the events, the ledger entry.
- **Shared vectors:** `challenge-id-vectors.json` for `ChallengeIds.ForBoss`.
- **Economy and API (Testcontainers):** rules, validation, caps, seeds, concurrent puts, resets (C17–C20, C24), the migration on a
  database holding 4c-shaped rows.
- **Worker settlement:** `ChallengeSettlementTests` (C1–C16, C21–C24) through the harness with `Completions` injected.
- **Godot:** `test_challenges` (conditions, tally, composites, tag queries, the replay fact, the validator),
  `test_battle_facts` (the wire shape against the C# golden), console tests for `server reward` and `server reward-reset`, the
  admin calls staying out of the player build.
- **e2e (on demand):** `reward_challenge` (real Godot replays the fixture challenge's stars, the worker pays each star),
  `reward_stars` (three independent challenges through the worker's test stub, paid again after a player reset and a reset for
  everyone), `reward_clock_offset`, `reward_reset`, and the existing boss scenarios on `boss/…` ids.

## 7. Decisions, what stays out

**Decided:** the challenge id is the one reward key; a boss gets a derived id (`boss/<id>`) the server computes; **no tiers**: a
challenge pays one amount per cycle and a score band is independent stars, each its own challenge; weekly reset fixed at
ISO-week UTC from the battle's submission time; events expire by `ends_at`; manual resets per challenge for everyone or one
player, any environment, admin only; a Development-only clock offset on the worker; conditions are data, composed in the editor.

**History.** The first draft had *ladders* (a reward of 1 to N tiers per challenge, paying the difference up to the best tier
reached, `best_tier` on the mark, `Tier` on facts, ledger rows and events). It was removed before release because tiers and
independent stars overlap, and stars are the more flexible content tool. Migration 0006 was rewritten in place for that reason
(the branch was never pushed).

**Open / later:** a progress read for the UI; run- and floor-level completions (4a); items and cards as rewards (slice 5).

**Stays out:** multipliers, per-challenge cycle lengths, a rules admin UI.
