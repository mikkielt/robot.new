# Migration - Schema Evolution

## Scope

This guide explains how the Coordinator advances the repository's data shape over time. Every schema change ships as a versioned migration. The Coordinator previews the change, applies it, and the system records what ran, when, and by whom. The same flow handles entity-schema changes, session-format changes, state-file changes, and external-data re-imports.

The guide covers what a migration is, where they live, how the Coordinator runs them, the safety checks the system enforces, the three branching strategies, recovery from a stuck run, and how to roll the repository back to a prior version. For step-by-step PowerShell commands, see [MIGRACJA-TECH.md](PL/MIGRACJA-TECH.md).

## Actors and Responsibilities

The Coordinator previews and applies migrations through the dashboard or the CLI, monitors job progress for long-running migrations, clears a stuck lock if a previous run crashed, and rolls the repository back to a prior schema version after a bad release is reverted in git.

A Plugin Author ships migrations alongside the plugin to register schema changes its own data depends on. The framework orders plugin migrations after the module migration at the same version.

Narrators and Players are not involved — migrations operate on the schema, not on narrative content.

## How a Migration Is Discovered

The system scans three locations on each run and presents the combined list to the Coordinator. Migrations shipped with the module are considered signed and apply normally. Migrations contributed by a loaded plugin are also signed. Migrations the Coordinator drops into `<repo>/.robot.local/migrations/` are unsigned — the preview surfaces a warning, and the apply call requires an explicit confirmation flag.

If two locations declare the same version, the operator-local copy wins and the system logs which one was overridden so the Coordinator can decide whether the override is intentional.

## Three Control Surfaces

All three surfaces reach the same engine. The audit trail and safety checks are identical regardless of which the Coordinator uses.

The REST API is the primary control plane. The dashboard's Tokens section mints a token with `migration:read` (preview and inspect) and `migration:write` (apply). A separate `migration:admin` scope is required to forcibly clear a stuck schema lock; a separately-issued `migration:restore` scope is required to roll the repository back to a prior version. The dashboard surfaces the current schema version, the list of pending migrations, and a preview for each one before the Coordinator confirms.

The PowerShell CLI exposes the same operations as cmdlets. `Get-SchemaVersion` shows the current state, `Get-Migration -Pending` lists what remains, `Get-MigrationPreview -Version 0.3.0` shows a dry run, and `Invoke-Migration -Version 0.3.0` or `Invoke-MigrationChain -To 0.3.0` applies the change.

A scripted run uses the same cmdlets non-interactively. The schema lock prevents two runs from racing each other regardless of which surface initiated them.

## The Preview Step

The Coordinator always previews before applying. The preview is a dry run: it never writes data and never hits the network unless the manifest declares the migration depends on a network source and the Coordinator explicitly opts in. The preview reports which files would be modified, created, or deleted, entity counts before and after the change, per-object before/after diffs the dashboard renders side-by-side, and any warnings the migration emits.

The preview is also a form. Each migration declares the inputs it accepts — for example, "regenerate from scratch?" or "commit message" — and the dashboard renders a form populated with the migration's declared defaults. The Coordinator edits the form, re-previews to see the updated diff, and applies. The per-object diffs in the preview can also carry overrides: if a row shows "before: Bagienko / after: Bagna" and the Coordinator wants to keep the existing value, they edit the "after" field of that row before applying. The override travels in the same apply call as the form fields.

If the migration declares it requires network access (for example, downloading session logs) and the preview was called without the opt-in, the file-list fields come back empty and the preview adds a warning noting that the accurate version requires opting in.

## Branching Strategy

The Coordinator picks one of three strategies per run. The CLI defaults to `Branch` because Coordinators usually have content edits in progress; the REST API defaults to `InPlace` because automation typically runs in clean working trees.

In-place applies to the working tree directly. The system refuses if `git status` shows any pending changes — the safety rule is that an in-place migration must not mix with content edits that would obscure the migration's diff. The Coordinator stashes or commits first.

Branch creates a dedicated git branch named after the migration (`migration/<slug>-<version>` for a single migration, `migration/<from>-to-<to>` for a chain), applies the change there, commits with a structured message recording the schema versions and file count, and leaves the branch checked out for review.

Branch-and-merge does the same as Branch and then fast-forward merges back into the original branch on success. The merge is refused if the original branch has diverged in the meantime, so the operator resolves the divergence manually.

## Long Runs and Background Jobs

A migration's manifest declares its estimated duration. Anything over ten seconds is dispatched as a background job: the dashboard polls the job's progress, the CLI either blocks with a progress bar or returns a job ID with `-AsJob`. The schema lock is held for the entire job and released automatically when it completes or fails.

A sync apply on a migration estimated to take more than ten seconds is refused with a hint to switch to async. The refusal is deliberate — it prevents an HTTP timeout from leaving the schema lock in an ambiguous state.

## Signed vs Unsigned

The signed/unsigned distinction is about provenance, not file format. Migrations shipped with the module or contributed by a loaded plugin go through code review and ship as committed artifacts. Migrations the Coordinator drops into `<repo>/.robot.local/migrations/` may be one-offs that never enter the repository.

For unsigned migrations, the preview surfaces a warning recommending the Coordinator review `migrate.ps1` before applying, and the apply call requires `allowUnsigned: true` (REST) or `-AllowUnsigned` (cmdlet). Without the flag, the system refuses with an "unsigned migration blocked" error.

