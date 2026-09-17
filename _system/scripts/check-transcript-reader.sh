#!/usr/bin/env bash
# check-transcript-reader.sh — prove the transcript translation still sees prose.
#
# Why this exists: the first version of transcript_reader.py was written against
# an August rollout (codex-cli 0.145.0) and mapped event_msg/user_message. Codex
# 0.154.0 moved user and assistant text into event_msg/item_completed, so the
# translator silently yielded tool calls and nothing else — every consumer kept
# running, reflect-reminder just counted zero user messages forever. A format
# drift that costs nothing at runtime is exactly what needs a gate.
#
# Exit codes: 0 fine (isolated anomalies reported, not enforced); 1 an
# established drift; 3 not enough evidence to judge — nothing large enough to
# examine, or too few transcripts to tell an anomaly from a drift. The hook
# treats 3 as skip-with-notice, never as a pass.
#
# A machine-readable "VERDICT: <drift|anomaly|inconclusive> [agents]" line goes
# to stderr so the caller keys on that instead of parsing the report text.
#
# The check walks the newest N transcripts of each agent present on the machine
# and fails when a non-trivial transcript yields no user text, OR no assistant
# text — either counter at zero is a failure, not both. Examining nothing is a
# separate outcome (exit 3), because "no evidence" is not "no defect". A count printed without a comparison
# is not evidence, so the comparison is here.
#
# Usage: check-transcript-reader.sh [--per-agent N] [--min-records N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_SESSIONS="${CODEX_HOME:-${HOME}/.codex}/sessions"
CLAUDE_PROJECTS="${HOME}/.claude/projects"
per_agent=3
min_records=60

while (( $# > 0 )); do
  case "$1" in
    --per-agent) per_agent="${2:-}"; [[ -n "${per_agent}" ]] || { echo "check-transcript-reader: --per-agent needs a value" >&2; exit 2; }; shift 2 ;;
    --min-records) min_records="${2:-}"; [[ -n "${min_records}" ]] || { echo "check-transcript-reader: --min-records needs a value" >&2; exit 2; }; shift 2 ;;
    *) echo "check-transcript-reader: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="${SCRIPT_DIR}" CODEX_SESSIONS="${CODEX_SESSIONS}" \
CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}" \
CLAUDE_PROJECTS="${CLAUDE_PROJECTS}" PER_AGENT="${per_agent}" MIN_RECORDS="${min_records}" \
python3 -c '
import glob, os, sys, time

LIVE_WINDOW_S = 600   # a transcript touched in the last 10 minutes may still be open

sys.path.insert(0, os.environ["SCRIPT_DIR"])
from transcript_reader import iter_records

per_agent = int(os.environ["PER_AGENT"])
min_records = int(os.environ["MIN_RECORDS"])


