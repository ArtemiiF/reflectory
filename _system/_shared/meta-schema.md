# `_meta.json` schema

Canonical schema for `<marketplace>/<plugin>/_meta.json` files. Single source of truth — every reader (`bootstrap.sh`) and writer (`/reflect-session`, `/sync-upstream`) must use the names defined here.

## Location

One `_meta.json` per **forked plugin** (not per artefact). Layout:

```
~/.claude/local-forks/<marketplace>/<plugin>/_meta.json
```

## Schema

```json
{
  "baseline_upstream_version": "1.4.2",
  "last_synced_at": "2026-05-18T07:23:00Z"
}
```

### Fields

| Key | Type | Required | Meaning |
|---|---|---|---|
| `baseline_upstream_version` | string (semver) | yes | Plugin version against which the current local-forks content is consistent. Updated by `/sync-upstream` Step 6 after a successful re-apply. Compared by `bootstrap.sh` against `~/.claude/plugins/installed_plugins.json` to decide whether to restore the fork directly or queue it for `/sync-upstream`. |
| `last_synced_at` | string (ISO-8601 UTC) | yes | Timestamp of the last successful `/sync-upstream` run that wrote this file. Diagnostic only — not used for drift detection. |

## Lifecycle

1. **First fork created** by `/reflect-session` Step 5(B.1) — writes `baseline_upstream_version` = the installed plugin version at the moment of forking. `last_synced_at` = now.
2. **Plugin upgrade detected** by `/sync-upstream` Step 3 — installed version differs from `baseline_upstream_version`.
3. **Successful re-apply** by `/sync-upstream` Step 6 — `baseline_upstream_version` is bumped to the new installed version. `last_synced_at` refreshed.
4. **Bootstrap on a fresh machine** by `bootstrap.sh` — reads `baseline_upstream_version`, compares to installed; restores the fork only on exact match.

## Anti-patterns

- **Do not use the deprecated alias `baseline_version`** (without the `upstream_` infix). Earlier drafts of `sync-upstream/SKILL.md` used this name; it was unified to `baseline_upstream_version` to match `bootstrap.sh` (which has always read this key).
- **Do not add fields without updating this document first.** Schema drift is the exact failure mode this file exists to prevent.
- **Do not write this file by hand outside of the two skills.** Manual edits will be overwritten by the next `/sync-upstream` Step 6.

## Forward compatibility

`bootstrap.sh` reads only `baseline_upstream_version` and ignores everything else (via `jq -r '.baseline_upstream_version // empty'`). Future skills may add fields here without breaking bootstrap, but every reader added later must be documented in this file.
