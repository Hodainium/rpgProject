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

## Order, with gates
1. **Contracts:** add or update C# `record` DTOs in `src/Rpg.Contracts/`. Wire shapes only, never game logic.
2. **Server:** Postgres migrations, endpoints, Redis caching and locks, RabbitMQ publishers and consumers, outbox and
   relay in `src/Rpg.GameServerApi/`, but only what the spec lists. Add tests for every failure scenario the spec covers.
   **Gate:** `dotnet build` and `dotnet test` pass at the repo root.
3. **Stop and summarize** what was built and tested. Ask before starting Godot work.
4. **Godot (after approval):** system code goes in `client-godot/combat/` and `tests/fixtures/`. Changes to my folders
   (`content/`, `presentation/`, `godot_gas/`) must be minimal, and each one is confirmed through the permission prompt.
   Follow the ownership section of `client-godot/CLAUDE.md`.
   **Gate:** the project loads headless without errors, and the system tests (against fixtures) pass under `godot --headless`.
   If content golden replays changed, report it. Never edit content to make them pass.
5. Update the "Current state" table in the root `CLAUDE.md` for anything that now exists.
6. **Don't commit.** Summarize the changes file by file and suggest a `feat: ...` commit message for me to review.
