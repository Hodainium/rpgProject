# Spec: hash-id-lists (a small slice after unique-events): run hash v3, the snapshot hashed

Status: **spec written 2026-11-22; decisions taken with the user the same day (section 7); awaiting the user's review before
`/implement`.** Found by the security review of `unique-events` (2026-11-22). Builds on `specs/run-verify.md` (steps,
checkpoint snapshots bound by the run hash) and `specs/server-authority.md` (snapshots, `RunSnapshot`).

## 1. Purpose & enterprise mapping

**The hole.** The run hash (`RunState.canonical_lines`, `run-v2`) is not one-to-one: two different states can write the same
text. Its hand-written lines join id lists with commas (`seen=`, `armor=`, `events_seen=`, `gifts=`, and inside a member's
line `skills`, `items`, use slots, equipment, fields joined by `|`), and the map cells, the open event, the pending battle and
the waiting floor go through `StateHasher.canonical`, which writes strings and keys as they are. So `seenItems: ["a", "b"]`
and `seenItems: ["a,b"]` both write `seen=a,b`, and the string `"1"` and the number `1` both write `1`.

**The exploit path.** A run step starts from the client's claimed checkpoint snapshot, and the verifier checks only that the
snapshot's hash is the hash the previous step reached (`StepRunner._replay`, by design: "the run hash covers everything that
decides play"). A modified client uploads a checkpoint whose ids are merged or split. The hash matches, the verifier accepts
it, and every later step replays on the forged state. The gain stays inside the run (items offered again, a stronger party,
so verified boss wins and their gems come easier); it never grants currency directly.

**The fix, in two parts.**
1. **One-to-one encoding.** A new encoder, `RunCanonical`, writes every value so the text reads back to exactly one value:
   strings quoted and escaped, numbers bare, booleans as words, lists and dictionaries bracketed.
