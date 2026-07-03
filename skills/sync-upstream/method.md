# Semantic re-apply method

Analytical scaffolding for `/sync-upstream` Step 4 — how to walk an intent log and re-apply each Improvement on top of a new upstream version. Read this file at the start of Step 4.

The goal is **conservative, evidence-driven re-application**. Three outcomes per Improvement (`subsumed`, `active`, `conflict`) — each backed by a concrete textual finding in the new upstream, never by hand-waving.

## Inputs available

Per fork, the following are gathered in Step 4 of `SKILL.md`:

| File | What it is | Required |
|---|---|---|
| `our.md` | Our current local version with all past improvements applied | yes |
| `intent.md` | List of Improvement entries with Why / Where / Effect / Re-apply rule | yes |
| `upstream.new.md` | The plugin file in the **new** version directory | yes |
| `upstream.baseline.md` | The plugin file in the **baseline** version directory, if still on disk | optional |
| `_meta.json` | Records baseline version, last sync timestamp | yes |

The optional `upstream.baseline.md` is a hint, not a source of truth. Re-apply is driven by `intent.md`, not by diff'ing baseline against new.

> **NOTE — typical case: baseline absent.** Claude Code's plugin manager cleans up old version directories ~7 days after an upgrade. By the time `/sync-upstream` runs, `upstream.baseline.md` is usually already gone. This is expected, not an error. When absent: log a one-line note in the per-fork report, proceed with the remaining inputs, and have Step 5 of `SKILL.md` show only two diffs instead of three.

## Phase 1 — Parse intent log

For each `## Improvement #N` entry, extract the four fields. If any field is missing or malformed, mark the entry **`malformed`** and surface to the user at the end — do not silently classify.

Validate Re-apply rule shape: it must describe an observable signal in the upstream text (a phrase, a section, a behaviour) — not a vague intent. A Re-apply rule that says «check if it still makes sense» is malformed.

## Phase 2 — Classify each Improvement

Apply the three-way decision in strict order. The first verdict that matches the evidence wins.

### Verdict 1 — `subsumed`

The new upstream **already does what our improvement does**.

Evidence required to assign `subsumed`:

- A specific section, paragraph, step, or sentence in `upstream.new.md` that performs the same behavioural change as our improvement, AND
- The Re-apply rule's «check signal» can be matched in `upstream.new.md`.

«Same behavioural change» means the *effect* matches — wording may differ. The plugin author may have used different words for the same idea. Be tolerant of phrasing, strict about effect.

If you cannot quote a specific span in `upstream.new.md` that demonstrates the behaviour, this is NOT `subsumed`. Do not retire on suspicion.

### Verdict 2 — `conflict`

The new upstream **does something incompatible** with our improvement. Three sub-shapes:

1. **Direct contradiction.** Upstream now explicitly forbids what we required, or requires what we forbade.
2. **Foundation removed.** The section / step / mechanism our improvement modified no longer exists in upstream. Our patch has nowhere to land.
3. **Behaviour drifted.** Upstream has restructured the surrounding logic so our improvement, when re-applied, would produce semantically wrong output (e.g. our improvement assumed a precondition that upstream now violates upfront).

Evidence required to assign `conflict`: name the contradiction. Quote the upstream phrase or describe the missing foundation. A conflict without a citation is `active`-with-uncertainty, not `conflict`.

### Verdict 3 — `active`

Default verdict if neither `subsumed` nor `conflict` is supported by clear evidence.

`active` means: upstream still lacks the behaviour our improvement added, and the patch can be applied cleanly on top of the new text.

Re-applying an `active` improvement is described in Phase 4.

### Confidence note

Do not invent a fourth verdict («partially subsumed», «sort of conflicts»). If torn between `active` and `conflict`, choose `conflict` and surface to the user — false-conflict costs the user one prompt, false-active silently corrupts behaviour.

## Phase 3 — Cross-improvement consistency check

Before re-applying any `active` entries, walk the full set together once:

1. Do two `active` improvements modify the same section in incompatible ways? (Possible if past `/reflect-session` runs added similar but slightly different rules.) → Surface as `conflict` against each other, ask user to consolidate.
2. Do two `subsumed` verdicts depend on the same upstream span? → Fine, both retire.
3. Does an `active` improvement assume the presence of another improvement that is now `subsumed`? (Stacking dependency.) → Re-evaluate: the foundation moved upstream, our patch may now be `subsumed` too.

