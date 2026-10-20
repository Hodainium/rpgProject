# Design record: run authority (system-design pass, 2026-10-20)

What the system-design pass after slice 1b decided, and why. The decisions themselves live in
`specs/server-authority.md` (the spec for slices 2 and 2b) and `specs/roadmap.md` ("Run authority model": the client
action policy and the Redis plan). This file keeps the reasoning and the options we rejected, so they don't get
proposed again without new information. Commit: `9fc3c94`.

## The question
Battles were already verified asynchronously (play instantly, replay later in headless Godot). Room generation added a
second problem: how should the server keep run state valid and stop cheating, without lag and without desyncs between
client and server? Constraint from the user: the project exists to show off a distributed-systems stack, so the
answer should use it meaningfully, and the game must still feel snappy (including on public transit).

## Threat model
Single-player PvE: cheating inside a run only hurts the cheater. What matters is **what leaves the run** (currency,
gacha, leaderboards) and **analytics integrity**. Rewards were already gated on verification, so the work is about
catching problems sooner, limiting what the client knows in advance, and keeping the log clean.

## Gaps found in the first draft of the spec
1. **Seed peeking:** the client got the whole run seed, so a modded client (or the planned seed-runner dev tool) could
   see every floor's loot in advance.
2. **Seed shopping:** abandoning a run was free, so players could reroll for a good floor 1.
3. **Late desync detection:** state hashes were sent but only compared at a run-end replay, so an honest player
   could lose a 40-minute run to one determinism bug.
4. **Client-proposed battle conditions** were trusted until the end of the run.

## Options considered
| Option | What it is | Outcome |
|---|---|---|
| A. Status quo | Optimistic client, verify the whole run at the end | Rejected: leaves all four gaps |
| B. Progressive disclosure | Server reveals seeds a piece at a time | **Adopted at floor granularity** (see below) |
| C. Checkpoint verification | Verify steps as they arrive, not at run end | **Adopted**, run in parallel (slice 4a) |
| D. Rollback | On mismatch, return to the last verified checkpoint instead of rejecting the run | **Adopted** (4a) |
| E. Statistical detection | Redpanda consumer flags too-perfect play, abandon rate, inhuman speed | **Adopted** (4b), delayed review, not instant bans |
| F. Server runs the rules | Synchronous headless Godot on the request path | Rejected: latency on every room, a stateful worker per run, no offline play |
| Per-room reveal | Server reveals each room on entry, from a Redis read model | Rejected: a round trip per room; at bad mobile latency (300 ms+, dozens of rooms per floor) exploring stops feeling good |
| Per-turn commit-reveal in battle | Server reveals each turn's randomness | Rejected: a round trip per turn, no offline battles |

**Why per-floor:** the user chose game feel. One server call per floor at the stairs (hidden behind the transition),
then the floor plays fully offline. A subway rider plays a floor between stops and fetches the next one at the next
stop.

## How other games do it (used to sanity-check the design)
- **Gacha games** (Genshin, HSR, FGO, Arknights): pulls, currency and pity are always fully server-side. PvE combat is
  usually the *least* protected: rewards rolled at stage start (Puzzle & Dragons), client-simulated combat,
  plausibility checks, delayed ban waves. Our battles are verified more strongly than typical gacha because the
  combat is deterministic by design.
- **Deterministic replay:** Trackmania (records validated before they count), Clash of Clans-style attack
  verification. Same pattern as ours.
- **Lockstep RTS** (StarCraft, AoE): input logs plus state checksums, which is our action log and state hash.
- **Rollback netcode** (GGPO): show the result at once, rewind on correction, which is our rollback at room scale.
- **Path of Exile**'s predictive vs lockstep mode: the latency/consistency trade-off exposed as a choice.
- **Chess.com / Lichess**: when the cheat is legal-looking play, detect statistically. That's our answer to perfect
  play on a known floor.
- **Delayed enforcement:** studios hold bans back so cheat makers can't tell what was detected. Replay rejections
  (2002) stay immediate because they're deterministic; statistical flags go to a delayed review queue.

