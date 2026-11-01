Read the specification in `specs/$ARGUMENTS.md`. If it does not exist, stop and suggest `/spec $ARGUMENTS`.
Follow the "Battle workflow decisions" in the root `CLAUDE.md`. Do not implement anything it lists as still unspecified.

## Step 0: clean working tree (required)
Run `git status --porcelain`. If anything is uncommitted, **stop**: list the files and ask me to commit them first
(suggest `design: ...` for `client-godot/content/`, `presentation/` or `godot_gas/`). Don't continue until the tree is clean,
so everything you change shows up in `git diff` and my work can always be restored.
Also remind me to **Save All** in the Godot editor first, and to accept its "reload from disk" prompt afterwards.

## Non-destructive edits (protect my tuning)
- Before changing a file, check whether it exists. If it does, read all of it and make minimal `Edit`s. Never rewrite it whole with `Write`.
- Never overwrite or revert things I added outside the spec: balance values in `.tres` resources, ExecCalc formula
  tweaks, scene and node layouts, `GameplayCue` hooks, custom helper functions.
- Change only what the spec requires. If existing code conflicts with the spec and looks like deliberate tuning, ask
  before changing it (`/sync-spec` may be the right fix instead).
- Never hand-edit GodotGAS generated files (`gameplay_tags.gd`, generated AttributeSets). Edit the registry or draft and tell me to regenerate.

## Review loop (used by the review gates below)
Review the uncommitted diff with the built-in skills, invoked through the Skill tool: `code-review` at `high` (never
`max` or `ultra` unless I ask), and `security-review` where the step says so.
- Fix confirmed findings in code you wrote for this spec, following the non-destructive rules above. Re-run the
  build and tests for that step, then review again.
- Don't fix findings in my folders (`content/`, `presentation/`, `godot_gas/`), in my tuning, or in code outside this
  spec. List them for me to decide.
- Stop after 3 review rounds, or earlier if a round finds nothing new, and list what is still open.
- Keep a short log for the summary: each finding, and whether it was fixed, left for me, or rejected as a false positive (with the reason).

## Order, with gates
1. **Contracts:** add or update C# `record` DTOs in `src/Rpg.Contracts/`. Wire shapes only, never game logic.
2. **Server:** Postgres migrations, endpoints, Redis caching and locks, RabbitMQ publishers and consumers, outbox and
   relay in `src/Rpg.GameServerApi/`, but only what the spec lists. Add tests for every failure scenario the spec covers.
   **Gate:** `dotnet build` and `dotnet test` pass at the repo root.
   **Review gate:** run the review loop with `code-review` and `security-review` (the server handles tokens, seeds,
   rewards and idempotency). Build and tests must still pass afterwards.
3. **Stop and summarize** what was built and tested, plus the review log. Ask before starting Godot work.
4. **Godot (after approval):** system code goes in `client-godot/combat/` and `tests/fixtures/`. Changes to my folders
   (`content/`, `presentation/`, `godot_gas/`) must be minimal, and each one is confirmed through the permission prompt.
   Follow the ownership section of `client-godot/CLAUDE.md`.
   **Gate:** the project loads headless without errors, and the system tests (against fixtures) pass under `godot --headless`.
   If content golden replays changed, report it. Never edit content to make them pass.
   **Review gate:** run the review loop with `code-review`. Add `security-review` if the Godot changes touch the server
   link, tokens, saves or anything sent to the server. The Godot gate must still pass afterwards.
5. Update the "Current state" table in the root `CLAUDE.md` for anything that now exists.
6. **Don't commit.** Summarize the changes file by file, include the review log (anything still open first), and
   suggest a `feat: ...` commit message for me to review.
