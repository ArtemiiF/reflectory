---
name: reflect-archive
description: >-
  Batch-reflect over one or more PAST Claude Code sessions (largest first) and propose
  improvements to the user's Claude configuration, with an adversarial critic that re-reads
  the raw transcript to refute weak findings before they reach approval. Each surviving change
  is approved per-item; applied changes persist in ~/.claude/local-forks/ exactly like
  /reflect-session. All long-lived knowledge is stored in `.md` files — auto-memory is not used.
  MANDATORY TRIGGERS: "/reflect-archive", "пройдись по большим сессиям", "разбери большие сессии",
  "проходись по самым большим сессиям", "отрефлексируй прошлые сессии", "reflect archive",
  "batch reflect", "разбери прошлые сессии".
  DO NOT use for: reflecting on the CURRENT live conversation (that is /reflect-session — this
  skill explicitly excludes the live session); writing production code; fixing bugs in user
  repos; any change that is not a local configuration improvement.
argument-hint: "[--top N] [--min-bytes BYTES] [paths...]"
---

# /reflect-archive

Walk back through the largest past sessions (or explicit ones), reflect on each in its own
sub-agent, put every proposed change through a critic that re-reads the **raw** transcript, then
hand the surviving, consolidated set into the same per-finding approval / apply / commit pipeline
as `/reflect-session`.

The system is described in `README.md` (overview, layout, fork lifecycle). The analytical
scaffolding is split: **batch orchestration + critic** here in `method.md`; the **per-session
reflection** reuses `reflect-session/method.md` Phases 0–5 (single source of truth — this skill
does not duplicate it).

## Inputs

- `--top N` — analyse the N largest sessions (default 3).
- `--min-bytes BYTES` — floor on session size.
- explicit `paths...` — absolute paths to `.jsonl` files; override the size heuristic entirely.

This skill never reads the live conversation; for that use `/reflect-session`.

## Preconditions

Same as `/reflect-session`: `~/.claude/local-forks/` is a git repo with a reachable `origin`,
`gh` is authenticated, and the user has consented to local mutations (running this skill counts).
If pre-flight is not `READY`, run the init wizard first.

## Algorithm

Steps run strictly in order. A step that fails twice → stop, surface state, do not retry a third
time. **The orchestrator never loads a raw transcript or a digest into its own context** — both
are tens of MB to ~1 MB; all reading happens inside sub-agents.

### Step 0. Pre-flight

Execute `~/.claude/local-forks/_system/_shared/init-remote.md`. Proceed only after `READY`.

### Step 1. Select sessions (method Phase S)

Run the selector:

```
bash ~/.claude/local-forks/_system/scripts/list-sessions.sh [--top N] [--min-bytes B] [--exclude UUID]...
```

It returns `bytes<TAB>uuid<TAB>path`, largest first, with `/subagents/`, the live session, and
already-studied sessions (from prior `source_sessions:`) already removed. If the user gave
explicit paths, skip the selector and use those.

Present the chosen list (size + uuid) via `AskUserQuestion` and confirm before spawning anything
— batch reflection costs real tokens, and the user may want a different N or specific sessions.

### Step 2. Reflect per session (method Phase R)

For each selected session, spawn **one** sub-agent (general-purpose), in parallel. Each agent's
prompt instructs it to:

1. Run `python3 ~/.claude/local-forks/_system/scripts/session-digest.py <raw-path> --out <scratch>/<uuid>.digest.txt`.
2. Read the digest (chunked if large) and execute `~/.claude/skills/reflect-session/method.md`
   **Phases 0–5** against it.
3. Return findings in the structured contract from `method.md` Phase R (`evidence` with `[E…]`
   pointer, `cluster`, `category` + scope/class, `draft`, `self_test`). Propose only — apply
   nothing, write nothing to the repo, do not commit.

Collect each agent's findings keyed by session uuid. An empty result for a session is valid.

### Step 3. Critic per session (method Phase K)

For each session that produced ≥1 finding, spawn **one** critic sub-agent (general-purpose). Give
it the session's findings **and the path to the raw `.jsonl`** (not the digest). Its prompt
instructs it to follow `method.md` Phase K: grep each cited quote in the raw transcript, read the
surrounding window for meaning-in-context, run a targeted raw sweep for missed friction/error
signals, and return per-finding verdicts (`SUPPORTED` / `WEAK` / `UNSUPPORTED`) plus a `MISSED`
list. The critic refutes; it never approves.

