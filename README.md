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
- **Skill and plugin targeting** — each skill declares which machines and which
  agents it belongs on, and so does every marketplace plugin whose own rule
  file should reach the assembled rule layer. Both live as entries in one
  `_tracked/registry.json` (schema: `_system/_shared/registry-schema.md`); a
  data repo that has not migrated keeps declaring skills one `install.json`
  per skill instead (schema: `_system/_shared/install-manifest.md`) and has no
  plugin roster at all — both are read by the same resolver. Either way, a
  WSL-only skill stays off your laptop and a Claude-specific one never ships
  into Codex.
- **Deterministic gates** — a pre-commit hook validates rule frontmatter on every
  commit; scripts (not prose) rebuild the index, digest sessions, and compute
  rule-usage stats. The prose instructions are advisory; the hooks fire regardless.
- **Live correction capture** — an optional `UserPromptSubmit` hook snapshots
  correction-bearing prompts («не так», "that's wrong", …) into a local queue the
  moment they happen; the next `/reflect-session` consumes the queue, so corrections
  survive even from sessions you never reflected on. Registration is one manual
  settings.json step (see `_system/scripts/capture-corrections.py` header).
- **Layered rules** — rules split into portable general discipline (L1), your
  idiolect and personal-but-portable discipline (L2), per-machine identity and
  environment (L3), and rules specific to one agent's plugins on one machine
  (L4), so each machine (and each agent on it) loads exactly the layers that
  apply. A data repo that has not migrated past the pre-registry layout keeps
  the equivalent split under its old names (general discipline (G), orchestrator
  discipline (K0), idiolect (K1), environment maps (K2)).
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
| `_system/scripts/skill-targets.sh` | Resolves which skills — and, from a registry, which plugins — install/attach on this machine, for which agent |
| `_system/scripts/build-agents-md.sh` | Projects the tracked rule layers (and, from a registry, the resolved plugin set) into Codex's `AGENTS.md` |
| `_system/scripts/transcript_reader.py` | Translates Codex rollouts into Claude-shaped records — one parser for both |
| `_system/_shared/` | Metadata schema, registry schema, and remote-init wizard used by the skills |
| `_system/_shared/registry-schema.md` | Schema for `_tracked/registry.json` — the skill + plugin targeting registry |
| `_tracked/general-rules.md` | Starter set of universal agent-discipline rules (class G, legacy layout), harvested from real sessions |
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

### Option A2 — install into Codex

Codex reads the same repository. Its plugin loader accepts this plugin's manifest
directly, and the bundled `.codex-plugin/plugin.json` gives it a native entry:

```
codex plugin marketplace add ArtemiiF/reflectory
codex plugin add reflectory@reflectory
```

Skills then appear namespaced — `reflectory:reflect-session` and the rest.

Two things a Codex install does not do, both on purpose:

- **Hooks stay manual.** A plugin-declared `hooks` entry does fire, but the hook
  scripts need the event payload on stdin (the prompt text, the transcript path),
  and only a user-level registration was measured to deliver it. Add these to
  `~/.codex/hooks.json`, merging with whatever is already there:

  ```json
  { "hooks": {
      "UserPromptSubmit": [ { "hooks": [ { "type": "command",
        "command": "python3 ~/.claude/plugins/marketplaces/reflectory/_system/scripts/capture-corrections.py" } ] } ],
      "Stop": [ { "hooks": [ { "type": "command",
        "command": "python3 ~/.claude/plugins/marketplaces/reflectory/_system/scripts/reflect-reminder.py" } ] } ]
  } }
  ```

  Codex pins a `trusted_hash` per hook in `config.toml` and will ask to trust the
  new entries once.

- **Targeting does not apply.** `install.json` governs the `bootstrap.sh` install
  path — which skill belongs on which machine and agent. A plugin install hands
  Codex every skill in the plugin, so `/reflect-session` and `/reflect-archive`
  are available there even though their manifests target Claude Code; their prose
  is agent-neutral, but the delegation contract under Codex is not yet exercised.

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

