# reflectory

Self-improvement harness for Claude Code: a git-tracked home for your personal
rules, forked plugin skills, and session reflections. The core loop:

1. Work in Claude Code as usual.
2. Run `/reflect-session` at the end of a session — Claude walks back through
   the conversation, finds concrete friction points, and proposes improvements
   to your config (CLAUDE.md rules, skill forks, new local skills).
3. You approve each change individually. Approved changes land here, get
   committed and pushed — your config improves monotonically, survives machine
   changes, and travels with you.

## Features

- **`/reflect-session`** — end-of-session harvest: walks back through the live
  conversation, finds friction points (corrections you made, rules Claude missed,
  patterns worth codifying), and proposes concrete config changes. Three change
  categories: CLAUDE.md rules, forks of plugin artefacts, brand-new local skills.
- **Per-item approval** — every proposed change is approved individually before
  it touches anything. Nothing lands silently; a rejected finding is logged and dropped.
- **`/reflect-archive`** — batch reflection over past sessions you never reflected
  on (largest first), with an **adversarial critic** that re-reads the raw transcript
  to refute weak findings before they reach you.
- **`/reflect-compress`** — the subtract channel: batch-audits the accumulated
  rule layer against reality — dormant rules (usage stats), dead path references
  (filesystem check), contradictions, near-duplicates, verbosity — and proposes
  per-item-approved reductions. `/reflect-session` grows the config; this keeps
  it from growing monotonically.
- **Fork tracking with intent logs** — when you fork a plugin skill, the *intent*
  behind the change is recorded alongside the diff. **`/sync-upstream`** replays
  those intents on top of a new upstream plugin version: subsumed → retire,
  still needed → re-apply, conflict → escalate to you.
- **Deterministic gates** — a pre-commit hook validates rule frontmatter on every
  commit; scripts (not prose) rebuild the index, digest sessions, and compute
  rule-usage stats. The prose instructions are advisory; the hooks fire regardless.
- **Live correction capture** — an optional `UserPromptSubmit` hook snapshots
  correction-bearing prompts («не так», "that's wrong", …) into a local queue the
  moment they happen; the next `/reflect-session` consumes the queue, so corrections
  survive even from sessions you never reflected on. Registration is one manual
  settings.json step (see `_system/scripts/capture-corrections.py` header).
- **Knowledge-class layering** — rules split into portable general discipline (G),
  orchestrator discipline (K0), your idiolect (K1), and per-machine environment
  maps (K2), so each machine loads exactly the layers that apply to it.
- **Git-native persistence** — everything lives in one repo you own; approved
  changes are committed and pushed, so your config survives machine changes.

## What's inside

| Path | What it is |
|---|---|
| `skills/reflect-session/` | The core skill: analyse the current session, propose config improvements, apply approved ones |
| `skills/reflect-archive/` | Batch reflection over past sessions, with an adversarial critic that re-reads raw transcripts to kill weak findings |
| `skills/reflect-compress/` | The subtract channel: batch-prune dormant rules, fix dead references, merge duplicates — per-item approved |
| `skills/sync-upstream/` | Re-apply your tracked skill forks after a plugin updates upstream |
| `_system/scripts/` | Deterministic plumbing: frontmatter validation, index build, pre-commit gate, session digests |
| `_system/_shared/` | Metadata schema and remote-init wizard used by the skills |
| `_tracked/general-rules.md` | Starter set of universal agent-discipline rules (class G), harvested from real sessions |
| `_system/bootstrap.sh` | Installer: symlinks skills into `~/.claude/skills/`, wires the tracked layer |

## Install

### Option A — plugin marketplace (recommended)

Inside Claude Code:

```
/plugin marketplace add ArtemiiF/reflectory
/plugin install reflectory@reflectory
```

Skills become available as `/reflect-session`, `/reflect-archive`, `/reflect-compress`, `/sync-upstream`.
On first run, `/reflect-session` walks you through a one-time init wizard: it
clones this repo to `~/.claude/local-forks` (your personal data repo — approved
changes land and get committed there) and points `origin` at your own private
GitHub repo. Don't run `bootstrap.sh` in this mode — the plugin already provides
the skills.

### Option B — clone + bootstrap (no marketplace)

```bash
git clone https://github.com/ArtemiiF/reflectory.git ~/.claude/local-forks
~/.claude/local-forks/_system/bootstrap.sh
```

Then point the repo at your own remote (the skills push approved changes there):

```bash
cd ~/.claude/local-forks
git remote set-url origin <your-fork-or-new-repo-url>
```

### Either way

The path `~/.claude/local-forks` is load-bearing — all skills and scripts
default to it (overridable via the `LOCAL_FORKS` env var). To pick up the
starter rules, add to your `~/.claude/CLAUDE.md`:

```markdown
@local-forks/_tracked/general-rules.md
```

## Daily use

- `/reflect-session` — end of a meaty session: harvest improvements from it.
- `/reflect-archive` — batch-process past sessions you never reflected on.
- `/sync-upstream` — after a plugin update: re-apply your forks on the new version.
- `/reflect-compress` — when the rule layer feels bloated: batch-audit and shrink it.

Every change is per-item approved. Nothing mutates your config silently.

## Layout conventions

- `_system/` — skills and machinery (symlinked into `~/.claude/skills/` by bootstrap).
- `_tracked/` — files mirrored into `~/.claude/` (rule layers imported by your CLAUDE.md).
- `_tracked/machines/<id>/` — optional per-machine layers; `machines/current` is a
  gitignored symlink set by bootstrap via `_meta/machine-id`.
- `_sessions/` — reflection reports produced by the skills (yours will accumulate here).
- `_meta/` — per-repo metadata (remote config, machine id override).

## Requirements

- Claude Code with skills support
- `git`, `gh` (GitHub CLI) authenticated, `bash`, `python3`

## License

MIT — see [LICENSE](LICENSE).