## Recovering from a Stuck Run

If a migration run crashes — process killed, host rebooted, network partition — the schema lock will still be held by the dead process. New runs refuse with "schema locked by ...". The system also tracks how long the lock has been held; if it exceeds the configured time-to-live (60 minutes by default, configurable in `local.config.psd1`), the schema status response reports it as "likely stale" so the Coordinator knows this is not a genuine in-progress run.

After confirming no migration is still running on another machine, the Coordinator clears the lock with `DELETE /schema/lock` or `Reset-MigrationLock -Force`.

If a migration partially completed before crashing, the per-migration checklist records which steps succeeded. The next run picks up where the previous one stopped — no rework, no double-writes.

## Schema Restore After a Git Revert

If a release of the lore repository has to be rolled back via `git revert`, the schema pointer in `.robot.local/schema.json` will no longer match the reverted code state. The Coordinator brings the pointer back into sync with `POST /schema/restore` or `Reset-SchemaVersion -To <version>`.

The target version must already appear in the schema's history (the system refuses unknown versions). The operation is pointer-only: no migration script runs, no data is rewritten. The downgrade is recorded as a new history entry tagged `schema-restore:` so the audit trail shows when and why the pointer moved backward.

The `migration:restore` scope is held independently of `migration:admin` so the Coordinator can grant downgrade rights to a release engineer without also granting lock-clearing rights.

## Module Load and the Read-Only Gate

The module ships with a supported schema-version range declared in its manifest. When the module loads against a repository, it checks the repository's current schema against the range:

| Repository state | What happens |
|---|---|
| Schema is within the supported range | Module loads normally. If pending migrations exist, the Coordinator sees a count on stderr. |
| Schema is below the minimum | Module loads in read-only mode. Every write cmdlet refuses with "schema too old; run migrations to enable writes." The Coordinator runs the pending chain to advance. |
| Schema is above the maximum | Module refuses to load. An older module against a newer repository is a corruption risk; the Coordinator updates the module before continuing. |
| Module imported outside a repository | Mode is "unknown"; writes are permitted because no repository is in scope. |

This protects the repository from accidental writes by a module that doesn't understand the current schema, and protects the operator from running migrations they didn't intend to. The module's declared range is what the Coordinator updates when a new migration ships at a version beyond the current `Max` — see [MIGRATION.md "Authoring rule"](../devdocs/MIGRATION.md#authoring-rule) for the developer-side rule.

## Expected Outcomes

After a successful migration:

- The schema pointer in `.robot.local/schema.json` advances to the new version
- The per-migration record in `.robot.local/res/migration-state.json` records status, timing, checklist state, and source-hash where applicable
- The per-run log in `.robot.local/res/migration-log.txt` captures every step with timestamps (overwritten on each run)
- The git history shows either a single migration commit (Branch / BranchAndMerge mode) or in-place changes the Coordinator commits manually
- The schema history records the previous version with timestamps and the user who applied the change

## Exceptions and Recovery Actions

| Situation | What happens | Recovery |
|---|---|---|
| Apply refused with "schema locked" | Another run is in progress or a previous run crashed | If genuinely in progress, wait. Otherwise check the lock age in `/schema/version`; clear with `DELETE /schema/lock` after confirming no concurrent run |
| Apply refused with "working tree dirty" (InPlace mode) | The Coordinator has pending content edits | Stash or commit, or re-run with `branchMode: Branch` |
| Apply refused with "unsigned migration blocked" | The migration is operator-local and the apply call did not opt in | Review `migrate.ps1` in the migration directory; re-run with `allowUnsigned: true` |
| Apply refused with "duration exceeds sync limit" | A sync apply hit a migration estimated to take more than ten seconds | Re-run with `mode: async`; poll `/migrations/jobs/<id>` |
| Apply refused with "prerequisite not met" | The migration's required predecessor has not run yet | Use `Invoke-MigrationChain -To <version>` to apply the chain |
| Module loaded in ReadOnly mode | Repository schema is below the module's supported minimum | Run pending migrations to advance the schema |
| Module refused to load | Repository schema exceeds the module's supported maximum | Update the module |
| Restore refused with "version-not-in-history" | The target version was never applied to this repository | Pick a version from the response's `available` list |

## Audit Trail

- `.robot.local/schema.json` — current version + history entries (one per applied migration, plus `schema-restore:` entries for downgrades)
- `.robot.local/res/migration-state.json` — per-migration records: status, timestamps, checklist, source-hash for idempotent re-imports
- `.robot.local/res/migration-log.txt` — per-run structured log (overwritten each run; rely on git history for cross-run records)
- Git commit history — when using Branch or BranchAndMerge modes, each migration produces a commit with structured headers (Migration-Id, Schema-From, Schema-To, Files-Modified, Applied-By)

## Related Documents

- [REST-API.md](REST-API.md) — full endpoint reference including the migration endpoints
- [Glossary](Glossary.md) — term definitions
- [MIGRACJA.md](PL/MIGRACJA.md) — team-facing migration guide (Polish)
- [MIGRACJA-TECH.md](PL/MIGRACJA-TECH.md) — step-by-step PowerShell commands (Polish)
