Compare the implementation against `specs/$ARGUMENTS.md` (or every spec in `specs/` if no argument) and bring the
**specs** up to date. This command edits specs and the root `CLAUDE.md` status table only. It never changes code,
scenes or resources.

1. **Read the spec(s)**, then what they describe as it actually exists:
   - Contracts: `src/Rpg.Contracts/` records (fields, types, names).
   - Server: endpoints, status codes, Postgres tables and migrations, Redis keys and TTLs, RabbitMQ queues and
     routing keys, Redpanda topics and event schemas, outbox, and metrics in `src/Rpg.BasServer/`.
   - Godot: the GodotGAS tag registry, AttributeSets, `GameplayEffect` `.tres` files, ExecCalcs, abilities, the turn
     manager, and the headless verifier entry point in `client-godot/`.
   - Tests: which of the spec's failure scenarios and golden vectors actually have tests.
2. **Classify every difference** and report it as a table (spec says | implementation has | category | proposed action):
   - **Tuned in implementation**: a value or behavior changed deliberately (e.g. balance numbers in `.tres`, an ExecCalc formula).
     GodotGAS is the source of truth, so update the spec. If the spec copies a number that lives in Godot, replace it
     with a pointer to the resource instead of the new number.
   - **Not built yet**: the spec is ahead of the code. Leave the spec as is and list it as remaining work.
   - **Conflict**: the code contradicts a decision in the root `CLAUDE.md` (e.g. combat logic in C#, publishing to Redpanda
     outside the outbox, Redis used as the source of truth), or the change looks accidental. Don't touch the spec; flag it for me to decide.
   - **Untested scenario**: a failure scenario the spec requires that has no test.
3. **Stop and ask** before editing anything. After I approve, apply the spec edits as minimal `Edit`s and update
   the "Current state" table in the root `CLAUDE.md`. Summarize what changed in each file.