### Step 4. Revise (method Phase V)

Deterministically apply verdicts: keep `SUPPORTED`; rework `WEAK` once then re-run the Phase-5
self-test (still weak → drop); drop `UNSUPPORTED` with a logged reason; promote `MISSED` to fresh
findings that must pass the Phase-5 self-test. The rework may be done by the orchestrator directly
(it is small text work) or delegated back to the reflector sub-agent.

### Step 5. Consolidate (method Phase C)

Merge across sessions: one finding per rule carrying all evidence pointers; recurrence across
sessions is the strongest signal and is stated in the approval prompt. Surface cross-session
contradictions as a single «which holds?» prompt rather than picking a winner.

### Step 6. Per-finding approval + apply

Hand the consolidated set into `/reflect-session` **Step 4** (per-finding `AskUserQuestion`:
label, evidence, category/rule-id, concrete diff, options `Apply` / `Skip` / `Edit` / `Discard`)
and **Step 5** (apply order A → C → B; same target-file rules per scope/class). No batch approval;
no silent edits.

### Step 7. Session log, commit, push, notice

Write one consolidated run log to `~/.claude/local-forks/_sessions/<YYYY-MM-DD>T<HH-MM>-reflect.md`
using the `/reflect-session` Step 5.5 layout, with one addition: a **`source_sessions:`** YAML
block in the frontmatter listing every analysed uuid — this is the dedup ledger
`list-sessions.sh` reads, so the next run skips these sessions.

**Deliberate divergence from `/reflect-session` Step 5.5:** that step skips the log when all
three finding counters are zero. `/reflect-archive` **always** writes the log, even on a
zero-finding batch, because the `source_sessions:` ledger must advance — otherwise the same large
sessions are re-selected and re-analysed on every run. A zero-finding log is the minimal record:
frontmatter (with `source_sessions` and zero counters) plus a one-line body noting nothing
surfaced.

```yaml
---
date: <YYYY-MM-DD>
session_topic: batch reflect over <N> past sessions (<short theme>)
source_sessions:
  - <uuid-1>
  - <uuid-2>
findings_applied: <int>
findings_skipped: <int>
findings_discarded: <int>
---
```

The body is the per-finding blocks (each tagged with its source uuid in the evidence) plus the
`## Decay check` section, exactly as `/reflect-session` Step 5.5 prescribes. Then run the same
pre-commit gates and push as `/reflect-session` **Step 6** (`build-index.sh`,
`validate-frontmatter.sh`, `update-last-push.sh`, single commit, push to the remote default
branch), and give the **Step 7** final notice (what applied vs skipped; `/reload-plugins` if any B
finding landed).

## Anti-patterns

- **No batch approval.** Each surviving finding is approved on its own — same as `/reflect-session`.
- **Orchestrator never reads raw/digest.** If you find yourself `Read`-ing a 20 MB `.jsonl` or a
  1 MB digest in the main context, stop — that work belongs to a sub-agent.
- **Critic reads raw, not the digest.** A critic handed the digest cannot catch findings that are
  artefacts of what the projection dropped — the entire point of the gate is lost.
- **No invented findings to justify the spend.** A batch run that surfaces nothing is a valid
  outcome; report «N sessions, nothing worth a rule».
- **Never include the live session.** It belongs to `/reflect-session` and is still being written.
- **No second rework.** A `WEAK` finding reworked once and still weak is dropped, not re-reworked.

## Failure handling

| Symptom | Response |
|---|---|
| Pre-flight not `READY` | Stop, hand off to the init wizard, do not proceed. |
| `list-sessions.sh` returns nothing | Tell the user (all sessions already studied / below floor / only the live session exists) and stop. |
| A reflector sub-agent dies | Note the skipped session in the report, continue with the rest. Do not block the batch on one session. |
| Plugin-cache version differs from `_meta.json` for a B finding | That is a `/sync-upstream` job — surface and stop (same as `/reflect-session`). |
| `git push` fails after one retry | Local commit stays; surface the error and the manual `git push` command. |
| User declines all findings | Exit cleanly with «no changes applied»; still write the session log with `source_sessions` so the dedup ledger advances. |
