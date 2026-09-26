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

> **Where the machinery lives.** `_system/…` and the system skills sit wherever this
> skill was installed from: inside the plugin when reflectory is installed as one,
> inside the data repo on a machine bootstrapped from a full clone.
> `~/.claude/local-forks` is the DATA path either way — rules, personal skills,
> session logs. Every Bash call that needs the machinery opens with these three
> lines (the shell resets between calls, so `${R}` never survives to the next one;
> when you need the root for a **file read** instead, make one such call that just
> echoes it):
>
> ```bash
> R="${CLAUDE_PLUGIN_ROOT:-$(head -1 "${LOCAL_FORKS:-$HOME/.claude/local-forks}"/_meta/machinery-root 2>/dev/null)}"
> [ -d "${R}/_system/scripts" ] || R="<the directory you read this SKILL.md from>/../.."
> [ -d "${R}/_system/scripts" ] || { echo "reflectory machinery not found — run bootstrap.sh" >&2; exit 1; }
> ```
>
> `_meta/machinery-root` is written by `bootstrap.sh` into the data repo it was
> pointed at (`${LOCAL_FORKS}`, default `~/.claude/local-forks`) — that process is
> the one that knows where it ran from. Before the first bootstrap on a machine the
> pointer does not exist yet, which is what the second line is for: this file lives
> at `<root>/skills/<name>/SKILL.md`, so the directory you opened it from, two
> levels up, IS the root. `CLAUDE_PLUGIN_ROOT` is empty in a skill's own shell and
> only helps inside plugin hooks.

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
  (see `${R}/_system/_shared/init-remote.md` — same pre-flight
  as the other reflectory skills).

## Algorithm

Steps run strictly in order. A step that fails twice → stop, surface state, do
not retry a third time.

### Step 0. Pre-flight

