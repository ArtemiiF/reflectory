---
name: reflect-session
description: >-
  Analyse the current Claude Code conversation and propose improvements to the user's
  Claude configuration: edits to CLAUDE.md, forks of plugin skills/agents/commands,
  or brand-new local skills. Every change requires per-item user approval. All
  long-lived knowledge is stored in `.md` files — auto-memory is not used.
  MANDATORY TRIGGERS: "/reflect-session", "отрефлексируй сессию", "пройдись по сессии",
  "self-improve", "session reflection", "что улучшить в claude config".
  DO NOT use for: writing production code, running tests, fixing bugs in user repos,
  modifying plugin source repositories, generic "что можно улучшить" without
  the word "сессию" / "config" / "claude" (that phrase belongs to plugin
  agents-updater for in-repo agent improvements — disambiguate by context),
  or any change that is not a local configuration improvement.
argument-hint: "[optional: path to a past .jsonl session file]"
---

# /reflect-session

Walk back through the conversation that just happened, find concrete points where the user's Claude Code setup could be improved, propose changes, and apply only what the user explicitly approves. Persist every approved change in `~/.claude/local-forks/` (git-tracked, pushed to GitHub) and — for plugin artefacts — also rewrite the corresponding file inside the plugin cache.

The system is described in `README.md` (overview, layout, fork lifecycle) and `method.md` (analytical scaffolding for Step 2).

## Inputs

- The current conversation context (transcript Claude already has in scope).
- Optional argument: an absolute path to a past `~/.claude/projects/.../<uuid>.jsonl` file when the user wants to reflect on an earlier session instead of the current one.

## Preconditions

- `~/.claude/local-forks/` exists, is a git repo, has an `origin` remote, and `git ls-remote origin` succeeds. If any of these fails, run the pre-flight + init wizard from `~/.claude/local-forks/_system/_shared/init-remote.md` before continuing.
- The user has consented to local file mutations (running this skill counts).
- `gh` CLI is authenticated (verified by the pre-flight).

## Algorithm

Steps run strictly in order. A step that fails twice → stop, surface state to the user, do not retry a third time.

### Step 0. Pre-flight

Execute the algorithm in `~/.claude/local-forks/_system/_shared/init-remote.md`. If state is not `READY`, walk the user through the init wizard. Only proceed to Step 1 after `READY`.

### Step 1. Scope source

- No argument → analyse the current conversation context.
- Argument is a path to a `.jsonl` file → read that file directly.

Do not silently mix sources. Tell the user which source is in scope.

### Step 2. Extract findings using the reflection method

Open and read `method.md` at `~/.claude/skills/reflect-session/method.md` (a symlink to `~/.claude/local-forks/_system/reflect-session/method.md` — single source of truth, no dual-location to choose between). Execute its seven phases (0–6) in order:

0. **Rule efficacy review (decay check)** — audit A-rules applied by past runs against this session: validated / dormant(N) / misfiring. Dormancy ≥5 → decay finding (propose removal/demotion, normal approval flow); misfiring → observation for Phase 1. Max 2 decay findings per run.
1. **Observe** — eight categories of user-side signal (friction, re-routing, re-clarification, unprompted user help, decision reversal, explicit preference, positive surprise, idiolect gap) plus agent-side, protocol and positive clusters. Each observation requires a quote, turn pointer, agent action, expected action — partial observations are dropped.
2. **Filter for generalisability** — only keep observations whose trigger and fix describe in plain language and apply beyond today's task.
3. **Categorise** — A / B / C via the decision tree (cheapest fitting category wins).
4. **Draft the improvement** — concrete rule text (A), minimal diff + 4-field intent entry (B), or new SKILL.md skeleton (C).
5. **Self-test** — counterfactual, conflict, specificity, minimality. A draft failing any check is reworked once or discarded.
6. **Hand off** — surviving drafts become independent approval prompts (Step 4 below).

A clean session legitimately produces zero findings. Inventing improvements to justify the run is a defect — the method explicitly forbids it.

### Step 3. Categorise each finding

| Category | What it is | Where it lands |
|---|---|---|
| A. Config rule | A rule, preference, correction, or routing change that should apply across sessions. First split by **scope** (method.md Phase 3): **общее (G)** → `~/.claude/local-forks/_tracked/general-rules.md` (portable, `@import`-ed); **личное** → `~/.claude/CLAUDE.md` (global) mirrored to `~/.claude/local-forks/_tracked/CLAUDE.md`, or `<workspace>/.claude/CLAUDE.md` (project, NOT mirrored). |
| B. Fork of a plugin artefact | A behavioural change to a specific plugin skill / agent / command. | New or updated entry under `~/.claude/local-forks/<plugin>/...`, plus edit-in-place in `~/.claude/plugins/cache/.../<version>/`. |
| C. New local skill | A stable, reusable pattern that does not exist as a skill yet. | New `~/.claude/local-forks/_system/<name>/SKILL.md` (source of truth) and a symlink `~/.claude/skills/<name>/SKILL.md` → that file (so Claude Code finds it at the live path). Cross-machine portability follows from the symlink layout: `bootstrap.sh` re-creates the symlink on every fresh machine. |

