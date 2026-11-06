# Spec: economy-challenges (slice 4d, after 4c, before 4a and slice 5)

Status: **spec revised 2026-11-06 after two reviews; approved to implement (in a new chat).** Builds on `specs/economy-rewards.md`
(slice 4c, implemented, commit `f501e4e`).
Decided with the user on 2026-11-04 and 2026-11-06: (1) **every reward is a ladder of tiers**, and a plain completion is a
ladder with one tier; (2) a higher tier pays **the difference**, each tier once per cycle; (3) the reset is **weekly at a
fixed UTC boundary** (ISO week, Monday 00:00), never configurable per challenge; (4) **the unit is the challenge id**: a
reward belongs to a challenge, a fact says "challenge X, tier N", and **a boss is never keyed by its own id**: its challenge
id is derived from it by one deterministic rule (section 1.1); (5) **event challenges expire**; (6) **a cycle can be reset
by hand**, and a Development-only clock offset lets a test cross a week boundary without waiting; (7) a reset can target **everyone or one player**; (8) the **game design side
is not touched now**: no Godot change, no challenge content, no star rules.

## 1. Purpose & enterprise mapping

**What this slice does.** It generalizes slice 4c's "boss → one amount, once ever" into **challenge → ladder of tiers, per
cycle**. A *challenge* is anything a player can complete and be rewarded for: beating a boss, or a limited-time event stage
with 1 to N stars (a Honkai-style challenge). The same table, admin path and settlement code serve a single reward, a weekly
bounty and a five-star event.

| | Boss, once (4c today) | Weekly boss bounty | Event challenge (5 stars) |
|---|---|---|---|
| Challenge id | `boss/demo.enemy.lich` (derived) | `boss/demo.enemy.lich` | `event.spring.trial-3` (authored) |
| Tiers (amount each) | `[25]` | `[25]` | `[10, 10, 15, 20, 40]` |
| Cycle | `once` | `weekly` | `weekly` or `once` |
| Ends at | none | none | the event's end date |
| Fact Godot reports | `BossIds` (as today) | same | `Completions: (event.spring.trial-3, 3)` |

### 1.1 Challenge ids and the boss link
A **challenge id** is a key-safe string (1–200 characters, no `:` and no whitespace; `/` and `.` are fine). It is the only
key of a reward, a mark and a ledger row; there is no separate "kind" any more.

**A boss's challenge id is derived, never typed:** `ChallengeIds.ForBoss(bossId) = "boss/" + bossId`. It is a pure function
in `Rpg.Economy` with a **shared vector file** (`tests/Rpg.Contracts.Tests/golden/challenge-id-vectors.json`: boss id → challenge id,
including the invalid ones) that the .NET tests read and, when Godot first needs the id (a UI that shows a boss's reward),
a GDScript test reads too, the same cross-check the battle goldens already use. Rules:
1. **The server derives it, Godot does not.** Godot keeps reporting `BossIds` (the verified fact "this boss was beaten").
   The worker turns each into `(ForBoss(bossId), tier 1)` before settling. The mapping can change shape later (a new
   prefix, a version) without a ruleset change, because it is server-side.
2. **The prefix `boss/` is reserved.** An authored completion fact from Godot (`Completions`) may not use it (counted
   `ignored_fact`), so a challenge cannot masquerade as a boss clear. Admins set boss rewards on `boss/<id>` ids on purpose (the
   console does it for you: `server reward boss <bossId> …`).
3. **Deterministic and total:** the same boss id always gives the same challenge id, and an invalid boss id (not key-safe, or over 195
   characters so the derived id would pass 200) gives none and is dropped as `bad_id`, as in 4c F10.
4. **One boss can have more than one challenge.** The derived id is "defeat the boss". Anything harder ("no damage taken",
   "under 8 turns") is its own authored challenge id that the game reports as a completion; it never reuses `boss/…`.

**The rules that follow (extending the boundary of 4c):**
1. **Godot reports what happened; the server decides what it is worth.** A fact is `(challengeId, tier)`. What a star
   means, how many tiers a challenge has and what each pays are server data. A tier above the ladder is capped, never an error.
2. **Pay the difference.** Per player, character, challenge and cycle the server keeps the **best tier paid**. A completion
   at tier N pays tiers `best+1 … N` at their own amounts and raises the best. Nothing is paid twice in a cycle.
3. **A cycle is a key, not a delete.** The mark carries a `cycle_key` (`once`, or `2026-W45`, plus `.r<n>` after a manual
   reset), so a reset is "a new key has no mark yet". Old weeks and old generations stay for audit; no job clears anything.
4. **Fixed boundary, battle time.** The week is the ISO 8601 week in UTC of the battle's `submitted_at` (not the verdict
   time), so a battle played late Sunday and verified Monday still counts for Sunday, and redelivery computes the same key.
