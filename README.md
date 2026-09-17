# reflectory

Self-improvement harness for Claude Code and Codex: a git-tracked home for your
personal rules, forked plugin skills, and session reflections. The core loop:

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
- **`/pull-forks`** — the multi-machine propagation direction: pull the data repo
  and install what arrived onto *this* machine — new skills into `~/.claude/skills/`
  (copy or symlink, matching how the machine was bootstrapped), changed hook
  scripts re-wired in settings.json, tracked CLAUDE.md layers verified live.
  Per-item approved, pull-only (never commits).
- **Two agents, one rule layer** — the same tracked rules reach Claude Code
  through `@`-imports and Codex through a generated `AGENTS.md`; session
  transcripts from both are read by one parser, so a reflection run sees Codex
  sessions too.
- **Skill targeting** — each skill declares which machines and which agents it
  belongs on (`skills/<name>/install.json`), so a WSL-only skill stays off your
  laptop and a Claude-specific one never ships into Codex.
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
| `skills/pull-forks/` | Pull the data repo and install what arrived onto this machine (skills, hooks, tracked layers) |
| `_system/scripts/` | Deterministic plumbing: frontmatter validation, index build, pre-commit gate, session digests |
| `_system/scripts/skill-targets.sh` | Resolves which skills install on this machine, for which agent |
| `_system/scripts/build-agents-md.sh` | Projects the tracked rule layers into Codex's `AGENTS.md` |
| `_system/scripts/transcript_reader.py` | Translates Codex rollouts into Claude-shaped records — one parser for both |
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

Skills become available as `/reflect-session`, `/reflect-archive`, `/reflect-compress`, `/sync-upstream`, `/pull-forks`.
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
- `/pull-forks` — on your other machine, after pushing from the first one: pull
  and wire in what arrived (skills, hooks, tracked layers).
- `/reflect-compress` — when the rule layer feels bloated: batch-audit and shrink it.

Every change is per-item approved. Nothing mutates your config silently.

## Codex support

Both agents read the same tracked rules and both can run your skills; what
differs is how each of them is fed.

### Rules

Claude Code loads the layers through `@`-imports in `~/.claude/CLAUDE.md`. Codex
has no import mechanism — a `@file.md` line in `AGENTS.md` is not substituted;
the model merely sees a reference and may or may not open it. So the layers are
concatenated into one generated file:

```bash
~/.claude/local-forks/_system/scripts/build-agents-md.sh          # write $CODEX_HOME/AGENTS.md
~/.claude/local-forks/_system/scripts/build-agents-md.sh --check  # stale?
```

`@`-imports inside the layers are expanded inline (4-hop ceiling, cycle guard),
and a sha256 of the expanded text is stamped into the header, so `--check`
catches a rule you edited but never re-projected. `bootstrap.sh` runs it on any
machine that has a Codex home; `/pull-forks` re-runs it after a pull that touched
`_tracked/`.

Two things it refuses to do. It will not write past `project_doc_max_bytes`
(default 32768), because Codex truncates the project doc at that limit **without
saying so** — a silently truncated rule layer looks installed and is not; raise
the limit in `~/.codex/config.toml` and it prints the exact line. And it will
not overwrite an `AGENTS.md` that lacks its own stamp: that is your hand-written
file, the same class as `~/.claude/CLAUDE.md` (`--force` overwrites, after a
timestamped backup).

### Skills

A skill declares its two axes beside `SKILL.md`:

```json
{ "machines": ["home-wsl"], "agents": ["claude", "codex"] }
```

`machines` is `["all"]` or ids from `_tracked/machines/<id>/`; `agents` is any
subset of `claude`, `codex`. No manifest means `machines: ["all"]`,
`agents: ["claude"]` — a skill written for Claude Code never ships into Codex by
accident. `bootstrap.sh` installs into `~/.claude/skills/` and
`$CODEX_HOME/skills/` accordingly, reports what it did not install, and removes
what it installed earlier and no longer targets only under `--prune` — never
touching a skill it cannot prove it owns, and never deleting on a manifest it
could not read.

Codex hooks (`~/.codex/hooks.json`) are check-and-report: Codex pins a
`trusted_hash` per hook in `config.toml`, so writing that file from a script
would only invalidate the trust. The hook scripts themselves need no changes —
Codex sends the same field names Claude Code does.

### Sessions

`transcript_reader.py` translates Codex rollouts into Claude-shaped records, so
`session-digest.py`, `reflect-reminder.py` and the reflection skills keep one
parser. Codex has used three text shapes across versions and one transcript can
mix them, so the shape is resolved per side (user / assistant).

```bash
_system/scripts/list-sessions.sh --agent all     # both (default)
_system/scripts/list-sessions.sh --agent codex   # Codex only
```

`check-transcript-reader.sh` guards the failure mode that is invisible at
runtime: when the format drifts, every consumer keeps working and simply sees an
empty conversation. It runs from pre-commit, prints a machine-readable
`VERDICT:` line, and separates an established drift (a run of empty results at
the newest end) from a single anomalous session from too little evidence to
judge.

Known gaps on Codex sessions: tool outputs carry no error flag, so
`tool_result_err` reads 0, and `thinking` reads 0 because reasoning records are
encrypted.

## Layout conventions

- `_system/` — skills and machinery (symlinked into `~/.claude/skills/` by bootstrap).
- `_tracked/` — files mirrored into `~/.claude/` (rule layers imported by your CLAUDE.md).
- `_tracked/machines/<id>/` — optional per-machine layers; `machines/current` is a
  gitignored symlink set by bootstrap via `_meta/machine-id`.
- `_sessions/` — reflection reports produced by the skills (yours will accumulate here).
- `_meta/` — per-repo metadata (remote config, machine id override).

## Requirements

- Claude Code with skills support
- Codex (optional) — `codex-cli`; the Codex legs are skipped on machines without it
- `git`, `gh` (GitHub CLI) authenticated, `bash`, `python3`, `jq`

## License

MIT — see [LICENSE](LICENSE).
