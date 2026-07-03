---
name: reflect-compress
description: >-
  Audit and compress the accumulated rule layer against reality: batch-prune
  dormant rules (rule-stats.py feed), fix or drop rules pointing at dead paths
  (check-stale-refs.py feed), merge near-duplicates, resolve contradictions,
  tighten verbose bodies. Every change requires per-item user approval; git is
  the backup — no silent deletion, ids preserved for decay continuity.
  MANDATORY TRIGGERS: "/reflect-compress", "сожми правила", "сожми конфиг",
  "compress config", "audit rules", "почисти правила".
  DO NOT use for: harvesting NEW rules from a session (that is /reflect-session),
  re-applying plugin forks (/sync-upstream), editing workspace CLAUDE.md files
  (out of scope for the tracked layer), or any change that is not a reduction /
  repair of already-existing rules.
argument-hint: "[optional: path to a specific rule file to compress]"
---

# /reflect-compress

`/reflect-session` is the add channel; its Phase 0 prunes at most 2 dormant rules per run as a side effect. Nothing walks the WHOLE rule layer and asks «what here is dead weight?» — so the always-on context grows monotonically. This skill is the dedicated subtract channel: a batch audit of the existing rules against dormancy stats, the live filesystem, and each other, ending in per-item-approved reductions.

The analytical scaffolding is in `method.md` (five audit phases). The system layout is in `README.md`.

## Inputs

- Rule files. No argument → the whole tracked layer: every rule `.md` under `~/.claude/local-forks/_tracked/` (including `machines/*/` layers and lazy reference files like `k2-environment.md`). Argument → that file only.
- `python3 ~/.claude/local-forks/_system/scripts/rule-stats.py --dormancy` — the dormancy feed.
- `python3 ~/.claude/local-forks/_system/scripts/check-stale-refs.py <files>` — the dead-pointer feed.

## Preconditions

Same as `/reflect-session`: `~/.claude/local-forks/` is a READY git repo (pre-flight per `_system/_shared/init-remote.md`); running this skill is consent to local file mutations.

## Algorithm

Steps run strictly in order; a step failing twice → stop and surface.

### Step 1. Collect machine feeds

Run both scripts above. Their output is the evidence floor: a prune or repair proposal without a feed line (or, for contradiction/merge/verbosity findings, without quoted rule text) is invalid by construction.

### Step 2. Audit using the compress method

Open and read `method.md` at `~/.claude/local-forks/skills/reflect-compress/method.md` (same both-install-modes guarantee as reflect-session's method). Execute its phases in order — X (stale refs), D (dormancy), C (contradictions), M (merge), V (verbosity) — then the shared self-test.

Cap: **max 10 findings per run**, priority X > D > C > M > V (repairs before prunes before polish). A healthy rule layer legitimately produces zero findings — inventing reductions to justify the run is a defect.

### Step 3. Per-finding approval

One `AskUserQuestion` per finding — never bundled:

- Short label, the machine-feed line or quoted rule text as evidence.
- The exact before → after diff (deletion shows the full rule being deleted).
- Options: `Apply`, `Skip`, `Edit and re-show`, `Discard with reason`.

### Step 4. Apply approved findings

- Edit the layer file in place — it is the single source (the live `~/.claude/CLAUDE.md` is a thin root that `@import`s the layer files, so the edit is live from the next session). Legacy setup where the live `~/.claude/CLAUDE.md` still duplicates a tracked file: apply to BOTH copies in one approval — fail one, roll back the other.
- **Id continuity:** a surviving (tightened / merged-into) rule keeps its `<!-- id: ... -->` comment unchanged — the decay aggregator joins on it. A merged-away or deleted rule's id goes into the session log's `retired_ids` (Step 5); `rule-stats.py` reads compress logs and drops retired ids from the `--dormancy` feed and the decay table — without this, a deleted rule's trailing dormant run would re-surface as a forced decay finding in every subsequent `/reflect-session`. Retirement is dated: decay lines newer than it (a rule re-added under the same id) bring the id back into the feed.
- No backup files: the repo IS the backup — every state is one `git revert` away.

### Step 5. Session log, commit, push

Write `~/.claude/local-forks/_sessions/<YYYY-MM-DD>T<HH-MM>-compress.md`:

```yaml
---
date: <YYYY-MM-DD>
mode: compress
findings_applied: <int>
findings_skipped: <int>
findings_discarded: <int>
retired_ids:            # ids of deleted/merged-away rules, [] if none
  - <rule-id>
---
```

Body: one `## Finding N (applied | skipped | discarded) — <label>` block per finding with **Phase** (X/D/C/M/V), **Evidence** (feed line or quotes), **Diff** (or reason for skip/discard). Skip the log only when all three counters are zero.

Then the same commit pipeline as `/reflect-session` Step 6: `build-index.sh`, `validate-frontmatter.sh`, `update-last-push.sh`, one commit (`compress: <N> findings — <short labels>`), push to the remote default branch, single retry on push failure.

### Step 6. Final notice

Applied vs skipped vs discarded; net line-count delta of the rule layer («−41 lines»); reminder that A-rule changes take effect next session start (CLAUDE.md is read at session start, not live).

## Anti-patterns

- **No semantic weakening.** Compression rewrites form, never scope: a tightened rule must still fire on every trigger its long form fired on. When in doubt — Skip.
- **No batch approval, no silent deletion** — same bar as /reflect-session.
- **No new rules.** A gap discovered while compressing is a /reflect-session observation, not a compress finding.
- **No cross-file «while we're here».** Only the target rule files are touched.

## Failure handling

| Symptom | Response |
|---|---|
| Pre-flight not READY | Stop, hand off to the init wizard. |
| `rule-stats.py --dormancy` empty (no history yet) | Phase D legitimately yields nothing — proceed with X/C/M/V only. |
| Legacy mirror setup: live `~/.claude/CLAUDE.md` duplicates `_tracked/CLAUDE.md` and they differ before the run | Surface the drift and stop — reconcile first (manual or /reflect-session), compressing a forked pair doubles the divergence. |
| Push fails after one retry | Local commit stays; surface the error and the manual push command. |