5. **Expiry is by battle time too.** A challenge with `ends_at` pays nothing for a battle submitted after it, and writes no mark.
6. **A cycle can be reset by hand** (1.2), for live ops ("run the event again") and for tests.

### 1.2 Resetting a cycle, and testing without waiting a week
- **Manual reset (any environment, role `economy-admin`):** `POST /api/v1/admin/reward-cycles/reset { challengeId, playerId?, reason? }`
  appends a row to `reward_cycle_resets`. Two scopes:
  - **Everyone** (`playerId` omitted): the challenge's **global generation** goes up by one ("run the event again").
  - **One player** (`playerId` given): that player's **generation for that challenge** goes up by one (a support or test tool; other players are untouched).

  The cycle key gains `.r<global>` when the global generation is above 0 and `.p<player>` when the player's is above 0 (both can apply:
  `2026-W45.r1.p2`). Marks under the old key are untouched but no longer match, so the next clear pays the ladder again.
  It resets `once` challenges too. It never claws anything back. It writes a `RewardCycleReset` event.
  Console: `server reward-reset <challengeId> [player=me|<playerId>] [reason]` (a boss: `server reward-reset boss <bossId> …`);
  `me` is the signed-in player's own id, which the game already knows. The e2e scenarios use it to repeat a weekly challenge in seconds.
- **Clock offset (Development only):** `Settlement:CycleClockOffset` (a time span, default zero) is added to the battle's `submitted_at` for the
  cycle key and for `ends_at`, so a test can land in next week or after an event's end by setting one value. The worker ignores
  it, and logs a warning at startup, in any environment but Development (a test proves it, like `AutoApproveWins` and `Auth:DevAdmins`).
  It is a startup setting per worker, which is how the e2e harness already configures its worker.

**Backend components used:** Postgres (rules, resets, marks, ledger, wallet, outbox), the verifier worker (settlement inside
the verdict transaction), the API (admin endpoints), the outbox and Redpanda (`RewardRuleChanged`, `RewardCycleReset`,
`RewardGranted` with tier fields). **Not used:** RabbitMQ (no new queue), Redis. **No Godot change.**

**Out of scope, on purpose:** any challenge content, star rules or UI in Godot; run-level and floor-level completions (the fact
shape is ready, 4a will emit them); a player-facing progress read (`GET /progress`, with the UI); multipliers and boosts; items and cards as rewards (slice 5 widens the
currency list); per-challenge cycle lengths.

## 2. Sequence flow

### 2.1 A designer sets a ladder (admin path)
```
PUT /api/v1/admin/reward-rules           (role economy-admin; same endpoint as 4c, new body)
  { challengeId:"event.spring.trial-3", currency:"gems", tiers:[10,10,15,20,40], cycle:"weekly", endsAt:"2026-12-01T00:00:00Z" }
  validate (id key-safe, currency, cycle, 0..MaxTiers tiers each 1..cap, endsAt in the future)
  one transaction: advisory lock on challenge id → version = max+1
                   INSERT one reward_rules row per tier (same version, tier 1..n)   [no tiers = one row, tier 1, amount 0 = retired]
                   INSERT outbox RewardRuleChanged
  200 { …, tiers, cycle, endsAt, version, effectiveFrom }
```
A ladder is replaced **as a whole** (a new version holds every tier), so it is never half-edited and its cycle and end time
never differ between tiers.