Run `${R}/_system/_shared/init-remote.md`. Proceed only on `READY`.

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
| `_tracked/CLAUDE.md` | hand-authored tracked mirror — only meaningful on a data repo that has not migrated (a migrated repo's live root is a generated, machine-local file `bootstrap.sh` manages directly, never written to `_tracked/`) | Step 3 — live-vs-tracked check |
| `_tracked/*.md` (L1/L2 layers, or the legacy general-rules/shared/k0-discipline names) | @-imported layer | Claude Code: none — live immediately via CLAUDE.md `@`-imports; just verify the import line exists. Codex present on this machine: re-project (Step 4b) |
| `_tracked/machines/<id>/**` | other machine's layer (L3/L4, or the legacy per-machine `CLAUDE.md`) | skip unless `<id>` == this machine's `_meta/machine-id` (or `machines/current` symlink target) |
| `_tracked/registry.json` | plugin + skill targeting registry | Step 4 — re-resolve which skills belong here. Codex's `AGENTS.md` picks up a changed plugin entry automatically via Step 4b below (it re-projects after any pull that touched `_tracked/`, registry.json included). The Claude root does not: re-run `bootstrap.sh` after a pull that changed this file to pick up a new/changed plugin entry there |
| `_tracked/hooks/*` | hook script | Step 5 — hook wiring |
| `skills/<name>/SKILL.md`, `*.md` | skill | Step 4 — skill install |
| `skills/<name>/install.json` | skill targeting manifest (legacy layout — superseded by `_tracked/registry.json` once the data repo migrates) | Step 4 — re-resolve; may add or drop a skill on this machine |
| `_system/**` | machinery — only present in a full-clone layout | none: under a plugin install the scripts arrive with `claude plugin update`, not through this repo |
| `_sessions/**`, `_meta/**`, `INDEX.md` | reports / metadata | none |

Empty install list → report «pulled N commits, nothing needs machine-local wiring», exit.

### Step 3. Tracked CLAUDE.md check

**Skip this step entirely if `~/.claude/local-forks/_tracked/registry.json` exists.**
On a migrated repo, `_tracked/CLAUDE.md` is not the live root's source — `bootstrap.sh`
Step 1.8 writes the live root directly from the registry and never reads
`_tracked/CLAUDE.md`. Running this check there would offer "Update live from
tracked" against a leftover, pre-migration file with no stamp; taking that
option would overwrite the registry-generated root with stale content and
permanently block bootstrap's own refresh (no stamp on it afterward). If the
pull brought `_tracked/CLAUDE.md` on a migrated repo, that file is orphaned
dead weight, not drift to reconcile — mention it in the Step 6 report as an
unused leftover for the user to delete by hand; do not run the drift check
against it, and do not assume `/reflect-compress` has a procedure for it
(it doesn't — this is a data-repo migration leftover, not a rule to prune).

Otherwise, if the pull changed `_tracked/CLAUDE.md`:

```
cmp -s ~/.claude/CLAUDE.md ~/.claude/local-forks/_tracked/CLAUDE.md
```

Differ → show the diff, `AskUserQuestion`: `Update live from tracked` /
`Keep live (drift persists)` / `Abort`. Never overwrite the live global
CLAUDE.md silently — it is load-bearing for every session.

### Step 4. Skill install

**Resolve the target set first — do not install every skill in the repo.** Two
axes decide it: machine and agent, declared per skill either in
`_tracked/registry.json` (schema: `_system/_shared/registry-schema.md`, once
the data repo has migrated) or in `skills/<name>/install.json` (schema:
`_system/_shared/install-manifest.md`, legacy layout — whichever is present).
One resolver serves both this skill and `bootstrap.sh`, so the two installers
cannot drift:

```
${R}/_system/scripts/skill-targets.sh
```

Output is one TSV line per skill: `<name>  install|skip  <agents>  <reason>`.
The resolver is shared with `bootstrap.sh`, so the two installers agree on WHICH
skills belong here; they still write different shapes (per-file symlinks vs a
whole-directory symlink), which the mode probe below has to account for.
Act only on `install` rows. Report the `skip` rows — a skill the user expects to
see missing from the list usually means a wrong machine id in its manifest, not
a pull problem.

A pulled skill that is installed here but no longer resolves to `install` (the
manifest narrowed its machines) → surface it, ask before removing. Same rule as
a deleted skill: never delete without approval.

**Then detect this machine's install pattern** — do not assume:

```
find ~/.claude/skills -maxdepth 1 -type l              # whole-directory symlinks
find ~/.claude/skills -maxdepth 2 -name SKILL.md -type l   # per-file symlinks
```

Both count as symlink mode. Checking only the first misses machines set up by
`bootstrap.sh`, and then copy mode would `cp` over a symlinked `SKILL.md` —
writing straight through into `local-forks` and corrupting the source of truth.

**Destination depends on the agent column of the resolver row**, not on habit:

| Resolved agent | Install root |
|---|---|
| `claude` | `~/.claude/skills/<name>/` |
| `codex` | `$CODEX_HOME/skills/<name>/` (default `~/.codex/skills/`) |

A row reading `claude,codex` installs into both. Writing a codex-targeted skill
into the Claude root is the drift this shared resolver exists to prevent.

- Symlinks present pointing into `local-forks` → **symlink mode** (bootstrap.sh
  machines): new skill → `ln -sfn ~/.claude/local-forks/skills/<name> <install-root>/<name>`;
  updated skill → nothing to do, the symlink already sees the new content.
- No such symlinks → **copy mode**: for each new/changed skill compare the
  currently installed copy (in the install root for that agent) against the
  PRE-pull repo version (`git show ORIG_HEAD:skills/<name>/SKILL.md`):
  - installed copy == pre-pull version → clean fast-forward, overwrite the copy;
  - installed copy differs → the user edited it locally → **conflict**: show both
    diffs, ask (`Take pulled version` / `Keep local` / `Skip`). Never clobber local edits.
  - not installed at all → new skill, install after approval.
- Skill DELETED upstream (`D` status) → surface, ask whether to remove the local
  install. Never delete without approval.

### Step 4b. Codex rule layer

Only when this machine has a Codex home (`~/.codex`, or `$CODEX_HOME`). Codex has
no `@`-import: text reaches the model only if it sits in `AGENTS.md` itself, so
the tracked layers are concatenated into one generated file.

```
${R}/_system/scripts/build-agents-md.sh --check   # stale?
${R}/_system/scripts/build-agents-md.sh           # re-project
```

`--check` compares the sha256 of the current layers against the one stamped in
the generated file, so a pulled rule change that was never re-projected is caught
by the script, not by memory. Run it after every pull that touched `_tracked/`.

The script refuses to write when the projection exceeds Codex's
`project_doc_max_bytes` (default 32768 — over it Codex truncates the project doc
silently). It prints the exact line to add to `~/.codex/config.toml`; that edit
is the user's call, so surface it rather than writing the config yourself.

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