def record_count(path):
    """Raw JSON lines. Deliberately not "conversational turns": a transcript
    whose translation drifted has zero turns by definition, so judging size by
    anything the translator produces would filter out exactly the evidence."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return 0

sources = {
    "codex": os.path.join(os.environ["CODEX_SESSIONS"], "*", "*", "*", "rollout-*.jsonl"),
    "claude": os.path.join(os.environ["CLAUDE_PROJECTS"], "*", "*.jsonl"),
}

checked = 0
per_agent_checked = {"codex": 0, "claude": 0}
per_agent_failed = {"codex": 0, "claude": 0}
# Verdicts per transcript in newest-first order: a drift is a RUN of failures at
# the newest end, an anomaly is an isolated one anywhere.
per_agent_sequence = {}
failures = []

for agent, pattern in sources.items():
    # Size in bytes does not separate a real session from a 30-second probe:
    # Codex writes the whole system prompt into the first record, so a probe
    # with one exchange is already ~52KB (measured 2026-09-16: probes 15-27
    # records at 52-332KB, real sessions 75-1204 records). Record count does.
    paths = [p for p in glob.glob(pattern) if record_count(p) >= min_records]
    if not paths:
        print("  %-6s no transcript with >=%d records — skipped" % (agent, min_records))
        continue
    paths.sort(key=os.path.getmtime, reverse=True)
    # A transcript written in the last few minutes is probably still being
    # appended to: mid-run it legitimately has no assistant message yet, and
    # judging it would fail over state that has nothing to do with the commit.
    # Dropping by RANK instead would have skipped the first transcript written
    # after a format drift — exactly the one that shows it.
    now = time.time()
    fresh = [p for p in paths if now - os.path.getmtime(p) < LIVE_WINDOW_S]
    paths = [p for p in paths if p not in fresh]
    if fresh:
        print("  %-6s %d transcript(s) too fresh to judge (still open) — skipped" % (agent, len(fresh)))
    for path in paths[:per_agent]:
        users = assts = tools = 0
        for rec in iter_records(path):
            msg = rec.get("message") or {}
            content = msg.get("content")
            if rec.get("type") == "user":
                # Claude user records carry either a plain string or a block
                # list; counting only strings made a healthy transcript look
                # empty and, once this ran from pre-commit, would have blocked
                # every commit on the machine.
                if isinstance(content, str) and content.strip():
                    users += 1
                elif isinstance(content, list) and any(
                    isinstance(b, dict) and b.get("type") == "text" for b in content
                ):
                    users += 1
            elif rec.get("type") == "assistant" and isinstance(content, list):
                # Scan every block: Claude records routinely lead with a
                # thinking block, so judging by content[0] alone under-reports
                # assistant text and produces a false red on those transcripts.
                kinds = {b.get("type") for b in content if isinstance(b, dict)}
                if "text" in kinds:
                    assts += 1
                if "tool_use" in kinds:
                    tools += 1
        checked += 1
        per_agent_checked[agent] = per_agent_checked.get(agent, 0) + 1
        per_agent_sequence.setdefault(agent, [])
        name = os.path.basename(path)
        # tools is printed for context only — nothing is asserted about it, since
        # a session may legitimately call no tool at all.
        print("  %-6s %-46s user=%-4d assistant=%-4d tool=%d" % (agent, name[:46], users, assts, tools))
        per_agent_sequence[agent].append(users > 0 and assts > 0)
        if users == 0 or assts == 0:
            per_agent_failed[agent] = per_agent_failed.get(agent, 0) + 1
            what = []
            if users == 0:
                what.append("no user text")
            if assts == 0:
                what.append("no assistant text")
            failures.append("%s: %s yields %s" % (agent, name, " and ".join(what)))

if checked == 0:
    # Exit 3, not 1: "nothing to examine" is a different fact from "translation
    # is broken", and the pre-commit hook must not block a commit on the former.
    # Still non-zero, so a direct run never reads as a pass.
    sys.stderr.write("check-transcript-reader: examined 0 transcripts — nothing was proven.\n")
    sys.exit(3)

# The translation this repo owns is the Codex one. A green built only on Claude
# transcripts proves nothing about it, so say so rather than print "ok".
# Codex presence is judged by CODEX_HOME, the same way bootstrap.sh and
# skill-targets.sh judge it — keying on sessions/ meant a Codex home whose
# sessions directory did not exist yet produced a green built on Claude data.
if per_agent_checked.get("codex", 0) == 0 and os.path.isdir(os.environ["CODEX_HOME_DIR"]):
    sys.stderr.write(
        "VERDICT: inconclusive codex\n"
        "check-transcript-reader: no Codex transcript settled and >=%d records —\n"
        "the Codex leg, which is the translation this repo owns, was not exercised.\n"
        % min_records
    )
    sys.exit(3)

# A format drift zeroes every transcript written AFTER it, so it shows up as a
# run of empty results at the newest end — while an interrupted session is an
# isolated one. Two distinctions matter and both were wrong before:
#   * one sample is not a run: with a single examined transcript "all of them
#     failed" is trivially true, and an anomaly would have blocked every commit;
#   * a drift does not have to reach the oldest transcript: waiting for ALL of
#     them to fail means the first sessions after a drift pass as anomalies.
MIN_RUN = 2

drifted = []
for a, seq in per_agent_sequence.items():
    run = 0
    for ok in seq:            # newest first
        if ok:
            break
        run += 1
    if run >= MIN_RUN:
        drifted.append(a)

inconclusive = [
    a for a, seq in per_agent_sequence.items()
    if seq and len(seq) < MIN_RUN and not all(seq)
]

if failures and not drifted:
    label = "inconclusive" if inconclusive else "anomalous"
    sys.stderr.write("\ncheck-transcript-reader: %s transcript(s), not an established drift:\n" % label)
    for f in failures:
        sys.stderr.write("  %s\n" % f)
    if inconclusive:
        sys.stderr.write(
            "VERDICT: inconclusive %s\n"
            "Only %d transcript(s) of that agent were examined — too few to tell an\n"
            "interrupted session from a format drift. Check the mapping by hand.\n"
            % ("/".join(sorted(inconclusive)), MIN_RUN - 1)
        )
        sys.exit(3)
    sys.stderr.write("VERDICT: anomaly\n")
    sys.stderr.write("Newer transcripts of the same agent carried the conversation.\n")

if drifted:
    sys.stderr.write("\ncheck-transcript-reader: translation lost the conversation:\n")
    for f in failures:
        sys.stderr.write("  %s\n" % f)
    sys.stderr.write(
        "VERDICT: drift %s\n"
        "The newest %s transcript(s) all came back empty — the format probably\n"
        "drifted; see the mapping in transcript_reader.py.\n"
        % ("/".join(sorted(drifted)), "/".join(sorted(drifted)))
    )
    sys.exit(1)

if per_agent_checked.get("codex", 0) == 0:
    sys.stderr.write(
        "check-transcript-reader: the Codex leg was not exercised on this machine.\n"
    )

clean = checked - sum(per_agent_failed.values())
print("transcript reader ok: %d of %d examined transcript(s) carried both user and"
      " assistant text." % (clean, checked))
'