### 2.2 A manual reset
```
POST /api/v1/admin/reward-cycles/reset { challengeId, playerId?, reason? }     (role economy-admin)
  the challenge must have a rule, and the player (when given) must exist (else 404 1303)
  one transaction: advisory lock on (challenge id, player id or 'all')
                   → INSERT reward_cycle_resets (player_id or null, generation = previous in that scope + 1, reset_by, reason)
                   INSERT outbox RewardCycleReset
  200 { challengeId, playerId?, generation, resetAt, resetBy }
```

### 2.3 Settlement (the worker; replaces step 5c of 4c)
```
Input: the Verified Victory's facts, and the battle's submitted_at.
completions = facts.BossIds mapped by ChallengeIds.ForBoss as (challengeId, tier 1)   (an invalid boss id → bad_id)
            ∪ facts.Completions                                                       (a "boss/…" id, tier < 1 or a bad id → ignored_fact)
            → merged by challengeId, keeping the highest tier
at = submitted_at + Settlement:CycleClockOffset (Development only, otherwise zero)
for each (challengeId, reached):
  ladder = latest version in force of challengeId, read inside the transaction                [4c lookup, now returning all tiers]
  if none or retired:           count missing/retired, no mark, carry on
  if ladder.ends_at ≤ at:       count expired, no mark, carry on
  global = max(generation) of reward_cycle_resets for challengeId with player_id null, 0 if none   (read in the same transaction)
  cycle_key  = (ladder.cycle = 'once' ? 'once' : ISOYear + '-W' + ISOWeek(at, UTC)) + (global > 0 ? '.r' + global : '')
               + (player > 0 ? '.p' + player : '')   where player = max(generation) of the resets for (challengeId, this player), 0 if none
  top = min(reached, ladder.tiers.count)                                                      (a tier above the ladder is capped)
  for each distinct character in facts.PartyCharacterIds:
    INSERT completion_marks (player, character, challenge_id, cycle_key, best_tier 0, battle) ON CONFLICT DO NOTHING
    best = SELECT best_tier … FOR UPDATE                                                      (serialises two battles of one player)
    if top ≤ best: unchanged, carry on
    for tier in best+1 … top:
      INSERT wallet_ledger (… delta = ladder[tier].amount, challenge_id, rule_version, tier, cycle_key,
                            idempotency_key = 'mark:{battleId}:{characterId}:{challengeId}:{tier}') ON CONFLICT DO NOTHING
      UPSERT wallets (gems += amount, version += 1)
      INSERT outbox RewardGranted { …, challengeId, tier, cycleKey }
    UPDATE completion_marks SET best_tier = top, battle_id = $battle
```
One ledger row and one event per tier, so a three-tier jump is three auditable rows. The three exactly-once gates of slice 4
hold: the session guard, the mark row (`best_tier` only rises within a key), and the ledger key (now with the tier).
Amount and `rule_version` come from the ladder version in force **when the verdict commits** (4c F3, unchanged); the cycle
and end time come from the battle's `submitted_at`; both generations are read in the same transaction.

### 2.4 Reading
`GET /api/v1/wallet` is unchanged apart from two optional ledger fields (`tier`, `cycleKey`). `GET /api/v1/admin/reward-rules`
lists the current ladder per challenge, with its global generation.

## 3. Data contracts

