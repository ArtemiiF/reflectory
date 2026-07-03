---
name: sync-upstream
description: >-
  Detect when a Claude Code plugin has a new version installed and re-apply our
  intent-tracked improvements on top of the new upstream content. For each
  improvement: decide whether it is already subsumed by upstream (retire), still
  needed (active, re-apply semantically), or in conflict (escalate). Every diff
  requires per-fork user approval.
  MANDATORY TRIGGERS: "/sync-upstream", "плагин обновился", "новая версия плагина",
  "пере-применить форки", "sync forks", "re-apply intent log".
  DO NOT use for: writing new improvements (use /reflect-session), updating
  upstream plugins themselves, modifying plugin marketplaces, or any change that
  is not an upstream-driven re-application of existing intent logs.
---

# /sync-upstream

Walk over every forked plugin artefact recorded in `~/.claude/local-forks/<plugin>/<kind>/<name>/`, detect whether the plugin's installed version on disk now differs from the baseline recorded in `<plugin>/_meta.json`, and — for each artefact that drifted — semantically re-apply our intent log on top of the new upstream content. Apply only what the user approves. Push to GitHub.

The system is described in `README.md` (overview, layout, fork lifecycle) and `method.md` (analytical scaffolding for Step 4).

## Inputs

- None from the user. The state of `~/.claude/plugins/installed_plugins.json` vs `~/.claude/local-forks/<plugin>/_meta.json` is enough.
- Optional implicit context: per-plugin override if the user asks to limit the sync to a specific plugin or artefact.

## Preconditions

- `~/.claude/local-forks/` exists, is a git repo, has an `origin` remote that responds (see `~/.claude/local-forks/_system/_shared/init-remote.md`).
- At least one forked artefact exists (otherwise this skill has nothing to do).
- `gh` CLI is authenticated.

## Algorithm

Steps run strictly in order. A step that fails twice → stop, surface state to the user, do not retry a third time.

### Step 0. Pre-flight

Run `~/.claude/local-forks/_system/_shared/init-remote.md`. Proceed only on state `READY`.

### Step 1. Pull remote first

```
default_branch=$(git -C ~/.claude/local-forks symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
default_branch=${default_branch:-main}
git -C ~/.claude/local-forks pull --ff-only origin "${default_branch}"
```

The default branch is read from the remote rather than hardcoded — `gh repo create` honours the user's GitHub default-branch preference, which may be `main`, `master`, or something else. `refs/remotes/origin/HEAD` is only set automatically by `git clone`; for repos initialised with `git remote add` (the «attach existing repo» branch of the init wizard) the ref is absent and the command above returns empty. In that case fall back to `main` and tell the user how to set the head permanently:

```
git -C ~/.claude/local-forks remote set-head origin -a
```

If fast-forward fails (the user edited on another machine and pushed) — stop and ask: «remote has divergent commits; resolve manually with `git pull --rebase` or `git merge`, then re-run /sync-upstream». Do not auto-resolve.

### Step 1a. CLAUDE.md drift detection

After a successful pull, compare the live global CLAUDE.md against the tracked mirror:

```
cmp -s ~/.claude/CLAUDE.md ~/.claude/local-forks/_tracked/CLAUDE.md
```

If they differ — the user (or another tool) edited `~/.claude/CLAUDE.md` since the last `/reflect-session` Step 5(A). Present the diff via `AskUserQuestion` with these options:

| Option | Action |
|---|---|
| `Import live → tracked` | Copy `~/.claude/CLAUDE.md` over `_tracked/CLAUDE.md`. Will be committed and pushed in Step 7 alongside any fork updates. |
| `Restore tracked → live` | Copy `_tracked/CLAUDE.md` over `~/.claude/CLAUDE.md`. Discards the manual edit. |
| `Keep both, skip this check` | Leave both as-is. The drift persists until the next sync. |
| `Abort` | Stop the sync entirely. |

Never auto-resolve. CLAUDE.md is load-bearing for the orchestrator — silent overwrite is a behavioural-correctness risk.