## What was decided
- **Whole floor, offline.** HMAC floor seed issued at the stairs; everything on the floor, battle seeds included,
  derives from it. The blocking `/battle/start` handshake is gone. Slice 2 renamed `battle-checkout` → `run-checkout`.
- **Client action policy** (full table in the roadmap): **blocking** = sign-in, run start and resume, the stairs, a
  won run's ending, gacha and currency. **Async** (applied locally, queued offline, uploaded in ordered idempotent
  batches, verified later) = every in-floor action, battles included, and a death. **Free** = presentation and
  settings.
- **Prevent the payoff, not the action.** Optimistic doesn't mean unchecked. A fake result gets the cheater at most
  until the next gate; gates bound how far ahead of the server the client can be (at most one unverified floor), and
  rewards wait for a verified run.
- **A won run blocks.** No victory screen before the server approves the run ("Verifying run…", usually brief because
  earlier floors were verified during play). A death ends at once: nothing is paid out.
- **Parallel verification needs links, not just valid steps.** A floor is valid when every step (segments of
  out-of-battle actions, single battles) is valid **and** every link is: each step's claimed start state equals the
  previous step's verified end state. Without the link check, a client could claim it entered the boss with 100 HP
  instead of 10 and play a perfectly legal battle from there. The client sends full snapshots at checkpoints so steps
  can be verified in parallel; a C# fan-in aggregator compares hashes (no game rules in C#). Same idea as blockchains
  validating transactions in parallel, then chaining state roots.
- **One verifier image, several queues.** Not two engines: the same Godot code (so rules can't diverge), with
  `verify.battle` and `verify.segment` queues on separately scaled worker pools.
- **Run verification after the outbox** (slice 4a, was "3b"): it publishes floor verdicts and anti-cheat events and its
  run-end gate settles rewards.
- **Local saves; the server's log wins.** Without a save, resume rebuilds the run from the latest checkpoint plus a
  replay of the accepted tail on the client. The run is event-sourced, so the server never needs game rules to
  restore it.
- **Redis gets real jobs** (placement in the roadmap's Redis plan): run summary and battle session caches
  (delete-on-write cache-aside), live presence, per-player rate limiting (fails open), verdict cache, work locks,
  floor read model, live analytics counters, leaderboards (verified runs only), gacha banner cache, SignalR
  backplane with two API replicas. Never the source of correctness.
- **Presence is a client heartbeat.** The server only learns about an offline battle when it's uploaded, so
  "players in a battle" is a hint that drives a dashboard tile and nothing else.
- **Development conveniences** (`X-Dev-Player`, dev tokens, `Ruleset:AcceptAny`, `Run:AutoApproveWins`) work only in
  Development; a test proves they're inert in Production.

## Accepted cheats
- **Perfect play on a known floor:** a modded client sees the floor and its battle seeds and can try every route and
  move offline. Every action it sends is legal, so replay can't reject it.
- **Save copying:** restoring a local save to retry a battle before it uploads. Same hindsight as above. Once an
  action is accepted it can't be redone (409 `1103`).
Both are left to statistical detection (4b).

## Facts from the code that shaped the spec
- Every per-floor stream is already labelled `floor/N/…` under the run seed, so a seed source can switch local mode
  (today's labels, goldens unchanged) and server mode (floor seeds) without touching anything else.
- Floor generation depends on run state (items seen and held, party), so floor N+1 can't be generated before floor N
  is played. Its generation is verified in the step that ends with `next_floor`.
- `RunState` had no save/load format. `RunSnapshot` v1 is new work in 2b, with a resume-equivalence golden test.

## Ideas noted, not adopted
- **Reveal horizon** (prefetch adjacent rooms for offline play): moot once whole floors are issued.
- **Verify by stakes** (fully verify paying runs, sample the rest): every run can pay out, so all are verified. Worth
  revisiting if verification cost becomes a load-test problem.