### 3.1 C# records (`src/Rpg.Contracts/`)
```csharp
namespace Rpg.Contracts.Economy;

public static class RewardCycles { public const string Once = "once"; public const string Weekly = "weekly"; }
// RewardSourceKinds is REMOVED (the challenge id is the one key).

/// <summary>PUT /api/v1/admin/reward-rules. A whole new version of one challenge's ladder. REPLACES slice 4c's kind/id/Amount.</summary>
public sealed record RewardRuleRequest(
    string ChallengeId, string Currency,
    IReadOnlyList<int> Tiers,                 // amount per tier, index 0 = tier 1; each 1..Economy:MaxRewardAmount; empty = retire
    string Cycle = RewardCycles.Once,         // "once" | "weekly"
    DateTimeOffset? EndsAt = null);           // null = never expires; otherwise must be in the future when set

public sealed record RewardRuleResponse(
    string ChallengeId, string Currency, IReadOnlyList<int> Tiers, string Cycle, DateTimeOffset? EndsAt,
    int Generation, int Version, DateTimeOffset EffectiveFrom, string CreatedBy);
// RewardRuleListResponse: unchanged (latest ladder per challenge).

/// <summary>POST /api/v1/admin/reward-cycles/reset.</summary>
public sealed record RewardCycleResetRequest(string ChallengeId, Guid? PlayerId = null, string? Reason = null);   // PlayerId null = everyone
public sealed record RewardCycleResetResponse(string ChallengeId, Guid? PlayerId, int Generation, DateTimeOffset ResetAt, string ResetBy);

namespace Rpg.Contracts.Battle;
/// <summary>One challenge the battle completed and the tier (stars) reached. Bosses stay in BossIds.</summary>
public sealed record CompletionFact(string ChallengeId, int Tier);
// BattleFacts gains: IReadOnlyList<CompletionFact>? Completions = null   (omitted from JSON when null)
// Godot emits none yet; BossIds keep meaning "this boss was beaten", so every golden and the replay runner are unchanged.

namespace Rpg.Contracts.Events;
// RewardGrantedPayload gains (additive, schema version stays 1): string ChallengeId, int Tier, string CycleKey.
//   BossId stays, filled when the challenge id is "boss/…" (the boss id) and null otherwise (kept for slice 4 consumers).
// RewardRuleChangedPayload: SourceKind/SourceId become ChallengeId; Amount/PreviousAmount become IReadOnlyList<int> Tiers / PreviousTiers (+ Cycle, EndsAt).
// New RewardCycleResetPayload(ChallengeId, PlayerId?, Generation, ResetBy, Reason?); EventTypes.RewardCycleReset; key "rule:{challengeId}".
//   Nothing consumes rpg.economy.events yet, so these are version-1 corrections, not a v2.
// LedgerEntryDto gains: string? ChallengeId, int? Tier, string? CycleKey (null on older rows).
```
Error codes: **1301 RewardRuleInvalid** also covers an unknown `cycle`, too many tiers, a tier amount out of range and an `endsAt`
in the past. New **1303 RewardTargetUnknown** (404, a reset for a challenge with no rule or a player that does not exist).

