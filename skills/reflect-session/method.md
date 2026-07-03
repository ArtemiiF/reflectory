# Reflection method

Analytical scaffolding for `/reflect-session` Step 2 — how to turn raw conversation observations into actionable improvement proposals. Read this file at the start of Step 2.

The goal is **falsifiable improvements**, not vibes. Every proposed change must be tied to a concrete observation, not «in general it would be nicer if…».

## Phase 0 — Rule efficacy review (decay check)

Every applied A-finding grows the always-on global CLAUDE.md; a rule whose trigger never re-occurs pays attention-budget rent without returns. Before observing the new session, audit what past runs produced.

1. Read the dormancy aggregate — the single source of truth for the decay counter:
   ```
   python3 ~/.claude/local-forks/_system/scripts/rule-stats.py --dormancy
   ```
   It emits one `key<TAB>N<TAB>label` line per audited rule, sorted by N desc. **N is computed from the full history** (length of the trailing run of `dormant` marks for that rule's stable id / normalised label), NOT carried forward from the previous log. A single missing `## Decay check` section therefore no longer resets the count — this is what keeps the prune channel alive (the add channel runs every session; the counter must not silently reset under it).
2. For each rule applied **≥3 reflect-runs ago**, check against the current session source:
   - Did its trigger condition occur this session?
   - If yes — did the rule hold (the mistake it encodes did not happen)?
3. Classify each audited rule:
   - **validated** — trigger occurred, behaviour correct. Record; no action.
   - **dormant(N)** — trigger not seen this session. N = the aggregate value from step 1, +1 for this run's dormant mark.
   - **misfiring** — trigger occurred but the rule did not help, or actively hurt. Becomes a regular observation: feed it into Phase 1 with the transcript span as evidence.
4. **Forced decay finding.** Any rule whose aggregate **dormancy ≥5** MUST become a decay finding this run (up to the 2-finding cap, highest N first) — propose, as a normal Category A approval item, removing it from always-on CLAUDE.md (delete, merge into an adjacent rule, or demote to a lazily-read reference file). Per-finding approval applies; never silently delete. The aggregate makes this non-optional: if `--dormancy` reports N≥5, the run does not finish without surfacing the removal proposal.

Caps and recording:

- At most **2 decay findings per run** (highest dormancy first) — the decay channel must not crowd out fresh observations.
- Write the audit result into the session log (`## Decay check` section, Step 5.5) — one line per audited rule: `- [<rule-id>] <rule label> — validated | dormant(N) | misfiring`. The `[<rule-id>]` prefix is what the aggregator keys on (Phase 4 assigns it; legacy id-less rules fall back to their normalised label). The counter itself is now derived by `rule-stats.py --dormancy` from the whole history, so a missing section degrades the trend's resolution but no longer resets the count.
- When the session source is a past `.jsonl` (argument mode), Phase 0 still runs — the trigger-occurrence question is asked against that transcript.

Phase 0 produces at most: decay findings (→ Phase 6 approval) and misfiring observations (→ Phase 1 input). It never mutates anything itself.

## Phase 1 — Observe

Walk the conversation chronologically. For each turn, record observations grouped into four clusters. **The agent-side signals (B) and the discipline signals (C) are the easiest to miss** because they require no user correction — pretend an external auditor is reading the transcript without context.

A second input feeds Cluster A: the corrections queue (`_local/corrections-queue.jsonl`, captured live by `capture-corrections.py` — see SKILL.md Step 2). Queue entries from other sessions arrive without surrounding context; before using one as an observation, recover its context from that session's transcript if it still exists, and drop the entry if the context is unrecoverable — a bare correction quote fails the observation contract below.

### Cluster A — User-side signals (visible from user messages)

| # | Type | What it looks like |
|---|---|---|
| A1 | **Friction** | User says «нет», «не так», «стоп», «не делай», «не надо», «не туда», «вернись», «убери», «actually», «that's wrong» |
| A2 | **Re-routing** | User redirects to a different tool / skill / agent / category. «делай через X, а не Y», «не этим подсосом» |
| A3 | **Re-clarification** | The agent asked something the user already answered in an earlier turn |
| A4 | **Unprompted user help** | The user fills in context the agent should have looked up itself (paths, version numbers, links the agent could grep) |
| A5 | **Decision reversal** | The agent proposed A, user pushed back, ended at B — and B was discoverable from prior turns |
| A6 | **Explicit «remember» / preference** | User says «remember:», «всегда делай», «никогда», «по умолчанию» — highest-confidence rule candidate |
| A7 | **Positive validation of a non-obvious choice** | User explicitly approves an unusual decision («да, именно так и надо», «то что нужно», «отлично») — captures a validated judgment call, prevents the agent from second-guessing it next time |
| A8 | **Idiolect gap** | Agent interpreted a user phrase as X; a later turn shows the user meant Y (reversal, re-explanation, «я имел в виду», «нет, я про…»). Distinct from A1: friction is the symptom, A8 captures the reusable mapping «phrase → intent» so the same phrase is read correctly next session. Highest-value signal for the mutual-understanding goal (VISION.md, K1) |

### Cluster B — Agent-side signals (transcript shows thrashing, no user correction)

These are the most underused signals. Industry term: **agent observability** / «plan-vs-delivery drift». Pretend you are reading another agent's transcript and grading it.

| # | Type | What it looks like |
|---|---|---|
| B1 | **Trial-and-error loop** | Agent invoked A → null, B → error, C → 404, D → worked. No user correction in between. The improvement: identify the signal that would have pointed at D from the start. |
| B2 | **Wrong tool / wrong subagent (single mid-flight switch)** | Agent picked subagent / MCP call / grep pattern / file path that didn't fit, switched mid-flight. Distinct from B1 in being a single bad pick, not a sequence. |
| B3 | **Hallucination caught** | Agent stated a fact (file path, API name, version, function signature) that turned out wrong, surfaced by a tool result or by the user. Improvement: «verify by Read/grep before stating». |
| B4 | **Stale-context reasoning** | Agent read file at turn N, edited or another tool mutated state at turn M, in turn K agent reasons from the turn-N snapshot. State has moved on; reasoning has not. |
| B5 | **Premature completion claim** | Agent said «done», «готово», «всё работает», «зелёный» — and the next message (tool result, user reply) shows it isn't. Failure of self-test gate. |
| B6 | **Plan-vs-delivery drift** | Agent stated plan A. Executed A′ (subtly different). Drift was not surfaced before delivery. |
| B7 | **Over-fetching / wasted reads** | Agent ran N file reads / greps / API calls where 1 would have done. Often: `ls -la` on a directory whose layout was already known, or repeated `Read` on the same file. |
| B8 | **Late clarification** | Agent committed to a plan, started executing, then asked a clarification mid-flight that should have come during planning. |
| B9 | **Repeated-within-session mistake** | Agent made mistake X early in the session, corrected to Y, then later in the same session did X again. Self-supersedure failure. |
| B10 | **Skipped grounding** | Agent reasoned about library / framework behaviour from training instead of grepping / reading current code, or read a file but then ignored what it read. |
| B11 | **Retry loop without diagnosis** | Same operation retried 3+ times with cosmetic changes (different flag, slight prompt tweak) when the root cause was structural. The 2-strike rule was crossed without escalating. |
| B12 | **Asking when knowing** | Agent asked the user for information that one tool call would have produced. |
| B13 | **External-system anchor thrashing** | Agent ran a discovery call (`list_datasources` / `list_channels` / `search_repos` / `list_*` / `find_*`), picked a candidate by guess, ran the actual query against it, got empty / 404 / `unknown_uid` / `no_such_channel` — then retried with a different candidate. Or: declared «not found» / «нет данных» after one empty result without re-running discovery. The improvement: on first successful resolution, save the anchor as a `reference`-type memory entry; on subsequent empty result, treat as «anchor moved» (re-discover) before declaring «not found». |

### Cluster C — Discipline / protocol signals (compare to user's stated rules)

These are violations of rules the user already stated — in `CLAUDE.md`, in earlier turns of the session, or in MEMORY.md. Each one means the rule exists but the agent missed it.

| # | Type | What it looks like |
|---|---|---|
| C1 | **Format violation** | User has a stated format preference (terse, no preamble, no trailing summary). Agent produced the opposite. Pattern visible across multiple turns. |
| C2 | **Tool-protocol violation** | Plain-text «[1] [2] [3]» choice presented to the user when `AskUserQuestion` was required; or `AskUserQuestion` used for trivial confirmations where prose was fine. |
| C3 | **Skepticism mis-calibration** | Trivial task got Critical-level interrogation (over-plan, procrastination); or Complex task got Trivial treatment (no plan, premature execution). Outcome shows the mismatch. |
| C4 | **Author/executor mode bleed** | Author-mode artefact (skill, agent, CLAUDE.md) contains session-specific symbols (real class names, ticket IDs, branch names); or executor-mode artefact uses abstract placeholders. |
| C5 | **Missed re-grounding** | A relevant entry exists in `MEMORY.md`, `CLAUDE.md`, or an earlier turn that would have informed the action. The agent did not re-read it and contradicted or ignored it. |
| C6 | **Implicit-consent violation** | Agent took a destructive action (push, force-push, MR merge, delete, close ticket) without explicit per-action consent for that specific operation. |

### Cluster D — Positive validated patterns (worth preserving, not «fixing»)

| # | Type | What it looks like |
|---|---|---|
| D1 | **Successful non-obvious choice** | Agent chose a non-default path, user approved without correction or pushback. Encoding this prevents the next session from second-guessing the same choice. |
| D2 | **Quiet preference confirmation** | User accepted an unusual style / tone / scope choice without commenting — implicit endorsement. Lower confidence than D1, but worth checking against existing rules to consolidate. |

---

For every observation record four things:

- **Evidence** — exact text quote for Cluster A; for Clusters B and C, a precise transcript span citing tool calls / turn numbers (e.g. «turn 12-15: `mcp__yandex-tracker__issues_find` → empty result; then `issue_get` → 404; then `issues_find` with different filter → hit»)
- **Turn pointer** — short anchor like «турн 4, после Bash на check-plugin-cache»
- **Agent action** — what the agent actually did
- **Expected action** — what the user wanted (A) / what the right first move would have been (B) / what rule was violated (C) / what made the choice successful (D)

Observations missing any of the four fields are dropped, not interpreted further.

### Anti-noise filter

Do **not** record:
- One-word filler («да», «ок», «круто», «го») unless it answers an open question.
- Single phrasing reformulations (the user mistyped, then re-typed).
- Banter, off-topic exchanges.
- Speech-to-text artefacts not corresponding to a substantive instruction.

Reflexion paper's lesson ([arxiv:2303.11366](https://arxiv.org/abs/2303.11366)) is that verbal feedback only improves behaviour when it is **specific and actionable**. Vague observations produce vague rules that misfire.

If a candidate observation does not have all four — drop it. Vague impressions do not feed improvements.

## Phase 2 — Filter for generalisability

For each observation answer two questions:

1. Can the **trigger condition** be described in one plain-language sentence that does not name today's specific task?
2. Can the **fix** be described as a rule that would apply to plausible future sessions, not only this one?

Yes / yes → continue.
Anything else → discard with a one-line reason (logged for the user in the final report, not silently dropped).

Discards include:
- One-off task specifics («for this particular MR…»)
- Personal-style preferences too narrow to encode
- Speech-to-text noise (e.g. user typed something garbled, then re-typed clearly — only the second take matters)
- Items the user already corrected mid-session — the correction is the record, no new rule needed

## Phase 3 — Categorise (A / B / C)

Apply this decision tree to each surviving observation. Pick the **cheapest** category that actually addresses the cause.

```
Is the fix about HOW the orchestrator behaves (discipline, tone, when to use which skill/agent)?
  → A — CLAUDE.md rule
    Then refine: A1 (global) or A2 (workspace)? See "Category A split" below.

Is the fix about the INTERNAL BEHAVIOUR of a specific plugin skill / agent / command?
  → B — fork that plugin artefact

Is the fix a NEW stable pattern not covered by any existing skill?
  → C — new local skill in ~/.claude/skills/<name>/

None of the above?
  → Discard.
```

### Category A split — A1 (global) vs A2 (workspace)

Once an observation lands in Category A, decide where it goes:

| Sub-category | Target file | When to pick |
|---|---|---|
| **A1** | a layer file under `~/.claude/local-forks/_tracked/` — which one is decided by scope/class below | Rule describes orchestrator behaviour that should apply **regardless of which workspace is open**: tone, response format, when to use which tool, skepticism calibration, agent invocation discipline. |
| **A2** | `<workspace>/.claude/CLAUDE.md` (not mirrored) | Rule references **specific paths, branch-naming conventions, CI specifics, team processes, or tooling that belongs to one workspace's repo**. |

**Recognition heuristic — pick A2 if any of these hit:**

- The rule names a path under `/home/coder/workspace/...` or a similar workspace-rooted location.
- The rule references branch-naming (`username/...`), MR-flow specifics, CI pipeline behaviour, or other team-process conventions.
- The rule depends on tooling that only one workspace uses (`dotnet`, `glab`, `helm`, a project-specific NuGet feed).
- The rule cites a workspace-local CLAUDE.md, AGENTS.md, or CONTRIBUTING.md that doesn't exist in `~/`.

**Otherwise pick A1.** When in doubt → A1 is the safer default (the global file always applies; a workspace-only rule may never fire if you switch contexts).

### Category A scope — общее (G) vs личное (then K-class)

Every Category A finding is first split by **scope** (VISION.md «Ось общие/личные»), then — if personal — by knowledge-class.

**Step 1 — scope.** Ask the load-bearing question: *would this rule fire for a different user on a different machine, with no edits?*

- **Yes → общее (G).** Universal orchestrator discipline — how Claude should work in principle, no reference to this user, their environment, paths, projects, or idiolect (e.g. algorithm-diagnosis gate, evidence-based-medicine protocol, staged-diff check before commit, «record project conventions in the project's own CLAUDE.md»). Tag **G**, id-prefix `g-`, lands in `~/.claude/local-forks/_tracked/general-rules.md` (portable, `@import`-ed into CLAUDE.md). When in doubt → NOT G (keep the shared file clean; a mis-filed personal rule leaks this user's context into a portable artefact).
- **No → личное.** Tied to this setup. Continue to Step 2.

**Step 2 — knowledge-class (personal findings only):**

| Tag | Class | Covers |
|---|---|---|
| **K1** | Mutual-understanding profile | lexicon mappings (phrase → intent, typical source A8), format preferences (A6, A7, C1), input-pattern markers («именно» = verbatim) |
| **K2** | Environment map | command recipes that survived trial-and-error (B1), tool quirks (WSL / NTFS / rtk-class), resolved anchors (B13) |
| **K0** | Personal orchestrator discipline | agent-behaviour rules tied to this user's projects / config / tooling (e.g. Ren'Py validation gate, auto-memory↔CLAUDE.md mirror) — discipline that is NOT portable |

