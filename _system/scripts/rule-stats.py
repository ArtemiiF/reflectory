#!/usr/bin/env python3
# Aggregates rule-efficacy data from _sessions/*-reflect.md logs.
#
# Why: VISION.md success metric — the share of `validated` rules in Phase 0
# decay audits is the measurable proxy for "уровень непонимания снижается".
# Without an aggregator the per-session Decay check lines never become a trend.
#
# Reads from every session log:
#   1. frontmatter (session_topic + findings_applied / skipped / discarded)
#   2. finding headers `## Finding N (status) — <label>` + optional **Class:** field
#   3. `## Decay check` lines: `- [id] <label> — validated | dormant(N) | misfiring`
#      The `[id]` prefix is optional; id-less legacy lines key on a normalised
#      label so relabel drift no longer splits one rule's history into two.
#
# Also reads `retired_ids` from _sessions/*-compress.md frontmatter
# (/reflect-compress Step 5): a retired id is dropped from the --dormancy feed
# and the decay table, so a rule deleted by a compress run stops re-surfacing
# as a forced decay finding in every subsequent /reflect-session. Retirement is
# dated — decay lines newer than the retirement (rule re-added under the same
# id) bring the rule back into the feed.
#
# Prints: chronological session review (what session, what was proposed,
# which knowledge class), per-rule decay history, totals, validated share.
# The session review answers "в какую сторону развивать": which sessions
# produce findings, which class (K1/K2/K0) dominates, what gets skipped.
# Read-only; safe to run anytime:
#   python3 _system/scripts/rule-stats.py            # full review
#   python3 _system/scripts/rule-stats.py --tail 10  # last 10 sessions only
#   python3 _system/scripts/rule-stats.py --dormancy # `key<TAB>N<TAB>label` feed
#                                                     # for Phase 0 (N = dormant run)

import glob
import os
import re
import sys
from collections import defaultdict

SESSIONS = os.path.join(
    os.environ.get("LOCAL_FORKS") or os.path.expanduser("~/.claude/local-forks"),
    "_sessions",
)
FRICTION = os.path.join(SESSIONS, "friction-metrics.tsv")

# A decay line may carry a stable rule-id prefix: `- [k1-foo] <label> — validated`.
# Legacy lines without the prefix fall back to a normalised label key (see norm_key).
# Trailing free-text after the status token is tolerated (e.g.
# `— dormant(5) → демоут в lazy (Finding 3)`) — the status is captured, the rest
# ignored — so an annotated decay line is never silently dropped.
DECAY_LINE = re.compile(
    r"^-\s+(?:\[(?P<id>[a-z0-9][a-z0-9-]*)\]\s+)?"
    r"(?P<label>.*?)\s+—\s+(?P<status>validated|dormant(?:\(\d+\))?|misfiring)(?:\s.*)?$"
)
FM_COUNTER = re.compile(
    r"^(findings_applied|findings_skipped|findings_discarded):\s*(\d+)\s*$"
)
FM_TOPIC = re.compile(r"^session_topic:\s*(.+)$")
FINDING_HDR = re.compile(r"^## Finding \d+ \((applied|skipped|discarded)\) — (.+)$")
CLASS_FIELD = re.compile(r"^\*\*Class:\*\*\s*(G|K[012])")


def norm_key(label: str) -> str:
    # Collapse relabel drift for legacy id-less lines: lowercase, drop a trailing
    # "(...)" qualifier (e.g. "(U+FFFD)", "(uv venv ...)"), squeeze whitespace.
    s = re.sub(r"\s*\([^)]*\)\s*$", "", label).lower()
    return re.sub(r"\s+", " ", s).strip()


# Both tolerate a trailing `# comment` — the SKILL.md log template puts an
# inline note on the key line, and hand-edited logs may annotate items.
RETIRED_KEY = re.compile(r"^retired_ids:\s*(\[\])?\s*(#.*)?$")
RETIRED_ITEM = re.compile(r"^\s*-\s+([a-z0-9][a-z0-9-]*)\s*(#.*)?$")