### 3.2 PostgreSQL: `Migrations/0006_reward_challenges.sql`
```sql
-- reward_rules: the challenge id replaces (kind, id); boss rules move to their derived ids.
ALTER TABLE reward_rules RENAME COLUMN source_id TO challenge_id;
UPDATE reward_rules SET challenge_id = 'boss/' || challenge_id;           -- every 4c rule was a boss rule
ALTER TABLE reward_rules DROP COLUMN source_kind;                          -- drops its check, its unique key and the index with it
ALTER TABLE reward_rules
  ADD COLUMN tier int NOT NULL DEFAULT 1 CHECK (tier >= 1),
  ADD COLUMN cycle text NOT NULL DEFAULT 'once' CHECK (cycle IN ('once', 'weekly')),
  ADD COLUMN ends_at timestamptz,                                          -- the same on every tier row of a version (the API writes it so)
  ADD UNIQUE (challenge_id, version, tier);
CREATE INDEX reward_rules_latest ON reward_rules (challenge_id, version DESC);

CREATE TABLE reward_cycle_resets (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  challenge_id text NOT NULL,
  player_id uuid REFERENCES players,                   -- null = a reset for everyone
  generation int NOT NULL CHECK (generation >= 1),     -- counted per scope: (challenge, everyone) or (challenge, player)
  reset_by text NOT NULL,
  reason text,
  reset_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX reward_cycle_resets_scope ON reward_cycle_resets
  (challenge_id, COALESCE(player_id, '00000000-0000-0000-0000-000000000000'::uuid), generation);

-- completion_marks: one row per (player, character, challenge, cycle), holding the best tier paid so far.
ALTER TABLE completion_marks RENAME COLUMN boss_id TO challenge_id;
UPDATE completion_marks SET challenge_id = 'boss/' || challenge_id;
ALTER TABLE completion_marks
  ADD COLUMN cycle_key text NOT NULL DEFAULT 'once',
  ADD COLUMN best_tier int NOT NULL DEFAULT 1 CHECK (best_tier >= 0);      -- existing rows: tier 1 of 'once'
ALTER TABLE completion_marks DROP CONSTRAINT completion_marks_pkey,
  ADD PRIMARY KEY (player_id, character_id, challenge_id, cycle_key);

-- wallet_ledger: source_kind/source_id (4c) become challenge_id; tier and cycle_key are new. Older rows stay null.
ALTER TABLE wallet_ledger RENAME COLUMN source_id TO challenge_id;
UPDATE wallet_ledger SET challenge_id = 'boss/' || challenge_id WHERE challenge_id IS NOT NULL;
ALTER TABLE wallet_ledger DROP COLUMN source_kind, ADD COLUMN tier int, ADD COLUMN cycle_key text;
```
Existing data stays valid and keeps its meaning (a 4c boss rule becomes tier 1, cycle `once`, challenge `boss/<id>`; a mark
becomes best tier 1 of `once`). The migration test loads 4c-shaped rows first. The ledger's old keys (`mark:{battle}:{character}:{boss}`)
stay as written: those battles already have a mark, so a redelivery never reaches the ledger. New keys are
`mark:{battleId}:{characterId}:{challengeId}:{tier}`; the challenge id has no `:` (key-safe), so the key is unambiguous.

### 3.3 RabbitMQ
N/A: no new queue.

### 3.4 Redpanda
`rpg.economy.events`: `RewardGranted`, `RewardRuleChanged` and the new `RewardCycleReset` as in 3.1. Keys: `playerId` for grants, `rule:{challengeId}` for rule events.
Consumers dedupe on `EventId`.

### 3.5 Redis
None.

### 3.6 HTTP and console
| Endpoint | Auth | Answer |
|---|---|---|
| `PUT /api/v1/admin/reward-rules` | role `economy-admin` | 200 `RewardRuleResponse`; 400 1301; 403 1302 |
| `GET /api/v1/admin/reward-rules` | same | 200 `RewardRuleListResponse` |
| `POST /api/v1/admin/reward-cycles/reset` | same | 200 `RewardCycleResetResponse`; 400 1301; 403 1302; 404 1303 (no rule, or no such player) |

Console: `server reward` lists. `server reward <challengeId> <amount>[,<amount>…] [cycle=once|weekly] [ends=<UTC ISO>]` sets;
`server reward boss <bossId> <amounts> …` is the same for `boss/<bossId>` (the console builds the id with the same rule); no amount list and `0` retire.
`server reward-reset [boss] <id> [player=me|<playerId>] [reason]` resets a cycle for everyone or one player. Client side: `PutRewardRuleAsync`, `ListRewardRulesAsync`, new `ResetRewardCycleAsync`
(admin calls stay inside `#if DEBUG` in `ServerBridge`, as in 4c). The e2e harness gives its player the role as in 4c.