The scope+class travels into the session log (`**Class:**` field, one of `G / K1 / K2 / K0`) and decides the target **layer file**. Раскладка A1 («оглавление»): живой `~/.claude/CLAUDE.md` — тонкий, он лишь `@import`-ит файлы ниже, поэтому **отдельного зеркалирования в `_tracked/CLAUDE.md` больше нет** — правка слой-файла видна со следующей сессии напрямую.

- **G** → `_tracked/general-rules.md` (портируемо на любую установку).
- **K1** → `_tracked/shared.md`, секция «Профиль взаимопонимания (К1)».
- **K0** → если правило портируемо для этого юзера и **не привязано к машине/проекту** → `_tracked/shared.md`, секция «Дисциплина оркестратора (К0)»; если **машинно/проектно-специфично** (Ren'Py-гейт, дисциплина под конкретную машину) → `_tracked/machines/current/CLAUDE.md`, секция К0.
- **K2** → `_tracked/machines/current/CLAUDE.md`: индекс-строка в таблице «Карта среды (К2)»; полный рецепт — в `_tracked/machines/current/k2-environment.md` (reference-файл текущей машины).

`machines/current` — симлинк на профиль активной машины (наводит `bootstrap.sh` по детекции). K2 и машинный K0 писать **только через `current/`** — тогда правило ложится в профиль той машины, где поймано, и не утекает на другие. Если профиля текущей машины ещё нет (`current` не наведён) — сначала завести `machines/<id>/` и `_meta/machine-id`, затем писать.

Avoidance rules:
- If a one-line CLAUDE.md rule (A) would fix the same incident as a plugin fork (B) — pick A. Forks are more expensive to maintain.
- If an existing plugin skill already covers the pattern but is misbehaving — that is B (fix the plugin), not C (don't duplicate the skill under a new name).
- If a new skill (C) would only ever be invoked from this single conversation — that is not stable, drop it.

## Phase 4 — Draft the improvement

For each chosen observation, draft a concrete artefact.

**Category A — CLAUDE.md rule.**

**Assign a stable rule-id.** Every new A-rule gets a kebab-case id at creation, prefixed by its scope/class — `g-evidence-medicine` (general), `k1-implicit-revert`, `k2-rsync-ntfs`, `k0-renpy-validation-gate`. The id is written once as an HTML comment directly under the rule's `###` header in its target file (`general-rules.md` for G, CLAUDE.md for K1/K0, `k2-environment.md` for K2) and never changed afterwards (the header text may be reworded; the id may not):
```
### <Human-readable title>
<!-- id: <class>-<slug> -->
```
This id is the decay aggregator's join key (Phase 0). It exists precisely so a future reword of the title cannot split one rule's dormancy history into two and silently starve the prune channel. The id travels into the session log's finding block (`**Rule-ID:**`) and every future `## Decay check` line (`- [<id>] …`).

**Known limitation (lazy id adoption).** Rules created before this convention carry no id. They key on their normalised label (the `rule-stats.py` fallback) until a future run touches them and assigns an id; the continuity bridge then folds their pre-id history into the id. So the relabel-split protection is prospective — an id-less rule reworded before it ever gets an id can still split once. This is an accepted trade-off (no bulk back-fill); ids accrue as rules are next audited or edited.

Two common shapes:

*General rule:*
```
**Trigger:** <one sentence describing when this kicks in>
**Action:** <one sentence describing what to do>
**Reason (optional):** <one line with the original observation that motivated this>
```

*K1 mutual-understanding rule (typical output of A8; also A6/A7/C1 format preferences):*
```
**Trigger:** <the user's phrase or input pattern — verbatim where possible, not paraphrased>
**Means:** <the intent — what the user actually wants done when saying it>
**Don't:** <the misreading that happened — how the phrase was wrongly interpreted this time>
```
The Trigger MUST quote the user's actual wording from the evidence. A paraphrased trigger
will not match the way the user really talks — the rule then never fires (instant dormancy).

*Routing / tool-selection rule (typical output of signal types 8 and 9):*
```
**When:** <task class, described without naming today's task>
**Use:** <the specific tool / agent / skill / MCP call / search pattern that worked>
**Don't first try:** <the tool / agent / pattern that wasted time, with a short reason>
**Signal to recognise it:** <observable trait of the task that maps to «Use» — what the agent should look for in the prompt / repo / context to pick «Use» directly>
```

*External-system anchor rule (typical output of signal B13):*
```
**When:** querying <external system> for <data class> that needs an opaque ID (datasource UID, channel ID, project key, queue, org slug, etc.).
**Save:** on first successful resolution of the anchor, store a `reference`-type memory entry — `name: {system}_{context}_{anchor-kind}`, body = literal value + query template / standard label + verified date.
**Use:** on subsequent calls, read memory first, use the saved anchor directly. Do NOT re-run discovery if a fresh memory entry exists.
**Stale-detection:** empty / 404 / unknown_id from the anchor-driven query → re-run discovery (`list_*` / `search_*`), NOT a «not found» response to the user. If the anchor moved, update memory (move old value to a `previously_known:` line) and retry against the new anchor. Only after discovery also returns empty — say «not found».
**Why:** opaque IDs go stale silently when admins rotate datasources or rename channels. The first empty result must default to «anchor moved», not «data missing».
```

Anchor rules MUST include both **Save** AND **Stale-detection** halves — a one-sided rule either wastes discovery calls forever or silently swallows real outages.

The **«Signal to recognise it»** field is the load-bearing one for trial-and-error and wrong-tool observations: it's what makes the rule actionable next time. A rule that says «use X» without describing **what to look for to know X is right** does not prevent the next thrashing episode.

Pick the right section by grepping the existing CLAUDE.md for related rules. If no section fits, propose creating one with a short header.

**Category B — fork of a plugin artefact.**

Steps:
1. Locate the target file in `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/<kind>/<name>.<ext>`.
2. Read the upstream content and find the exact paragraph / step / sentence that produces the wrong behaviour.
3. Write the replacement text. Aim for **minimal diff** — change the smallest amount that fixes the cause.
4. Draft the intent-log entry. All four fields are required:
   ```
   ## Improvement #N — <YYYY-MM-DD> — <short label>
   **Why:** <one or two lines, motivation from the observation>
   **Where:** <which section / step / line range was touched>
   **Effect:** <one sentence on the behavioural change>
   **Re-apply rule:** <how /sync-upstream should check if this is still needed on a future upstream — look for the absence/presence of a specific phrase, behaviour, or example>
   ```

**Category C — new local skill.**

Skeleton:
- Frontmatter `name`, `description`. The `description` MUST include `MANDATORY TRIGGERS:` derived from the **actual phrases the user used in this conversation** (not invented synonyms), plus `DO NOT use for:` enumerating adjacent cases that should not match.
- Body with the standard sections of existing skills: `# /<name>`, Inputs, Preconditions, Algorithm (numbered steps), Anti-patterns, Failure handling.

## Phase 5 — Self-test (adversarial)

Before showing the draft to the user, run four checks on it:

1. **Counterfactual.** Would this improvement, if it had existed at the start of the session, actually have prevented the observed mistake? If no — the improvement is mis-targeted, rework or discard.
2. **Conflict.** Does the proposed rule / change contradict any existing rule in:
   - `~/.claude/CLAUDE.md` (global)
   - `<workspace>/.claude/CLAUDE.md` (workspace, if any is active)
   - `~/.claude/projects/<project-slug>/memory/MEMORY.md` **and every linked `.md` file** under that directory (auto-memory — see note below)
   - any installed plugin skill description

   Grep before claiming «no conflict». If a conflict exists, surface it to the user — do not silently override.

   > **Note on auto-memory.** This system does **not write** to `~/.claude/projects/.../memory/` (by design — all long-lived knowledge is in `.md` files we control). But auto-memory is an active source of rules the orchestrator follows in other sessions, so it must be **read** during conflict-check. A proposed CLAUDE.md rule that contradicts an existing memory entry is exactly the silent-override case this gate exists to catch.
3. **Specificity.** Is the trigger condition narrow enough that it won't misfire on unrelated tasks? Read the proposed trigger out loud and try to invent three unrelated future sessions that would accidentally match it. If any of them sound plausibly mismatched, narrow the trigger.
4. **Minimality.** Does the diff change only what the observation requires? «While I'm here» edits — strip them.

A draft that fails any check is either reworked once or discarded with a logged reason. No second rework — if check fails twice, the observation is probably not ready to become a rule.

## Phase 6 — Hand off to Step 4 of `/reflect-session`

Each surviving draft becomes one independent approval prompt to the user via `AskUserQuestion`. Bundle nothing. The user sees:

- The observation evidence (quote + turn pointer)
- The category (A / B / C)
- The full draft content (rule text, diff, or new SKILL.md)
- The self-test summary (which checks passed)
- Approval options: `Apply`, `Skip`, `Edit and re-show`, `Discard with reason`

## What the method is NOT

- **Not a chat retrospective.** «User seemed slightly annoyed on turn 7» is not an observation. A quote with verb «делай», «не», «вернись» — is.
- **Not a free-form notebook.** Phases run in order. Skipping Phase 5 turns the system into a noise generator.
- **Not exhaustive.** It is fine for `/reflect-session` to produce zero findings on a clean session. The right answer to «we worked well today» is no commit, not an invented improvement.

---

## References

The signal catalog in Phase 1 is informed by published taxonomies of LLM-agent failures and self-reflection patterns:

- Shinn et al., *Reflexion: Language Agents with Verbal Reinforcement Learning* — [arxiv:2303.11366](https://arxiv.org/abs/2303.11366). Core insight: actionable verbal feedback as the «gradient signal» for the next session.
- Cemri et al., *Why Do Multi-Agent LLM Systems Fail?* — [arxiv:2503.13657](https://arxiv.org/pdf/2503.13657). MAST taxonomy: specification/design (41.8%), inter-agent misalignment (36.9%), verification failures (21.3%) — basis for Cluster C protocol signals.
- *Where LLM Agents Fail and How They can Learn From Failures* — [arxiv:2509.25370](https://arxiv.org/abs/2509.25370). AgentErrorTaxonomy: memory / reflection / planning / action / system-level — basis for Cluster B agent-side signals.
- Microsoft, *Taxonomy of Failure Mode in Agentic AI Systems* (whitepaper, 2025).
- [BayramAnnakov/claude-reflect](https://github.com/BayramAnnakov/claude-reflect) — practical pattern of «correction phrases + positive feedback + remember statements», basis for Cluster A signals A1, A6, A7.

These references are background, not authority. The method overrides them where it disagrees.