def load_retirements() -> dict:
    # key -> date of the latest compress run that retired it. Dates are the
    # filename prefixes (`<YYYY-MM-DD>T<HH-MM>`), ISO-shaped, so string
    # comparison orders them correctly against decay-history dates.
    retired = {}
    for path in sorted(glob.glob(os.path.join(SESSIONS, "*-compress.md"))):
        date = os.path.basename(path).split("-compress")[0]
        in_list = False
        for line in open(path, encoding="utf-8"):
            line = line.rstrip("\n")
            m = RETIRED_KEY.match(line)
            if m:
                in_list = m.group(1) is None  # `[]` → empty list, nothing follows
                continue
            if in_list:
                m = RETIRED_ITEM.match(line)
                if m:
                    retired[m.group(1)] = max(date, retired.get(m.group(1), ""))
                else:
                    in_list = False
    return retired


def is_retired(key, entries, retired) -> bool:
    # Retired unless a decay line postdates the retirement — a rule re-added
    # under the same id resumes its history and re-enters the feed.
    return key in retired and retired[key] >= entries[-1][0]


def consecutive_dormant(entries) -> int:
    # N = length of the trailing run of dormant marks in this rule's history.
    # Computed from the full aggregated history, NOT a number carried in the last
    # log — so a single missing Decay-check section can no longer reset the count.
    n = 0
    for _date, status in reversed(entries):
        if status.startswith("dormant"):
            n += 1
        else:
            break
    return n


