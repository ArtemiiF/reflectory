# Reflect-archive method

Analytical scaffolding for `/reflect-archive` — batch-reflect over one or more **past**
sessions, then put every proposed change through an adversarial critic that re-reads the
**raw** transcript before any finding reaches the user.

`/reflect-session` reflects on the live conversation Claude already holds. `/reflect-archive`
differs on two axes:

1. **Many / large sessions, none in context.** The transcripts are tens of MB — they do not
   fit. Each session is digested by `session-digest.py` and reflected on by its own sub-agent.
2. **Critic gate.** The single-session skill trusts its own Phase-5 self-test. Here, a separate
   critic re-derives the ground truth from the raw `.jsonl` and tries to *refute* each finding
   before it becomes an approval prompt. This is the defence against the failure mode the base
   method warns about — inventing improvements to justify the run — amplified by batch volume.

The reflection itself is **not** re-invented here. The per-session reflector executes
`reflect-session/method.md` Phases 0–5 verbatim. This file adds only what is new: **selection**,
**the critic rubric**, and **revision / consolidation**.

---

## Phase S — Select sessions

Selection is delegated to `_system/scripts/list-sessions.sh` (deterministic). It returns
top-level session files largest-first, having already dropped `/subagents/` transcripts, the
live session, and any session whose uuid is recorded in a previous run's `source_sessions:`.

- **Default:** top 3 by size. Size is the proxy for signal density — a long session has more
  user turns, more routing, more friction than a short one. It is a proxy, not truth; the user
  may override.
- **Explicit paths** given by the user override the size heuristic entirely (analyse exactly
  those, in the given order).
- **`--top N` / `--min-bytes`** tune the size selection.

Always show the chosen list (size + uuid) and get confirmation before spawning reflectors —
batch volume costs real tokens, and the user may want a different N or specific sessions.

Never silently include the live session: its findings belong to `/reflect-session`, and it is
still being appended to (a moving target).

---

## Phase R — Reflect per session (one sub-agent each)

For each selected session, one sub-agent:

1. Runs `session-digest.py <path> --out <digest-path>` (deterministic projection; also the
   human-readable **dump** of what was analysed).
2. Reads the digest (in chunks if large) and executes `reflect-session/method.md` **Phases 0–5**
   against it.
3. Returns findings in the structured contract below. It does **not** apply anything, does not
   write to the repo, does not commit — it only proposes.

Each finding the reflector returns MUST carry, verbatim from the base method:

- `evidence` — the exact quote (Cluster A) or transcript span (Clusters B/C), with an event
  pointer (`[E00123]`) into the digest.
- `cluster` — the signal id (A1…A8, B1…B13, C1…C6, D1…D2).
- `category` — A / B / C, and for A the scope/class (G / K1 / K2 / K0) per Phase 3.
- `draft` — the concrete rule text / diff / skill skeleton (Phase 4).
- `self_test` — which of the four Phase-5 checks passed.

A reflector that finds nothing on a session returns an empty list — that is a valid, expected
outcome, not a failure. Do not pressure a sub-agent to produce findings.

---

## Phase K — Critic (one sub-agent each, reads the RAW transcript)

The critic is the new gate. It receives one session's findings **plus the path to the raw
`.jsonl`** (NOT the digest). It does not trust the digest — the digest truncates and paraphrases,
so a finding can be an artefact of what the projection dropped.

Context discipline: the critic does **not** load the whole raw file. It works by:

- **grep the quote** — confirm the cited evidence string actually occurs in the raw transcript.
- **read the window** — read the raw lines around the hit to judge meaning-in-context.
- **targeted raw sweep** — grep the raw file for high-signal markers the digest may have hidden
  (friction: `нет`, `не так`, `стоп`, `не туда`, `вернись`, `actually`; repeated tool errors;
  `готово`/`done` immediately followed by an error result) to surface **missed** signals.

For each finding, the critic returns one verdict:

| Verdict | Meaning | Test |
|---|---|---|
| **SUPPORTED** | survives | quote is literally present; context confirms the reading; maps to a real cluster signal; generalises; no conflict |
| **WEAK** | needs one rework | grounded but over-broad trigger, mis-categorised, or quote paraphrased (real but not literal) |
| **UNSUPPORTED** | drop | quote absent / fabricated; context inverts the meaning (e.g. «нет» answered a different question); pure vibe with no actionable cluster |

The critic also emits a **MISSED** list: signals it found in the raw transcript that the
reflector did not report, each with the same evidence/cluster fields a reflector finding carries.

The critic is adversarial by stance: when a finding is borderline, default to WEAK over
SUPPORTED, and to UNSUPPORTED over WEAK. A false drop costs one lost rule; a false pass spends
the user's attention budget on a rule that will misfire or sit dormant.

---

## Phase V — Revise

Apply the verdicts deterministically:

- **SUPPORTED** → carry forward unchanged.
- **WEAK** → rework once (narrow the trigger, fix the category, replace a paraphrase with the
  literal quote). Re-run the Phase-5 self-test on the reworked draft. Still weak → drop with a
  logged reason. **No second rework** (same two-strike rule as the base method).
- **UNSUPPORTED** → drop; log the one-line reason for the session report.
- **MISSED** → treat as a fresh finding: it must pass the full Phase-5 self-test before it joins
  the surviving set (it is grounded in raw evidence already, so it usually does).

---

## Phase C — Consolidate across sessions

Findings from different sessions are merged before they reach the user:

- **Same rule, multiple sessions** → one finding carrying **all** evidence pointers (uuid +
  event). Recurrence across sessions is the strongest possible signal — say so in the approval
  prompt. Do not present the same rule N times.
- **Near-duplicate drafts** → keep the more specific draft; fold the other's evidence into it.
- **Cross-session contradiction** (two sessions imply opposite rules) → do not pick a winner;
  surface both to the user as a single «these conflict — which holds?» prompt.

The consolidated, deduped set is what hands off to `/reflect-archive` SKILL Step 6 (the existing
per-finding approval / apply / commit machinery of `/reflect-session`).

---

## What this method is NOT

- **Not a re-implementation of the reflection method.** Phases 0–5 live in
  `reflect-session/method.md` and are executed there. If the base method changes, this skill
  inherits it for free.
- **Not a way to skip approval.** The critic narrows the set; it never approves. Every survivor
  is still an independent user approval (no batch approval, no silent apply).
- **Not exhaustive.** Several clean sessions legitimately produce zero surviving findings. The
  honest output of a batch run can be «3 sessions, nothing worth a rule». Inventing findings to
  justify the token spend is the exact defect the critic exists to catch.