A finding that does not cleanly fit any category goes to a fourth bucket — `Discard` — and is dropped with a one-line reason logged in the session report.

### Step 4. Per-finding approval

For each finding, present to the user via `AskUserQuestion`:

- Short label and the evidence quote from the conversation.
- Category (A / B / C). For Category A — the assigned stable rule-id (Phase 4).
- Concrete diff or new-file content (small enough to read inline; large diffs go to a tmp file referenced by path).
- Options: `Apply`, `Skip`, `Edit and re-show`, `Discard with reason`.

Never bundle multiple findings into a single approval prompt.

### Step 5. Apply approved findings

Order: A first (cheapest, in-session effect), then C (new local skill, also in-session), then B (plugin fork, requires `/reload-plugins`).

For each approved finding:

- **A:**
  - **Scope G (общее):** append the rule to `~/.claude/local-forks/_tracked/general-rules.md` under its own `### <title>`. This file is git-tracked and already `@import`-ed into `~/.claude/CLAUDE.md`, so no mirror step and no CLAUDE.md edit is needed — the import makes it always-on. Single source of truth.
  - If target is `~/.claude/CLAUDE.md` (global, личное): edit in place AND mirror the same content to `~/.claude/local-forks/_tracked/CLAUDE.md`. Both writes are part of the same approval — fail one, roll back the other before committing.
  - Write the stable rule-id (method.md Phase 4) as an HTML comment directly under the rule's `###` header: `<!-- id: <scope/class>-<slug> -->`. This is the decay aggregator's join key — required for every new G / K1 / K0 rule, and for the K2 full body in `k2-environment.md`.
  - For личное findings the rule lands by its knowledge-class tag (method.md Phase 3): K1 → `## Профиль взаимопонимания (К1)`, K0 → `## Дисциплина оркестратора (К0)` — full rule text in CLAUDE.md. **K2 is two-part:** the full rule body goes to `~/.claude/local-forks/_tracked/k2-environment.md` (lazy file), and one index row (`| триггер | ядро действия |`) goes to the `## Карта среды (К2) — индекс` table in CLAUDE.md. Both K2 writes are one approval — fail one, roll back the other. If the section/index is missing (e.g. workspace CLAUDE.md), append the full rule at the end without inventing the structure.
  - If target is `<workspace>/.claude/CLAUDE.md` (project): edit in place only. Workspace CLAUDE.md belongs to the workspace's own git repo and is out of scope for local-forks.
- **C:** Write the new `SKILL.md` to `~/.claude/local-forks/_system/<name>/SKILL.md`, then `mkdir -p ~/.claude/skills/<name>/` and `ln -sfn ~/.claude/local-forks/_system/<name>/SKILL.md ~/.claude/skills/<name>/SKILL.md` (matches the symlink shape `bootstrap.sh` produces for existing skills). Single source of truth — no second copy to maintain.
- **B:**
  1. If this artefact is not yet forked: create `~/.claude/local-forks/<plugin>/<kind>/<name>/SKILL.md` (or `<name>.md` for agents/commands), seed `<name>.intent.md`, write `<plugin>/_meta.json` with the current baseline plugin version.
  2. Apply the change to the local copy.
  3. Add a new `## Improvement #N — <YYYY-MM-DD> — <label>` entry to `<name>.intent.md` with `Why:`, `Where:`, `Effect:`, `Re-apply rule:` lines.
  4. Copy the resulting file over the plugin-cache location: `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/<kind>/<name>/SKILL.md` (or `.md` for agents/commands).

### Step 5.5. Write session log

After applying every approved finding (and before composing the commit), record the run to `~/.claude/local-forks/_sessions/<YYYY-MM-DD>T<HH-MM>-reflect.md` (UTC, time-suffixed per Stage 9 — prevents collisions on same-day re-run).

Skip this step only when **all three counters are zero** (`findings_applied == 0 && findings_skipped == 0 && findings_discarded == 0`) — i.e. a clean session with no findings to report. A session with at least one finding always produces a log, even if every finding was skipped or discarded (the «what we considered and chose not to do» trail is useful for the next `/reflect-session` calibration).

The log has two parts.

**Frontmatter** (required keys, in this order):

```yaml
---
date: <YYYY-MM-DD>
session_topic: <one-sentence summary of the conversation that produced these findings>
source_sessions:            # OPTIONAL — see note below
  - <uuid>
findings_applied: <integer>
findings_skipped: <integer>
findings_discarded: <integer>
---
```

**`source_sessions` (optional).** Include this YAML block listing the analysed session uuid(s)
**only when the source is a known past `.jsonl`** — i.e. argument mode (Step 1, a path was
passed). It is the dedup ledger that `/reflect-archive` (`list-sessions.sh`) reads to skip
already-studied sessions. In live-session mode the current session's uuid is not reliably known —
omit the key rather than guess. `/reflect-archive` always writes it (one entry per session in the
batch).

**Body — one block per finding** in the order they were presented in Step 4:

```markdown
## Finding N (applied | skipped | discarded) — <short label>

**Rule-ID:** <the stable `<class>-<slug>` id for Category A findings; `—` for B/C/discarded>

**Signal cluster:** <e.g. A1, B6, C5 — from method.md Phase 1>

**Evidence:** <the quote / transcript span recorded in Phase 1>

**Generalisation:** <the rule formulated in Phase 4, in one or two sentences>

**Class:** <G (general/portable) | K1 (mutual understanding) | K2 (environment map) | K0 (personal orchestrator discipline) — Category A findings only, `—` otherwise>

**Target:** <file:line for A; `<plugin>/<kind>/<name>` for B; new skill path for C; `—` for discarded>

**Rule text applied** (for applied findings only) or **Reason for skip/discard** (otherwise):
> <quoted rule, diff snippet, or the user-stated reason>
```

**Decay check section** (after the finding blocks, whenever Phase 0 audited at least one rule):

```markdown
## Decay check

- [<rule-id>] <rule label> — validated | dormant(N) | misfiring
```

One line per audited rule. The `[<rule-id>]` prefix is the aggregator's join key (legacy id-less rules fall back to their normalised label). The dormancy counter `N` is **derived from the whole history** by `rule-stats.py --dormancy`, not carried from this one section — so a missing section lowers the trend's resolution but no longer resets the count to zero.

The existing `_sessions/2026-05-16-reflect.md` is the reference shape — match its layout exactly so the file remains greppable for cross-session pattern analysis.

### Step 6. Commit and push

Before composing the commit:

1. Regenerate the fork index so `INDEX.md` reflects the new state:
   ```
   bash ~/.claude/local-forks/_system/scripts/build-index.sh
   ```
   Idempotent; if no B-category finding was applied (no new fork created or _meta.json touched), the only change is the «last regenerated» timestamp line — that's fine, it ships in the same commit.

2. Validate frontmatter in every `*.md` we may have touched (including the new `_sessions/<...>-reflect.md` from Step 5.5):
   ```
   bash ~/.claude/local-forks/_system/scripts/validate-frontmatter.sh
   ```
   Exits non-zero on any malformed YAML frontmatter. If it fails, do NOT commit — fix the offending file first and re-run.

3. Bump the push timestamp so it ships in the same commit (no amend, no force-push):
   ```
   bash ~/.claude/local-forks/_system/scripts/update-last-push.sh
   ```
   Writes the current UTC into `_meta/remote.json:last_push_ok_at`. Stage `_meta/remote.json` along with the other approved changes — one commit per pipeline.

Single git commit summarising all approved findings. Includes everything touched in Step 5, the Step 5.5 session log, and the Step 6.3 bumped `remote.json`. Example message:

```
reflect: <N> findings — <short labels>

A: 2 — <labels>
B: 1 — <plugin>/<kind>/<name>
C: 1 — <new-skill-name>
```

Then push to the remote default branch:

```
default_branch=$(git -C ~/.claude/local-forks symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
default_branch=${default_branch:-main}
git -C ~/.claude/local-forks push origin "${default_branch}"
```

The default branch is read from the remote rather than hardcoded — `gh repo create` honours the user's GitHub default-branch preference. For repos initialised via `git remote add` (where `refs/remotes/origin/HEAD` is not set) the resolution falls back to `main`; to fix this permanently run `git -C ~/.claude/local-forks remote set-head origin -a`.

`last_push_ok_at` was already updated in the pre-commit step above and is part of the commit we just pushed — no post-push edit is needed.

If push fails — single retry, then surface error and stop. Local changes stay; do not roll back.

### Step 7. Final notice

Tell the user:

- Summary of what was applied vs skipped vs discarded.
- **If any B finding was applied:** «Run `/reload-plugins` to make the plugin-cache edits visible to the current Claude Code process.»
- **If only A or C findings were applied:** «Changes take effect in this session immediately.»

## Anti-patterns

- **No batch approval.** Each finding is approved on its own.
- **No silent edits.** Every applied change is reported in Step 7.
- **No reformatting outside the proposed diff.** Do not «while we're here» any other lines.
- **No writes to auto-memory** (`~/.claude/projects/.../memory/`). All long-lived knowledge lives in `.md` files.
- **No fork of an artefact that does not exist.** If the user proposes editing a plugin skill that is not installed, surface the contradiction and stop.
- **No new local skill that duplicates an existing plugin skill.** If the proposed pattern matches an installed skill's description, propose a B-category fork of that skill instead.

## Failure handling

| Symptom | Response |
|---|---|
| `~/.claude/local-forks/_system/_shared/init-remote.md` returns not `READY` | Stop, hand off to the init wizard, do not proceed. |
| Plugin cache version on disk differs from the one recorded in `<plugin>/_meta.json` | This is a `/sync-upstream` job, not `/reflect-session`. Surface and stop. |
| `git push` fails after one retry | Local commit stays, surface the error and the suggested `git push` command for the user to run manually. |
| User declines all findings | Exit cleanly with «no changes applied», do not commit an empty change. |