This check exists because intent logs accumulate over months and entries are not independent.

## Phase 4 — Re-apply `active` improvements

For each `active` Improvement, build the patched upstream text:

1. Re-locate the target span in `upstream.new.md` using the Re-apply rule. The structural anchor (a section heading, a step number, a function name) usually survives upstream edits even when wording changes. If the anchor is gone but the structural context is recognisable, re-apply at the nearest equivalent location.
2. Express the change as a **minimal semantic patch** — paraphrase if needed to fit the new wording, do not copy-paste old lines verbatim if they would clash with new style.
3. Preserve frontmatter, headings hierarchy, and code-block fences. A re-applied improvement must produce a syntactically valid `.md` file.
4. Refresh the Improvement's `Where:` field to point at the new anchor location for the next sync cycle.

Order of application: by Improvement number (chronological). Later improvements may build on earlier ones — apply in the order they were created.

## Phase 5 — Build `our.new.md`

Output of Phase 4 is the new local file. Sanity-check before writing:

- Frontmatter parses (single YAML block at the top with valid keys).
- All Markdown headings well-formed.
- No leftover `<<<<<<<` / `=======` / `>>>>>>>` conflict markers (this is a semantic re-apply — diff3 markers should never appear).
- File size within an order of magnitude of `upstream.new.md` (a 10× growth is a red flag — likely accidental duplication).

If sanity-check fails, mark this whole fork as `conflict` and surface to the user. Do not write a broken file to disk.

## Phase 6 — Re-package `intent.md`

Rewrite the intent log into three sections, replacing the previous flat list:

```markdown
## Active
<remaining improvements with refreshed Where: fields>

## Retired (subsumed by <plugin>@<new-version>)
<entries removed because upstream now does this, with the upstream-snippet that subsumed them>

## Conflicts (manual review)
<entries that conflict with new upstream, with the contradicting upstream-snippet>
```

Retired entries are kept in the file as audit trail — they are not deleted. They move from `Active` to `Retired` and become inert.

Update `_meta.json`:

```json
{
  "baseline_upstream_version": "<new-version>",
  "last_synced_at": "<ISO-8601 UTC>"
}
```

## Phase 7 — Hand off to Step 5 of `/sync-upstream`

The output of this method, per fork:

- `our.new.md` — the re-applied local file content
- `intent.new.md` — re-packaged intent log
- `_meta.json.new` — updated metadata
- A per-fork report: counts of `active` / `subsumed` / `conflict` / `malformed`, with the evidence quote for each non-`active` verdict.

This report is what Step 5 of `SKILL.md` shows the user for approval.

## Anti-patterns

- **No verdicts without citations.** Every `subsumed` or `conflict` decision quotes a specific span of `upstream.new.md`. No quote = `active`-or-`malformed`, not «subsumed by vibes».
- **No textual diff3 / git merge-file.** This is a semantic re-apply, not a 3-way merge.
- **No batch verdicts.** Each Improvement is classified independently. Cross-improvement consistency runs ONCE in Phase 3, not woven into Phase 2 decisions.
- **No silent retirement.** Every `Retired` entry remains in the intent log with the subsuming-upstream snippet.
- **No partial verdicts.** «Partially subsumed» is `conflict` — escalate to the user.
- **No conflict markers in output files.** If diff3-style markers appear anywhere, the run is broken — stop, surface, do not write.

## What the method is NOT

- **Not a syntactic merge.** It does not align lines or compute textual deltas. It reads intent, re-applies effect.
- **Not authoritative.** Every output requires per-fork user approval in Step 5. Method just produces the proposal.
- **Not retroactive.** It does not revisit previously-retired entries. Retired stays retired unless the user manually un-retires.

---

## References

- [Reflexion (Shinn et al.)](https://arxiv.org/abs/2303.11366) — verbal feedback as the actionable signal, the basis for treating Re-apply rules as the load-bearing field.
- [LLMinus — LLM-assisted merge conflict resolution](https://www.phoronix.com/news/LLMinus-RFC-v2) — adjacent problem (kernel merge), useful as contrast: LLMinus operates on diff hunks; this method operates on intents.