### 3.7 Configuration
API: `Economy:MaxTiers` (default 10), `Economy:MaxRewardAmount` (unchanged). `Economy:SeedRules` / `infra/economy/reward_rules.json` move to
`challengeId` + `tiers` (`boss/demo.enemy.lich`, `[amount]`); seeds still fill only challenges with no rule.
Worker: `Settlement:CycleClockOffset` (Development only, default `00:00:00`), `Settlement:Enabled` (unchanged).

## 4. Failure modes

| # | Situation | Behaviour | Test |
|---|---|---|---|
| C1 | Same battle settled twice (redelivery, two workers) | unchanged: the session guard, then `best_tier` cannot rise twice, then the ledger key per tier | `RedeliveredBattle_PaysEachTierOnce` |
| C2 | Higher tier after a lower one, same cycle | pays only the new tiers at their own amounts; `best_tier` rises | `ThreeStarsAfterOne_PaysTiersTwoAndThree` |
| C3 | Lower or equal tier after a higher one | pays nothing, `best_tier` unchanged | `LowerTierAfterHigher_PaysNothing` |
| C4 | First clear jumps straight to tier 5 | pays tiers 1…5 in one transaction: five ledger rows, five events | `FirstClearAtTop_PaysEveryTier` |
| C5 | Reported tier above the ladder | capped to the top; `best_tier` stores the capped value, so a longer ladder later can still pay the rest | `TierAboveTheLadder_IsCapped`, `LadderExtended_PaysTheNewTier` |
| C6 | A completion fact with tier < 1, a bad id, or a reserved `boss/…` id | that fact is dropped and counted (`ignored_fact`); other facts and the verdict still commit | `BadCompletionFacts_AreDropped_AndTheVerdictCommits`, `AuthoredFact_CannotUseTheBossPrefix` |
| C7 | A new week starts (ISO week changes) | the `cycle_key` differs, so no mark exists and the ladder pays again; last week's rows are untouched | `WeeklyChallenge_PaysAgainInANewWeek`, `WeeklyChallenge_PaysOncePerWeek` |
| C8 | The week boundary | a battle submitted Sunday 23:59:59 UTC counts for that week even if verified on Monday; Monday 00:00:00 UTC is the new week | `WeekBoundary_UsesSubmissionTime` |
| C9 | ISO year edge (e.g. 2026-12-31 is in 2026-W53, 2021-01-01 in 2020-W53) | the key uses the ISO year and week, never the calendar year | `IsoWeekKey_AtYearEnd` |
| C10 | The event has ended (`ends_at ≤ submitted_at`) | nothing is paid, no mark; counted `expired`. A battle submitted before the end but verified after still pays | `EndedEvent_PaysNothing_AndWritesNoMark`, `BattleSubmittedBeforeTheEnd_StillPays` |
| C11 | The designer edits a ladder (amounts, tiers, cycle) | a whole new version; tiers already paid keep their rows and the version they were paid at; `best_tier` is kept. Switching `once` → `weekly` pays again on the next clear (new key); switching back reuses the old `once` mark | `LadderEdit_DoesNotRepayOrLoseProgress`, `CycleSwitch_UsesTheNewKey` |
| C12 | The ladder shrinks below a player's `best_tier` | nothing is taken back and nothing more is paid; the mark stays | `ShrunkLadder_KeepsMarks` |
| C13 | Two battles of one player and character settled at once | the mark row is locked `FOR UPDATE`, so the second sees the first's `best_tier`; no tier is paid twice | `ConcurrentBattles_NeverPayATierTwice` |
| C14 | One battle reports the same challenge twice (a boss and a completion, or two tiers) | merged by challenge id keeping the highest tier, one pass | `DuplicateFacts_AreMergedToTheHighestTier` |
| C15 | An invalid PUT (bad cycle, a 0 inside a ladder, too many tiers, `endsAt` in the past, a bad id) | 400 1301, nothing written | `InvalidLadder_Is400_1301` |
| C16 | A challenge with no rule, or retired | as 4c F1/F2: nothing paid, no mark, so a later rule pays the next win | 4c tests, re-run on ladders |
| C17 | Concurrent admin PUTs on one challenge | the advisory lock keeps versions consecutive; a ladder's rows are written in one transaction, so a reader sees a whole ladder or the previous one | `ConcurrentLadderPuts_AreConsecutive`, `ALadderIsNeverHalfVisible` |
| C18 | A manual reset for everyone | global generation +1; the next clear of a `once` or `weekly` challenge pays the ladder again under the new key; old marks and ledger rows stay; a clear before the reset is not repaid | `Reset_LetsTheNextClearPayAgain`, `Reset_KeepsHistory` |
| C19 | A reset of a challenge with no rule, an unknown player, or a bad id; a non-admin caller | 404 1303 / 404 1303 / 400 1301 / 403 1302; nothing written | `ResetUnknownChallenge_Is404_1303`, `Reset_RequiresTheRole` |
| C20 | Two resets at once in one scope | the advisory lock gives consecutive generations (also protected by the unique index) | `ConcurrentResets_AreConsecutive` |
| C21 | A battle is settled after a reset but was played before it | it pays under the **current** generations (read at settlement, like the rule version), so a reset can make one in-flight battle pay again; documented, harmless, and bounded by `best_tier` per key | `BattleSettledAfterAReset_UsesTheNewGeneration` |
| C24 | A reset for one player | only that player's key changes (`.p<n>`): they are paid again, every other player keeps their marks; a later global reset stacks (`.r1.p1`) and pays everyone again | `PlayerReset_AffectsOnlyThatPlayer`, `PlayerAndGlobalReset_Stack` |
| C22 | `Settlement:CycleClockOffset` outside Development | ignored, with a startup warning; inside it, the cycle key and `ends_at` use `submitted_at + offset` | `ClockOffset_IsIgnoredOutsideDevelopment`, `ClockOffset_MovesTheWeekAndTheEnd` |
| C23 | A boss id the rule cannot map (not key-safe, or over 195 characters) | no challenge id, no grant, `bad_id` counted, the verdict commits | `ForBoss_IsDeterministicAndTotal` (the shared vectors), `AnInvalidBossId_IsNeverGranted` |