### Step 2. Enumerate forks

Find every directory matching `~/.claude/local-forks/<marketplace>/<plugin>/<kind>/<name>/` that contains an `*.intent.md` file. Skip `_system/` and `_meta/`.

For each fork build a tuple: `(marketplace, plugin, kind, name, baseline_upstream_version)` where `baseline_upstream_version` comes from `<plugin>/_meta.json` (canonical key — see `_system/_shared/meta-schema.md`).

### Step 3. Detect drift

For each fork, compare `baseline_upstream_version` against the installed version in `~/.claude/plugins/installed_plugins.json` under `<plugin>@<marketplace>`.

- Equal → no drift, skip.
- Installed version is newer → drift detected, add to the work list.
- Installed version is older than baseline → strange (downgrade). Surface to the user, do not auto-fix.
- Plugin no longer installed → surface, ask whether to keep the fork archived or remove it. Do not delete without approval.

If the work list is empty: report «all forks up to date», exit.

### Step 4. For each drifted fork — semantic re-apply using the method

**Step 4a — Load the four inputs from disk** before invoking the method. For the fork at `(marketplace, plugin, kind, name)`:

| Variable | Path | Required |
|---|---|---|
| `our.md` | `~/.claude/local-forks/<marketplace>/<plugin>/<kind>/<name>/<file>` (e.g. `SKILL.md` for skills, `<name>.md` for agents/commands) | yes |
| `intent.md` | `~/.claude/local-forks/<marketplace>/<plugin>/<kind>/<name>/<name>.intent.md` | yes |
| `upstream.new.md` | `~/.claude/plugins/cache/<marketplace>/<plugin>/<installed-version>/<kind>/<name>/<file>` | yes |
| `upstream.baseline.md` | same shape, at `<baseline-version>` | optional — if the old version directory has been cleaned up, skip it; the method treats it as a hint, not a source of truth |

If `upstream.new.md` is missing (artefact removed in the new upstream), drop into the special row in § Failure handling instead of running the method.

**Step 4b — Open and read `method.md`** (located at `~/.claude/local-forks/skills/sync-upstream/method.md`) and execute its seven phases per fork:

1. **Parse intent log** — extract Why / Where / Effect / Re-apply rule from each `## Improvement #N`; mark malformed entries.
2. **Classify** each Improvement as `subsumed` / `active` / `conflict`, with a quoted upstream span as evidence for the first two.
3. **Cross-improvement consistency check** — surface stacking dependencies and pairwise conflicts within our own intent log.
4. **Re-apply `active` improvements** semantically (effect, not lines) onto `upstream.new.md` in chronological order.
5. **Build `our.new.md`** — sanity-check frontmatter, headings, file size; reject broken output.
6. **Re-package `intent.md`** into `Active` / `Retired` / `Conflicts (manual review)` sections; update `_meta.json`.
7. **Produce per-fork report** with counts and evidence quotes for the next step.

The method file enforces «no verdict without citation» — every `subsumed` or `conflict` must quote the specific upstream phrase that justifies it. False-conflict costs one approval prompt; false-active silently corrupts behaviour, so when torn between `active` and `conflict`, the method picks `conflict`.

### Step 5. Present per-fork diff bundle

For each drifted fork, show the user three things:

1. `upstream.baseline.md → upstream.new.md` diff (what the plugin author changed). **If `upstream.baseline.md` is unavailable (typical case — see `method.md` Phase 1 note), skip this diff and tell the user «baseline cleaned up by plugin manager, showing 2 of 3 diffs» — do not block.**
2. `upstream.new.md → our.new.md` diff (what we are about to add back on top).
3. Intent-log changelog: list of retired / active / conflict improvements with one-line justification each.

`AskUserQuestion` options per fork: `Apply`, `Edit and re-show`, `Skip this fork`, `Abort sync`.

### Step 6. Apply approved forks

For each approved fork:

- Overwrite `~/.claude/local-forks/<marketplace>/<plugin>/<kind>/<name>/<file>` with `our.new.md`.
- Rewrite `*.intent.md` re-packaged:
  - `## Active` section with re-applied improvements (preserve `Why`, refresh `Where` to match new line numbers, keep `Effect`, keep or refine `Re-apply rule`).
  - `## Retired (subsumed by <plugin>@<new-version>)` section listing improvements removed.
  - `## Conflicts (manual review)` section listing conflicts the user chose to keep flagged.
- Update `<plugin>/_meta.json`: `baseline_upstream_version = <new-version>`, `last_synced_at = <UTC now>`.
- Edit-in-place: copy `our.new.md` over `~/.claude/plugins/cache/<marketplace>/<plugin>/<new-version>/<kind>/<name>/<file>`.

### Step 7. Commit and push

Before composing the commit:

1. Regenerate the fork index so `INDEX.md` reflects the new baseline versions and intent counts:
   ```
   bash ~/.claude/local-forks/_system/scripts/build-index.sh
   ```

2. Validate frontmatter in every `*.md` we may have touched:
   ```
   bash ~/.claude/local-forks/_system/scripts/validate-frontmatter.sh
   ```
   Exits non-zero on any malformed YAML frontmatter. If it fails, do NOT commit — fix the offending file first and re-run.

3. Bump the push timestamp so it ships in the same commit (no amend, no force-push):
   ```
   bash ~/.claude/local-forks/_system/scripts/update-last-push.sh
   ```
   Writes the current UTC into `_meta/remote.json:last_push_ok_at`. Stage `_meta/remote.json` along with the other approved changes — one commit per pipeline.

Single commit per `/sync-upstream` invocation. Message:

```
sync: <N> forks updated

<plugin>/<kind>/<name>: <baseline-version> → <new-version>  (retired: K, active: M, conflict: L)
<plugin>/<kind>/<name>: ...
```

Then push to the remote default branch (resolved the same way as Step 1 pull — see that step's NOTE on the `git remote set-head` fallback):

```
default_branch=$(git -C ~/.claude/local-forks symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
default_branch=${default_branch:-main}
git -C ~/.claude/local-forks push origin "${default_branch}"
```

`last_push_ok_at` was already updated in the pre-commit step above and is part of the commit we just pushed — no post-push edit is needed.

### Step 8. Final notice

Report to the user:

- Per fork: applied / skipped / aborted, with counts of retired / active / conflict.
- Any conflicts that need manual review now live in the intent log under `## Conflicts (manual review)`.
- **Always:** «Run `/reload-plugins` so the plugin-cache edits become visible to the current Claude Code process.»

## Anti-patterns

- **No syntactic diff3 / git merge-file** is used for semantic re-apply. We read the intent log and re-apply behaviour, not lines.
- **No silent retirement.** Every `retired` decision is shown to the user with the upstream snippet that justifies it.
- **No skipping conflicts.** Conflicts are surfaced — never auto-resolved to «keep ours» or «keep upstream».
- **No multi-plugin batch confirmation.** Each fork is approved on its own.
- **No commit on empty change set.** If the user skipped every fork, exit without committing.
- **No writes to auto-memory.** All knowledge stays in `.md` files.
- **No force-push.** If remote rejects the push, surface the error and stop.

## Failure handling

| Symptom | Response |
|---|---|
| `git pull --ff-only` fails | Stop, ask user to resolve manually, do not auto-rebase. |
| `installed_plugins.json` missing or malformed | Stop, ask user to verify the plugin manager state. |
| `upstream.new.md` missing (artefact removed in new upstream) | Surface as a special case: the upstream deleted the artefact. Options: archive the fork (move to `<plugin>/_archived/`), keep applying it manually, or delete it. User decides. |
| Re-apply produces obviously broken content (frontmatter corrupted, etc.) | Stop on that fork, mark it `conflict`, continue with the rest. |
| `git push` fails after one retry | Local commits stay, surface the error and the suggested `git push` command for the user to run manually. |
