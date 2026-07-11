---
name: pull-forks
description: >-
  Pull the personal local-forks data repo from its remote and install what
  arrived onto THIS machine: new or updated skills into ~/.claude/skills
  (respecting the machine's copy-vs-symlink install pattern), changed hook
  scripts re-wired in settings.json, tracked CLAUDE.md layers verified live.
  The multi-machine propagation direction: another machine pushed approved
  reflectory changes, this machine pulls and wires them in.
  MANDATORY TRIGGERS: "/pull-forks", "затяни форки", "затяни локал форкс",
  "подтяни обновления с другой машины", "pull forks", "обнови локал форкс".
  DO NOT use for: re-applying plugin forks after a plugin-manager update (that
  is /sync-upstream — upstream→forks direction), harvesting new improvements
  from a session (/reflect-session), pruning rules (/reflect-compress), or
  pulling arbitrary user repos unrelated to ~/.claude/local-forks.
---

# /pull-forks

Fast-forward `~/.claude/local-forks` from its `origin`, classify what the pull
brought in, and — with per-item approval — install the pieces that need machine-local
wiring: skills into `~/.claude/skills/`, hook scripts into `settings.json`,
tracked CLAUDE.md layers checked against the live files.

Everything is resolved at runtime from the fixed local path `~/.claude/local-forks`
(overridable via `LOCAL_FORKS` env var) and its `origin` remote. No repo name,
branch name, machine name, or GitHub account is hardcoded — the skill works
identically whatever the user called their data repo.

## Inputs

- None from the user. The state of `~/.claude/local-forks` vs its remote is enough.
- Optional implicit context: the user may scope the run («только скиллы», «только хуки»).

## Preconditions

- `~/.claude/local-forks/` exists, is a git repo, `origin` responds
  (see `~/.claude/local-forks/_system/_shared/init-remote.md` — same pre-flight
  as the other reflectory skills).

## Algorithm

Steps run strictly in order. A step that fails twice → stop, surface state, do
not retry a third time.

### Step 0. Pre-flight

Run `~/.claude/local-forks/_system/_shared/init-remote.md`. Proceed only on `READY`.

### Step 1. Pull

```
default_branch=$(git -C ~/.claude/local-forks symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
default_branch=${default_branch:-main}
git -C ~/.claude/local-forks pull --ff-only origin "${default_branch}"
```

- Fast-forward fails (local diverged) → stop: «remote and local diverged; resolve
  manually with `git pull --rebase` or `git merge`, then re-run /pull-forks».
  Never auto-resolve, never force anything.
- Already up to date → report «nothing new», exit. (If the user says a previous
  pull was left half-installed, re-run Steps 2–5 over an explicit range they
  name, e.g. `HEAD~4..HEAD`.)

Record the range for classification: `ORIG_HEAD..HEAD`.

### Step 2. Classify what arrived

```
git -C ~/.claude/local-forks diff --name-status ORIG_HEAD..HEAD
```

| Path pattern | Class | Local action |
|---|---|---|
| `_tracked/CLAUDE.md` | tracked mirror | Step 3 — live-vs-tracked check |
| `_tracked/*.md` (shared, general-rules, k0/k2 layers) | @-imported layer | none — live immediately via CLAUDE.md `@`-imports; just verify the import line exists |
| `_tracked/machines/<id>/**` | other machine's layer | skip unless `<id>` == this machine's `_meta/machine-id` (or `machines/current` symlink target) |
| `_tracked/hooks/*` | hook script | Step 5 — hook wiring |
| `skills/<name>/**` | skill | Step 4 — skill install |
| `_system/**`, `_sessions/**`, `_meta/**`, `INDEX.md` | plumbing / reports | none |

Empty install list → report «pulled N commits, nothing needs machine-local wiring», exit.

### Step 3. Tracked CLAUDE.md check

If the pull changed `_tracked/CLAUDE.md`:

```
cmp -s ~/.claude/CLAUDE.md ~/.claude/local-forks/_tracked/CLAUDE.md
```

Differ → show the diff, `AskUserQuestion`: `Update live from tracked` /
`Keep live (drift persists)` / `Abort`. Never overwrite the live global
CLAUDE.md silently — it is load-bearing for every session.

### Step 4. Skill install

**Detect this machine's install pattern first** — do not assume:

```
find ~/.claude/skills -maxdepth 1 -type l   # any symlinks into local-forks?
```

- Symlinks present pointing into `local-forks` → **symlink mode** (bootstrap.sh
  machines): new skill → `ln -sfn ~/.claude/local-forks/skills/<name> ~/.claude/skills/<name>`;
  updated skill → nothing to do, the symlink already sees the new content.
- No such symlinks → **copy mode**: for each new/changed skill compare the
  currently installed copy against the PRE-pull repo version (`git show ORIG_HEAD:skills/<name>/SKILL.md`):
  - installed copy == pre-pull version → clean fast-forward, overwrite the copy;
  - installed copy differs → the user edited it locally → **conflict**: show both
    diffs, ask (`Take pulled version` / `Keep local` / `Skip`). Never clobber local edits.
  - not installed at all → new skill, install after approval.
- Skill DELETED upstream (`D` status) → surface, ask whether to remove the local
  install. Never delete without approval.

### Step 5. Hook wiring

For each changed/new file under `_tracked/hooks/`:

1. Read the shebang → interpreter (`bash`, `python3`, …). Read the header
   comment → which hook event it is for (e.g. `UserPromptSubmit`).
2. Grep `~/.claude/settings.json` for the script's basename:
   - **Registered, command points at the tracked path with the right interpreter**
     → nothing to do (content updated by the pull itself).
   - **Registered, but points at a stale copy elsewhere or wrong interpreter**
     (e.g. `bash` invoking what is now a python3 script) → propose: retarget the
     command to `<interpreter> ~/.claude/local-forks/_tracked/hooks/<file>`,
     delete the stale copy. Both mutations per-item approved.
   - **Not registered** → propose registration under the event from the header
     comment. Approved → edit settings.json.
3. **Smoke-test before wiring**: `echo '{}' | <interpreter> <script>` must exit 0
   (hooks must fail-safe on empty/garbage input). Non-zero → do NOT wire, surface
   the output as a defect in the hook itself.
4. Remind: settings.json is read at session start — the hook becomes active from
   the next session.

### Step 6. Report

- Pulled range: N commits, one-line log.
- Per artefact: installed / updated / skipped / conflict, one line each.
- Layers that went live automatically via `@`-imports (no action was needed).
- Anything left unwired and why.

This skill makes **no commits and no pushes** — the repo side is pull-only;
all mutations are machine-local installs (`~/.claude/skills/`, `settings.json`,
live CLAUDE.md). There is nothing to write back.

## Anti-patterns

- **No hardcoded names.** Repo, branch, machine, GitHub account — all resolved
  at runtime (`origin`, `origin/HEAD`→fallback `main`, `_meta/machine-id`).
- **No silent settings.json edits.** Every hook wiring change is shown and approved.
- **No clobbering local edits.** A locally-diverged skill copy is a conflict to
  surface, not a target to overwrite.
- **No deletions without approval.** Stale hook copies, removed skills — ask first.
- **No merge/rebase auto-resolution.** ff-only; divergence goes back to the user.
- **No commits from this skill.** Pull-and-install only; the write direction
  belongs to /reflect-session and /sync-upstream.

## Failure handling

| Symptom | Response |
|---|---|
| `git pull --ff-only` fails | Stop, ask the user to resolve manually. |
| Hook smoke-test exits non-zero | Do not wire; surface stdout/stderr; suggest fixing the hook on the machine that authored it. |
| Installed skill copy diverged locally | Per-item conflict question; never overwrite silently. |
| `settings.json` is malformed JSON | Stop before editing; surface; do not "fix" unrelated content. |
| Plugin-managed skill shadows the same name | Surface both paths; let the user pick which one wins. |
