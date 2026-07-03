# Compress method

Analytical scaffolding for `/reflect-compress` Step 2. Five phases, each producing findings of one kind; run in order (repairs before prunes before polish). Every finding needs machine-feed evidence (Phases X, D) or quoted rule text (Phases C, M, V) — «this feels redundant» is not a finding.

## Phase X — Stale references (repair channel)

Input: `check-stale-refs.py` TSV (`file<TAB>line<TAB>token`).

For each dead pointer, decide by what the rule loses without it:

- Pointer is **incidental** (an example, one anchor among several) → finding: fix or drop the pointer, rule body otherwise unchanged.
- Pointer is **load-bearing** (the rule's Action says «read/run this») → finding: repair the path if the target moved (verify the new location exists — `ls`, not memory), or propose deleting the rule if the target is gone for good.
- Pointer refers to something **intentionally absent on this machine** (another machine's layer, an optional tool) → not a finding; note in the session log so the next run doesn't re-surface it.

## Phase D — Dormancy (prune channel)

Input: `rule-stats.py --dormancy` (`key<TAB>N<TAB>label`, N desc).

Same thresholds as reflect-session Phase 0, applied batch-wide instead of capped at 2:

- **N ≥ 5** → finding: delete, merge into an adjacent rule, or demote to a lazily-read reference file. Choose demotion when the rule encodes real but rare knowledge (a recipe), deletion when the encoded mistake is no longer plausible (tool retired, workflow changed).
- **3 ≤ N < 5** → tighten-only candidate: feeds Phase V, not a standalone prune.

Deleting/demoting here is what reflect-session's 2-per-run cap cannot do; the per-item approval gate is identical.

## Phase C — Contradictions

For each pair of rules in the same knowledge class (G / K0 / K1 / K2), compare Trigger and Action/Don't:

- Overlapping trigger, incompatible actions → finding: quote both rules, propose the resolution — merge with an explicit precedence clause, narrow one trigger, or delete the superseded rule (prefer keeping the one with the more recent evidence/Reason line).
- A rule contradicting a hard structural fact of the repo/environment (checkable now — check it) → finding: repair or delete.

Never resolve a contradiction by inventing a third behaviour neither rule states — that is a /reflect-session observation, not a compress finding.

## Phase M — Merge (near-duplicates)

Two rules are merge candidates when their triggers describe the same situation at different wording and their actions do not conflict (else Phase C). The merged rule:

- keeps the id and header of the **older** rule (longer decay history — continuity is worth more than the newer slug);
- unions the trigger phrasings and keeps the tighter action wording;
- records the retired id in the session log frontmatter (`retired_ids`).

Do not chain-merge (A+B → AB, then AB+C) in one run — each merge is a separate finding, and a second-order merge reasons about a rule that does not exist yet.

## Phase V — Verbosity

Candidates: rules over ~12 lines, rules whose Reason paragraph restates the Action, rules with 3+ examples where 1 carries the pattern, plus the 3 ≤ N < 5 dormant set from Phase D.

A tighten finding shows full before → after. The bar (this is the self-test below, applied at draft time): every trigger instance the long form catches, the short form must catch — compression of FORM, never of scope. Cutting a Reason line is fine (git keeps it); cutting a trigger qualifier is not.

## Self-test (every finding, any phase)

1. **Counterfactual** — for repairs/tightens: replay the rule's original evidence (its Reason line or the session that created it) against the new text; it must still fire. For deletions: state why the encoded mistake can no longer occur, or accept the risk explicitly in the approval prompt.
2. **Conflict** — the new text contradicts no surviving rule (including other findings of this run, in presentation order).
3. **Minimality** — the finding changes one rule (or one merge pair) — no opportunistic neighbouring edits.

A draft failing any check is reworked once or discarded.