def main() -> int:
    logs = sorted(glob.glob(os.path.join(SESSIONS, "*-reflect.md")))
    if not logs:
        print(f"no session logs under {SESSIONS}", file=sys.stderr)
        return 1

    tail = 0
    if "--tail" in sys.argv:
        try:
            tail = int(sys.argv[sys.argv.index("--tail") + 1])
        except (IndexError, ValueError):
            tail = 10

    dormancy_mode = "--dormancy" in sys.argv

    totals = {"findings_applied": 0, "findings_skipped": 0, "findings_discarded": 0}
    history = defaultdict(list)   # rule key (id or norm-label) -> [(date, status)]
    labels = {}                   # rule key -> display label (last seen)
    id_raw_label = {}             # id key -> raw label (for the continuity bridge)
    sessions = []                 # (date, topic, [(status, label, class)])
    class_counts = defaultdict(int)
    audits = 0

    for path in logs:
        date = os.path.basename(path).split("-reflect")[0]
        topic = ""
        findings = []
        in_decay = False
        for line in open(path, encoding="utf-8"):
            line = line.rstrip("\n")
            m = FM_COUNTER.match(line)
            if m:
                totals[m.group(1)] += int(m.group(2))
                continue
            m = FM_TOPIC.match(line)
            if m:
                topic = m.group(1).strip()
                continue
            m = FINDING_HDR.match(line)
            if m:
                findings.append([m.group(1), m.group(2).strip(), "—"])
                in_decay = False
                continue
            m = CLASS_FIELD.match(line.strip())
            if m and findings:
                findings[-1][2] = m.group(1)
                class_counts[m.group(1)] += 1
                continue
            if line.startswith("## "):
                in_decay = line.strip() == "## Decay check"
                continue
            if in_decay:
                stripped = line.strip()
                m = DECAY_LINE.match(stripped)
                if not m and stripped.startswith("- "):
                    # A bullet inside a Decay-check section that does not parse is
                    # drift, not noise — surface it rather than drop it silently.
                    print(
                        f"warning: unparsed decay line in {os.path.basename(path)}: "
                        f"{stripped[:80]}",
                        file=sys.stderr,
                    )
                if m:
                    key = m.group("id") or norm_key(m.group("label"))
                    display = (
                        f"[{m.group('id')}] {m.group('label')}"
                        if m.group("id") else m.group("label")
                    )
                    history[key].append((date, m.group("status")))
                    labels[key] = display
                    if m.group("id"):
                        id_raw_label[key] = m.group("label")
                    audits += 1
        sessions.append((date, topic, findings))

    # Continuity bridge: when a rule that used to be logged by bare label gets a
    # back-filled [id], its pre-id history sits under the norm-label key. Fold
    # that legacy bucket into the id key so back-filling never resets the trend.
    for key, raw in list(id_raw_label.items()):
        legacy = norm_key(raw)
        if legacy != key and legacy in history:
            history[key] = sorted(history[legacy] + history[key])
            del history[legacy]
            labels.pop(legacy, None)

    retired = load_retirements()

    # --dormancy: machine-readable feed for /reflect-session Phase 0.
    # One line per audited rule, `key<TAB>N<TAB>label`, sorted by N desc.
    # Phase 0 turns any N>=5 into a forced decay-removal finding.
    # Retired ids (see load_retirements) are excluded — already pruned by a
    # compress run, they must not re-surface as decay findings.
    if dormancy_mode:
        rows = sorted(
            ((consecutive_dormant(h), k) for k, h in history.items()
             if not is_retired(k, h, retired)),
            key=lambda r: (-r[0], r[1]),
        )
        for n, key in rows:
            print(f"{key}\t{n}\t{labels[key]}")
        return 0

    print("=== Sessions (chronological) ===")
    shown = sessions[-tail:] if tail else sessions
    for date, topic, findings in shown:
        print(f"\n{date}  {topic[:90] or '(no topic)'}")
        if not findings:
            print("  (no findings parsed)")
        for status, label, cls in findings:
            mark = {"applied": "+", "skipped": "~", "discarded": "-"}[status]
            cls_str = f" [{cls}]" if cls != "—" else ""
            print(f"  {mark} {label[:80]}{cls_str}")
    if tail and tail < len(sessions):
        print(f"\n(… {len(sessions) - tail} earlier sessions hidden; run without --tail)")

    print()
    print("=== Friction trend (machine-counted, from Stop hook) ===")
    if os.path.isfile(FRICTION):
        rows = []
        for line in open(FRICTION, encoding="utf-8"):
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 4:
                try:
                    rows.append((parts[0], parts[1], int(parts[2]), int(parts[3])))
                except ValueError:
                    continue
        rows.sort()
        shown_rows = rows[-(tail or len(rows)):]
        for date, sid, hits, msgs in shown_rows:
            ratio = hits / msgs * 100 if msgs else 0.0
            print(f"{date}  {sid[:12]:<12} corrections: {hits:>3} / {msgs:>4} msgs ({ratio:.0f}%)")
        if rows:
            total_h = sum(r[2] for r in rows)
            total_m = sum(r[3] for r in rows)
            avg = total_h / total_m * 100 if total_m else 0.0
            print(f"Overall: {total_h} corrections / {total_m} messages "
                  f"({avg:.0f}%) across {len(rows)} session(s) — goal: downward")
    else:
        print("no friction-metrics.tsv yet — accumulates automatically via the Stop hook")

    print()
    print("=== Totals ===")
    print(f"Session logs: {len(logs)}")
    if class_counts:
        print(
            "Class split: "
            + ", ".join(f"{k}: {v}" for k, v in sorted(class_counts.items()))
        )
    print(
        "Findings — applied: {findings_applied}, skipped: {findings_skipped}, "
        "discarded: {findings_discarded}".format(**totals)
    )
    print()

    if not history:
        print("No `## Decay check` sections yet — the metric starts accumulating")
        print("with the first /reflect-session run that executes Phase 0.")
        return 0

    counts = defaultdict(int)
    n_retired = 0
    print(f"{'rule':<55} {'last status':<14} audits")
    for key in sorted(history, key=lambda k: labels[k]):
        entries = history[key]
        if is_retired(key, entries, retired):
            n_retired += 1
            continue  # pruned by /reflect-compress — out of the live trend
        last = entries[-1][1]
        counts[re.sub(r"\(\d+\)", "", last)] += 1
        print(f"{labels[key][:54]:<55} {last:<14} {len(entries)}")
    if n_retired:
        print(f"(+ {n_retired} retired rule(s) via /reflect-compress — hidden)")

    total_rules = sum(counts.values())
    validated_share = counts["validated"] / total_rules * 100
    print()
    print(
        f"Rules audited: {total_rules} | validated: {counts['validated']} "
        f"({validated_share:.0f}%) | dormant: {counts['dormant']} | "
        f"misfiring: {counts['misfiring']}"
    )
    print(f"Decay-check lines total: {audits}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
