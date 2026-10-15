Create a technical specification in `specs/$ARGUMENTS.md`.
If `specs/$ARGUMENTS.md` already exists, stop: do not overwrite it. Say so and suggest editing it directly (tell Claude what to change) or `/sync-spec $ARGUMENTS` after implementation.
Include the sections below. Mark a section "N/A: <reason>" when it doesn't apply; do not add infrastructure the feature doesn't need.
1. **Purpose & enterprise mapping**: what the feature does, and which backend components it actually uses (see `README.md`).
2. **Sequence flow**: step-by-step data flow from the Godot client → ASP.NET Core endpoint → the stores and brokers involved.
3. **Data contracts**: C# `record` DTOs for `src/Rpg.Contracts/`, plus (if used) RabbitMQ queue names, Redpanda topic schemas, and Redis keys with TTLs and lock semantics.
4. **Failure modes**: idempotency, retries, dead-letter handling (if queues are used), and which of the root `CLAUDE.md` acceptance failure scenarios this feature covers, each with a test.
   Replay mismatches follow the root `CLAUDE.md` error contract: a verdict with `errorCode` 2002, not an HTTP 422.
5. **Observability**: Prometheus counters and histograms to expose.
6. **Test plan**: unit tests and golden vectors that prove it works.

Stop after writing the spec and ask for review before writing any code.