2. **The hash is the snapshot.** Instead of hand-written lines kept in step with the snapshot by a test, the run hash is
   built from the snapshot itself (`RunSnapshot`'s state part), minus an explicit list of fields left out on purpose, plus the
   two inputs that travel beside the snapshot (the card pool digest and the current floor's seed). What the verifier restores
   is exactly what is hashed, and a field added to the snapshot later is hashed the moment it is saved.

The hash version becomes `run-v3`. A merged or split id then simply hashes differently, and the forged checkpoint fails the
check that already exists (Rejected 2002 `SnapshotHashMismatch`, the existing rollback). No list of id fields to keep in
step, no rule on which characters ids may hold.

**Rejected alternatives.**
- Keep `run-v2` and check every id of a claimed snapshot against the content (the first draft of this spec): a hand-kept list
  of about 20 id fields, where one forgotten field reopens the hole without warning, plus a validator rule forbidding
  separators in ids. Its supposed advantages were not real: runs in flight break anyway (the ruleset version covers the
  source, and the worker verifies only its own ruleset), and goldens move once for a deliberate format change.
- `run-v3` as the encoding fix only, keeping the hand-written lines: it would leave the lines and the snapshot as two
  descriptions of one state, and the snapshot-derived hash would then need a `run-v4` and a second move of every golden.
- Length-prefixed strings (`3:abc`) instead of quoting: equally one-to-one but hand-rolled, and the goldens become unreadable.

**What changes for the worse, accepted:** the hash is now tied to the snapshot's layout, so renaming or restructuring a
snapshot key changes every run hash (a ruleset change, like any rule change). Golden lines use the snapshot's field names
(`run.seenItems=[...]`) instead of hand-picked ones (`seen=...`).

**Enterprise mapping.** Godot only (client and verifier, which share the code). The server never computes a run hash: it
stores the client's claimed hashes and the verifier's verdicts as strings. Postgres, Redis, RabbitMQ and Redpanda are not
touched; no contract changes.

**Acceptance scenarios covered:** 5 (a tampered run is rejected by replay with 2002).

## 2. Sequence flow

Unchanged on the wire. The client hashes with `run-v3` after each action and uploads the hash with the action and its
snapshot (`POST /runs/{id}/actions`, unchanged). The worker runs `step_main.tscn`; `StepRunner._replay` restores the claimed
start snapshot, computes its `run-v3` hash and compares it with the previous step's end hash (unchanged code). A mismatch is
Rejected 2002 `SnapshotHashMismatch` at `fromSeq`; the worker commits it and `RunAggregator` rolls the run back (epoch + 1);
the client rebuilds from `GET /resume`.

### 2.1 The encoding (`game/run_canonical.gd`, `RunCanonical.encode(value) -> String`)

| Value | Written as |
|---|---|
| String, StringName | JSON-quoted (`JSON.stringify` of the String): `"a,b"`, with `"`, `\` and control characters (incl. `\n`) escaped |
| int | the number: `12` |
| float | a whole float as the int (JSON-parsed snapshots hold floats); any other float is an error (the run state holds none) |
| bool | `true` / `false` |
| null | `null` |
| Array | `[` items joined by `,` `]` |
| Dictionary | `{` `"key":value` pairs joined by `,` `}`, keys as Strings, sorted by String (never by StringName pointer) |
| anything else (an Object, a Vector, a NodePath, ...) | an error: `push_error` and `!<type>` in the text, so a test, a report or the verifier fails loudly |

Strings and StringNames encode alike on purpose: restoring a snapshot turns ids back into StringNames (`RunSnapshot._names`),
and the rules compare them as equal. Every other pair of different values encodes differently.

### 2.2 The hashed state (`RunSnapshot.capture_state(state) -> Dictionary`)

`RunSnapshot.capture(run)` is split: `capture_state(state: RunState)` builds everything that describes the run's state
(`schemaVersion`, `run`, `map`, `pendingBattle`, `waitingFloor`) from `RunState` alone, and `capture(run)` adds what only the
controller holds (`log`, `tally`, `requestedFloors`). The snapshot's JSON is unchanged, so saves, uploads, resumes and the
server are unaffected. `pendingBattle` and `waitingFloor` are read from `RunState` (where `run-verify` put them).

### 2.3 The hash (`game/run_hash.gd`, `RunHash.lines(state) -> PackedStringArray`, `RunHash.of(state) -> String`)

`RunHash.lines` encodes `capture_state(state)` as lines, one per part, so goldens stay readable and a mismatch can be
traced to its first different line:

```
run-v3
run.bossCleared=false
run.chapter="fixture.chapter.cellar"
run.coins=12
...
run.party[0]={"alive":true,"character":"fixture.character.knight",...}
run.seenItems=["fixture.item.flask","fixture.item.feather"]
map.size=[9,8]
map.start=40
map.cells[13]={"cell":[4,1],"cleared":0,"content":{...},...}
pendingBattle={...}
floorSeed=5150
card_pool="<digest>"
```

- **Order:** the header, then the `run` keys sorted by name (the party one line per member, in slot order), the `map` keys
  sorted, one line per cell in index order, then `pendingBattle`, `waitingFloor`, `floorSeed`, `card_pool`.
- **Left out on purpose** (`RunHash.NOT_HASHED`, one list in code, each with its reason): `run.runId` (identity, compared by
  the step against the run itself), `run.devCommands` (a console-cheat counter), `run.floorSeeds` (replaced by `floorSeed`,
  the current floor's seed: the server's own are the reference for the rest), `map.attempts` (how many tries the generator
  needed), and the controller's `log`, `tally` and `requestedFloors` (not in `capture_state`).
- **Beside the snapshot:** `floorSeed=` (server mode only, as today) and `card_pool=` (only when the run has a pool, as
  today: `RunState.card_pool_digest()`).
- **Empty means absent:** a part whose value is `null`, `false`, `""`, `[]` or `{}` writes no line, so a feature a run never
  touches adds nothing to its hash. This is safe only because restoring a snapshot with that field missing gives the same
  state; a test proves it for every field (H6).

`RunState.run_hash()` and `RunState.canonical_lines()` stay as thin calls to `RunHash` (every caller keeps working).
`FloorMap.canonical_lines()` (the floor goldens) returns the `map.` lines of the same encoder. The hand-written lines in
`RunState.canonical_lines` are deleted.

**Not changed:** `StateHasher.canonical` (it also hashes the card catalog: the server's catalog hash,
`tools/check_card_catalog.sh` and its C# cross-check), the battle state hash v1 (see 7), `RunSnapshot`'s JSON layout and
`SCHEMA_VERSION`.

### 2.4 The cost (measured 2026-11-22)

Measured on the real demo content (a 4-member smart run of The Descent to floor 10, 316 actions), per action:

| Point in the run | `run-v2` hash | snapshot capture without the log + encode (prototype) |
|---|---|---|
| floor 1 (9 rooms) | ~0.3 ms | ~0.6 ms |
| floor 7 (20 rooms) | ~0.8 ms | ~1.3 ms |
| floor 10 (25 rooms) | ~0.9-1.0 ms | ~1.8 ms |

About +1 ms per action at most, under 10 ms for a typical step and about 90 ms for a 100-action step, against a worker
step that starts a Godot process and loads the content. **Budget:** at most 3 ms per hash on a 25-room floor. The play
report records it (`hashTiming`: mean and max microseconds per hash, and the floor of the max), so a regression shows in
the report, not in a flaky test. If it is ever needed, a per-cell cache of encoded cells (most actions change one cell) makes
the hash cheaper than `run-v2`; not built now.

## 3. Data contracts

N/A on the wire: no `Rpg.Contracts` record changes, no queue, topic or Redis key, the snapshot JSON unchanged. Run hashes
stay 64 hex characters. Godot only: `RunCanonical`, `RunHash`, `RunSnapshot.capture_state`, the `run-v3` header.

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| H1 | A checkpoint merges two seen item ids into one (`"a,b"`) | Its hash differs: Rejected 2002 `SnapshotHashMismatch` at `fromSeq`, before any replay; the run rolls back | `test_merged_ids_rejected` (in `test_step_runner`, from a real checkpoint) |
| H2 | The same merge or split in any string list of a snapshot (armor, events seen, pending gifts, a member's skills, items, use slots, equipment, a cell's pickups or enemies, ...) | Rejected the same way | `test_split_and_merge_change_the_hash`: for every string list in real snapshots, merging two neighbours and splitting one changes the hash |
| H3 | A string forged for a number or a number for a string (`"1"` for `1`), `true` for `1` | The hash differs | `test_types_change_the_hash` |
| H4 | A string holding a quote, a backslash, a newline, `,` `|` `=` `:` `{` `[` | Escaped; still one-to-one, and a newline cannot forge a hash line | `test_run_canonical_escapes` |
| H5 | A value the encoder does not know (an Object left in a cell) | `!<type>` and a script error, which fails the test, the report or the step (runner error, retried, then DLQ) | `test_run_canonical_refuses_objects` |
| H6 | A field left out because it is empty | Restoring a snapshot without it gives the same state | `test_empty_parts_restore_alike`: every empty, false or null leaf of real snapshots removed, restored, captured again: the same snapshot and hash |
| H7 | Any field of the snapshot changed | The hash moves, unless the field is in `RunHash.NOT_HASHED` | `test_snapshot_fields_are_covered` (kept; reads `RunHash.NOT_HASHED` instead of its own copy) |
| H8 | The card pool or the current floor's seed changed | The hash moves (they are outside the snapshot) | `test_side_inputs_are_hashed` |
| H9 | Dictionary keys that are StringNames, interned in a different order | The same text | `test_run_canonical_key_order` |
| H10 | An honest run | Verifies as before: both committed runs cut into steps, every checkpoint, the keyed run, the floor-rooms, card-pool and unique-events runs | the existing `test_step_runner` and `test_run_authority` suites, re-recorded goldens |
| H11 | The real stack | A forged checkpoint is rejected and the run rolls back and rebuilds | e2e `snapshot_ids_forged` (harness fault `tamper-snapshot-ids`: merges two seen item ids in the next stored checkpoint) |

Replay mismatches follow the root error contract: a verdict with `errorCode` 2002, never an HTTP 422.

**Runs in flight.** A run started before this slice was hashed with `run-v2`; its next step is verified by a worker built
from the new source, whose ruleset version differs, so it is handled as any ruleset change is today (slice 9 routes by
version). Local saves hold a snapshot, not a hash: they restore and hash with `run-v3` from then on. A server-mode save
whose queue still holds `run-v2` hashes is a run in flight like the above.

## 5. Observability

No new metric. A forged checkpoint shows in the existing `rpg_step_*` verdict counters under the reason
`SnapshotHashMismatch`, in `rpg_run_rollbacks_total`, and as an `AntiCheatAlert` event (`RunAggregator`), as every rejected
step does today. The hash's cost is in the play report (`hashTiming`, 2.4), never a Prometheus label.

## 6. Test plan

- `tests/game/test_run_canonical.gd` (new): H3, H4, H5, H9 on plain values, plus a property test: a few hundred generated
  values (nested lists and dictionaries of ids holding separators, numbers, booleans, nulls) never encode alike.
- `test_step_runner`: H1, H2, H6, H8 from real checkpoints of the committed runs (`_play`), each forged snapshot one change
  away; H7 kept.
- Goldens re-recorded once (`tools/godot_tests.sh -- --update-goldens`), expected to move: every golden holding run hashes or
  run and floor lines (`floor_123456789.txt`, `floor_7.txt`, `run_scripted.json`, `run_keyed.json`, `sandbox_room.json`,
  `seed_report.json`, `seed_report_play.json`). Expected **not** to move: every combat golden and trace, `card_catalog.json`,
  `seed_codes.json`, `seed_derive.json`. A move in those is a bug.
- `tools/verifier_image_check.sh`: the run goldens recorded on Windows still match inside the Linux image (the encoder uses
  no locale- or platform-dependent formatting).
- The play report on the gold standard (`play_sharded.sh ... --policy smart --party-size 4`): `hashTiming` within the budget.
- e2e: `tools/e2e.sh snapshot_ids_forged` on the real stack (Docker), plus the existing `verify_tampered` and
  `verify_battle` scenarios.
- Both suites (`dotnet test`, `tools/godot_tests.sh`) pass. No .NET code changes, so `dotnet test` only proves nothing broke.

## 7. Decisions, open questions, what stays out

**Decided with the user (2026-11-22):**
1. Fix the hash, not the ids: `run-v3`, the snapshot hashed through a one-to-one encoder (section 1).
2. JSON-quoted strings rather than length prefixes.
3. Remove the comma check on `seenEvents` added by `unique-events` (`RunSnapshot.shape_problem`): the encoding makes it
   redundant, and a check on one field alone misleads readers. The other shape checks stay (they protect the restore).
4. The cost is accepted with a budget (2.4), measured in the play report.

**Open:** none.

**Stays out:** checking snapshot ids against the content (a snapshot naming an unknown id hashes honestly and holds nothing
useful), the battle state hash v1 (its inputs are rebuilt by the verifier from the run, so a client never hands it strings;
moving it would move every combat golden and the C# cross-checks), `StateHasher.canonical` and the card catalog hash, the
per-cell cache (2.4), any server change, and reusing a warm Godot process per worker (the real lever for the verifier's
speed; its own slice).