**Acceptance scenarios covered.** 1 (duplicate settlement) and 2 (worker killed after commit) are proven for tiered payouts:
C1 and `verify_worker_kill` re-run with a multi-tier challenge. Scenario 3 (Redpanda down) is unchanged: more event types on
the same outbox. No new acceptance scenario.

## 5. Observability

| Metric | Type | Labels |
|---|---|---|
| `rpg_reward_rule_lookups_total` (exists) | counter | `result` gains `expired` |
| `rpg_completion_marks_total` | counter | `result` = `new` \| `advanced` \| `unchanged` \| `capped` |
| `rpg_reward_tiers_paid_total` | counter | none (the tier is in the ledger and events, not a label) |
| `rpg_reward_cycle_resets_total` | counter | `result` = `ok` \| `unknown` \| `forbidden` |
| `rpg_settlements_total` (exists) | counter | `result` gains `ignored_fact` |
| `rpg_gems_granted_total` (exists) | counter | `reason` (sums real amounts) |

Never a challenge id, character id or week key as a label. A resets spike on the dashboard is how an operator notices a manual
reset in production. The ledger's `rule_version`, `tier` and `cycle_key` are the audit trail for "why did this player get 40
gems on 2026-W46.r2".

## 6. Test plan

- **Contract goldens:** the ladder request and response (single tier, five tiers with `endsAt`, retire), the reset request and response, `BattleFacts` with and without
  `Completions` (a golden without the field is byte-identical to today's), `RewardGrantedPayload` with the new fields,
  `RewardRuleChangedPayload`, `RewardCycleResetPayload`, `LedgerEntryDto` with and without the new fields. The Godot goldens that carry facts are unchanged.
- **Shared vectors:** `challenge-id-vectors.json` for `ChallengeIds.ForBoss` (valid ids, `:` and whitespace, 195 and 196 characters, empty).
- **Economy library (Testcontainers):** ladder lookup returns the latest version's tiers in order; a retired version; the ISO week key at the boundary,
  at year end and in a 53-week year; the cycle-key suffixes (`.r`, `.p`, both); `best_tier` row locking (C13); resets (C18, C20, C24).
- **Worker settlement:** C1–C14, C16 and C21–C23 through the harness, with `Completions` injected since Godot emits none; the existing boss tests run
  unchanged on a one-tier ladder keyed `boss/<id>` (the regression proof that bosses behave as in 4c: same amounts, marks and once-ever semantics).
- **API:** C15, C17, C19, the list endpoint returns ladders with generations, the events with tiers, the seed file in the new shape.
- **Migration:** `0006` applies on a database holding 4c-shaped rules, marks and ledger rows (they become `boss/…`, tier 1, `once`), the new primary key
  and unique constraints exist, a second apply is a no-op.
- **Console (fake bridge):** `server reward` shows tiers, cycle, end and generation; `reward <id> 10,10,15 cycle=weekly` and `reward boss <bossId> 25` send the right
  ladder and id; `reward-reset` sends the reset for everyone, and `player=me` sends the signed-in player's id; bad lists and a 403 fail visibly.
- **e2e (on demand):** `settle_boss` and `reward_rule_change` keep passing, now on `boss/…` ids; new `reward_ladder`: a 3-tier weekly challenge, `Completions` injected through the
  worker's stub Godot (`#! content` fixtures only) pay tiers 1 then 2–3, then nothing on a repeat, then **`server reward-reset player=me` pays the ladder again** and a reset for everyone does too; a second worker
  scenario sets `Settlement__CycleClockOffset=7.00:00:00` and shows a new-week payout and an ended event (the SQL file checks `best_tier`, ledger rows per tier, `cycle_key` and the version on each).
- **Godot:** no game change; the whole suite and goldens stay as they are. `test_e2e_tools` covers the new console arguments; `test_admin_calls_stay_out_of_the_player_build` is extended to `ResetRewardCycle`.

## 7. Decisions, what stays out

**Decided:** the challenge id is the one reward key; a boss gets a derived id (`boss/<id>`) that the server computes; the ladder is the only shape (a boss is a ladder of one);
difference payout; weekly reset fixed at ISO-week UTC from the battle's submission time; events expire by `ends_at`; manual resets per challenge for everyone or one player, any environment, admin only;
a Development-only clock offset on the worker; amounts are per-tier increments, not cumulative totals; a ladder is replaced whole; the game design is untouched until later.

**What the game will need later (not now):** a way for a challenge's battle to emit `Completions` (a challenge definition in content that names its id and its star
conditions; the replay reads them as facts from the finished battle, like `BossIds`). That is a Godot design task with a one-line contract: `facts.completions += (challengeId, stars)`.

**Open for review:**
1. **Decided: the derived id is `boss/` + the boss id**, a namespace, not a hash. It is readable in the admin list and the ledger, deterministic and trivially unique.
   If you want it opaque (a hash of the boss id) or versioned (`boss.v1/…`), say so; only `ForBoss` and its vectors change.
2. **Resets are per challenge, for everyone or one player** (decided). A reset for a player who does not exist is a 404, not a silent no-op.
3. **Decided: replacing `kind/id/Amount` with `challengeId/Tiers`** breaks 4c's admin contract and moves its data (the migration prefixes `boss/`). Nothing outside the repo uses it yet.
4. **One `RewardGranted` event per tier** (ledger per tier either way).
5. The roadmap gets a `4d. economy-challenges` row at `/implement` time.

**Stays out:** challenge definitions and rewards of items or cards, run- and floor-level facts, player progress reads and UI, multipliers, per-challenge cycle lengths, a rules admin UI.