This manual step is for a data repo without `_tracked/registry.json` (either
option above starts you there). Once your data repo migrates to a registry
(a data-repo change, not part of this engine — see the Registry section
below), stop hand-editing `~/.claude/CLAUDE.md` entirely: `bootstrap.sh`
writes and refreshes it directly from then on. Remove any hand-written
`~/.claude/CLAUDE.md` before that first registry-mode `bootstrap.sh` run —
bootstrap.sh never overwrites a file lacking its own stamp, so a leftover
hand-written root would otherwise sit there unmanaged.

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
R="${CLAUDE_PLUGIN_ROOT:-$(head -1 "${LOCAL_FORKS:-$HOME/.claude/local-forks}"/_meta/machinery-root 2>/dev/null)}"
[ -d "${R}/_system/scripts" ] || echo "no machinery pointer — run bootstrap.sh first" >&2
"${R}"/_system/scripts/build-agents-md.sh          # write $CODEX_HOME/AGENTS.md
"${R}"/_system/scripts/build-agents-md.sh --check  # stale?
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

### Registry

A data repo with `_tracked/registry.json` declares two kinds of entry, each
with the same two axes — `machines` and `agents`:

```json
{ "entries": [
    { "name": "reflect-session", "kind": "skill", "layer": "root",
      "machines": ["all"], "agents": ["claude", "codex"] },
    { "name": "neuro-matrix", "kind": "plugin", "layer": "agent",
      "machines": ["mbp-filanovskii"], "agents": ["claude"],
      "import": "CLAUDE.md" }
] }
```

`kind: "skill"` entries replace the per-skill `install.json`; `kind: "plugin"`
entries are new — the plugin roster this repo did not have before. A plugin
entry's `import` (a file inside the plugin's own install directory, e.g. its
`CLAUDE.md`) is attached to the assembled rule layer only for the agents and
machines listed — never both agents unconditionally the way a hand-written
`@import` line inside a machine file used to. Where the plugin actually lives
on disk is never typed by hand: `skill-targets.sh` reads it from the agent's
own plugin-manager state (`installed_plugins.json` for Claude, the plugin
cache tree for Codex) — schema and full resolution rules in
`_system/_shared/registry-schema.md`.

**The live Claude root, once migrated.** With `_tracked/registry.json`
present, `bootstrap.sh` writes `~/.claude/CLAUDE.md` directly — the L1-L4
layers plus every plugin resolved for `claude` on this machine — and
refreshes it on later runs (a stamp in the file's first line marks it as
bootstrap's own; a hand-written root is never touched). `_tracked/CLAUDE.md`
plays no part here: a plugin's resolved path is this machine's own
filesystem location, and that file is git-tracked and shared across every
machine, so nothing machine-specific is ever written there. If this machine
already has a hand-written `~/.claude/CLAUDE.md` from before migrating, back
it up and remove it once, then run `bootstrap.sh` to switch to the generated
root.

**Transition mode.** A data repo with no `_tracked/registry.json` is
unaffected by any of this — `bootstrap.sh`, `build-agents-md.sh`,
`skill-targets.sh` and `validate-manifests.sh` all fall back to exactly the
pre-registry behaviour: per-skill `install.json`, no plugin roster, the
`general-rules.md` / `shared.md` / `machines/current/CLAUDE.md` layer names.
Nothing here is a breaking change until a data repo creates `registry.json`.

### Skills

A skill declares its two axes either as a `kind: "skill"` entry in
`_tracked/registry.json` (above) or, in a data repo that has not migrated,
beside its own `SKILL.md`:

```json
{ "machines": ["home-wsl"], "agents": ["claude", "codex"] }
```

`machines` is `["all"]` or ids from `_tracked/machines/<id>/`; `agents` is any
subset of `claude`, `codex`. No entry/manifest means `machines: ["all"]`,
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
- `_tracked/` — rule layers your CLAUDE.md `@import`s: `L1-general.md`,
  `L2-culture.md` (or the legacy `general-rules.md` / `shared.md` on a repo
  that has not migrated), plus, once migrated, `registry.json` — the skill +
  plugin targeting registry, read by `bootstrap.sh`/`build-agents-md.sh`, not
  itself mirrored or imported anywhere.
- `_tracked/machines/<id>/` — per-machine layers: `role.md`, `environment.md`,
  `rules.md` + `k2-environment.md`, `agents/<agent>.md` — or the legacy single
  `CLAUDE.md` per machine. `machines/current` is a gitignored symlink set by
  bootstrap via `_meta/machine-id`.
- `_sessions/` — reflection reports produced by the skills (yours will accumulate here).
- `_meta/` — per-repo metadata (remote config, machine id override).

## Requirements

- Claude Code with skills support, or Codex, or both
- Codex users: `codex-cli` 0.154 or newer (earlier versions wrote transcripts in a shape the reader also understands, but the skill install shape was measured against 0.154)
- `git`, `gh` (GitHub CLI) authenticated, `bash`, `python3`, `jq`

## License

MIT — see [LICENSE](LICENSE).
